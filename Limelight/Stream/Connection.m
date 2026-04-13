//
//  Connection.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/19/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "Connection.h"
#import "LogBuffer.h"
#import "Utils.h"

#import "Moonlight-Swift.h"

#import <AudioUnit/AudioUnit.h>
#import <CoreAudio/CoreAudio.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <os/lock.h>

#import <arpa/inet.h>
#include <netinet/in.h>

#include "Limelight.h"
#include "Limelight-internal.h"
#include "opus_multistream.h"

// Limelight-internal.h defines these as macros redirecting to
// LiGetEffectiveConnectionContext()->xxx, which prevents direct
// struct field access like _connectionContext.RemoteAddr.
// Undef them so we can access ML_CONNECTION_CONTEXT fields directly.
#undef RemoteAddr
#undef LocalAddr
#undef AddrLen
#undef MicPingPayload
#undef MicPortNumber
#undef AudioEncryptionEnabled
#undef EncryptionFeaturesEnabled

#define AUDIO_QUEUE_BUFFERS 4

@interface Connection ()
#if defined(LI_MIC_CONTROL_START)
@property (nonatomic, strong) AVAudioEngine* micAudioEngine;
@property (nonatomic, strong) AVAudioConverter* micConverter;
@property (nonatomic, strong) AVAudioFormat* micOutputFormat;
#endif
- (void)updateVolume;
@end

@implementation Connection {
    SERVER_INFORMATION _serverInfo;
    STREAM_CONFIGURATION _streamConfig;
    CONNECTION_LISTENER_CALLBACKS _clCallbacks;
    DECODER_RENDERER_CALLBACKS _drCallbacks;
    AUDIO_RENDERER_CALLBACKS _arCallbacks;
    char _hostString[256];
    char _appVersionString[32];
    char _gfeVersionString[32];
    char _rtspSessionUrl[1024];

    ML_CONNECTION_CONTEXT _connectionContext;
    NSLock *_initLock;

    VideoDecoderRenderer *_renderer;
    id<ConnectionCallbacks> _callbacks;

    OpusMSDecoder *_opusDecoder;
    int _audioBufferEntries;
    int _audioBufferWriteIndex;
    int _audioBufferReadIndex;
    int _audioBufferStride;
    int _audioSamplesPerFrame;
    short *_audioCircularBuffer;

    int _channelCount;
    float _audioVolumeMultiplier;
    NSString *_hostAddress;
    int _currentUpscalingMode;
    StreamConfiguration *_rendererStreamConfig;
    os_unfair_lock _stateLock;

    AudioQueueRef _audioQueue;
    AudioQueueBufferRef _audioBuffers[AUDIO_QUEUE_BUFFERS];
    void *_audioQueueContext;

#if defined(LI_MIC_CONTROL_START)
    dispatch_queue_t _micQueue;
    OpusMSEncoder* _micEncoder;
    NSMutableData* _micPcmQueue;
    int _micSendFailures;
    BOOL _micStopping;
    BOOL _micControlStarted;
    BOOL _micEncryptionStatusLogged;
    uint64_t _micLastPingTimeMs;
    uint32_t _micPingCount;
#endif
}

static NSMutableDictionary<NSValue*, Connection*>* gConnectionMap;
static dispatch_queue_t gConnectionMapQueue;
static void *gConnectionMapQueueKey = &gConnectionMapQueueKey;
static os_unfair_lock gConnectionMapLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock gConnectionLifecycleLock = OS_UNFAIR_LOCK_INIT;
static void *gMicQueueKey = &gMicQueueKey;

#define OUTPUT_BUS 0

// My iPod touch 5th Generation seems to really require 80 ms
// of buffering to deliver glitch-free playback :(
// FIXME: Maybe we can use a smaller buffer on more modern iOS versions?
#define CIRCULAR_BUFFER_DURATION 80

// (moved to instance fields)

static void EnsureConnectionMap(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gConnectionMap = [NSMutableDictionary dictionary];
        gConnectionMapQueue = dispatch_queue_create("moonlight.connection.map", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(gConnectionMapQueue, gConnectionMapQueueKey, gConnectionMapQueueKey, NULL);
    });
}

static void RegisterConnection(PML_CONNECTION_CONTEXT ctx, Connection* connection) {
    if (ctx == NULL || connection == nil) {
        return;
    }
    EnsureConnectionMap();
    NSValue *key = [NSValue valueWithPointer:ctx];
    os_unfair_lock_lock(&gConnectionMapLock);
    gConnectionMap[key] = connection;
    os_unfair_lock_unlock(&gConnectionMapLock);
}

static void UnregisterConnection(PML_CONNECTION_CONTEXT ctx) {
    if (ctx == NULL) {
        return;
    }
    EnsureConnectionMap();
    NSValue *key = [NSValue valueWithPointer:ctx];
    os_unfair_lock_lock(&gConnectionMapLock);
    [gConnectionMap removeObjectForKey:key];
    os_unfair_lock_unlock(&gConnectionMapLock);
}

static Connection* ConnectionForContext(PML_CONNECTION_CONTEXT ctx) {
    if (ctx == NULL) {
        return nil;
    }
    EnsureConnectionMap();
    NSValue *key = [NSValue valueWithPointer:ctx];
    __block Connection *conn = nil;
    os_unfair_lock_lock(&gConnectionMapLock);
    conn = gConnectionMap[key];
    os_unfair_lock_unlock(&gConnectionMapLock);
    return conn;
}

static Connection* CurrentConnection(void) {
    return ConnectionForContext(LiGetThreadConnectionContext());
}

static VideoDecoderRenderer* ConnectionGetRendererSnapshot(Connection *conn) {
    if (conn == nil) {
        return nil;
    }

    os_unfair_lock_lock(&conn->_stateLock);
    VideoDecoderRenderer *renderer = conn->_renderer;
    os_unfair_lock_unlock(&conn->_stateLock);
    return renderer;
}

static id<ConnectionCallbacks> ConnectionGetCallbacksSnapshot(Connection *conn) {
    if (conn == nil) {
        return nil;
    }

    os_unfair_lock_lock(&conn->_stateLock);
    id<ConnectionCallbacks> callbacks = conn->_callbacks;
    os_unfair_lock_unlock(&conn->_stateLock);
    return callbacks;
}

static void ConnectionSetRenderer(Connection *conn, VideoDecoderRenderer *renderer) {
    if (conn == nil) {
        return;
    }

    os_unfair_lock_lock(&conn->_stateLock);
    conn->_renderer = renderer;
    os_unfair_lock_unlock(&conn->_stateLock);
}

static void ConnectionSetCallbacks(Connection *conn, id<ConnectionCallbacks> callbacks) {
    if (conn == nil) {
        return;
    }

    os_unfair_lock_lock(&conn->_stateLock);
    conn->_callbacks = callbacks;
    os_unfair_lock_unlock(&conn->_stateLock);
}

static void ConnectionClearRuntimeTargets(Connection *conn) {
    if (conn == nil) {
        return;
    }

    os_unfair_lock_lock(&conn->_stateLock);
    conn->_callbacks = nil;
    conn->_renderer = nil;
    os_unfair_lock_unlock(&conn->_stateLock);
}

+ (Connection *)currentConnection {
    return CurrentConnection();
}

- (VideoDecoderRenderer *)renderer {
    return ConnectionGetRendererSnapshot(self);
}

static void FillOutputBuffer(void *aqData,
                             AudioQueueRef inAQ,
                             AudioQueueBufferRef inBuffer);

#if defined(LI_MIC_CONTROL_START)
// (moved to instance fields)
static const int micSampleRate = 48000;
static const int micChannels = 1;
static const int micFrameSize = 960; // 20 ms at 48 kHz
static const int micBitrate = 64000;
#endif

int DrDecoderSetup(int videoFormat, int width, int height, int redrawRate, void* context, int drFlags)
{
    Connection *conn = context ? (__bridge Connection *)context : CurrentConnection();
    if (conn == nil) {
        return -1;
    }
    VideoDecoderRenderer *renderer = ConnectionGetRendererSnapshot(conn);
    if (renderer == nil) {
        return -1;
    }
    [renderer setupWithVideoFormat:videoFormat
                         frameRate:redrawRate
                     upscalingMode:conn->_currentUpscalingMode
                      streamConfig:conn->_rendererStreamConfig];
    return 0;
}

void DrStart(void)
{
    Connection *conn = CurrentConnection();
    if (conn != nil) {
        VideoDecoderRenderer *renderer = ConnectionGetRendererSnapshot(conn);
        [renderer start];
    }
}

void DrStop(void)
{
    Connection *conn = CurrentConnection();
    if (conn != nil) {
        VideoDecoderRenderer *renderer = ConnectionGetRendererSnapshot(conn);
        [renderer stop];
        ConnectionClearRuntimeTargets(conn);
    }
}

int DrSubmitDecodeUnit(PDECODE_UNIT decodeUnit)
{
    // Use the optimized renderer path which includes buffer pooling
    Connection *conn = CurrentConnection();
    VideoDecoderRenderer *renderer = ConnectionGetRendererSnapshot(conn);
    if (conn == nil || renderer == nil) {
        return DR_OK;
    }
    return [renderer submitDecodeUnit:decodeUnit];
}

int ArInit(int audioConfiguration, POPUS_MULTISTREAM_CONFIGURATION originalOpusConfig, void* context, int flags)
{
    Connection *conn = context ? (__bridge Connection *)context : CurrentConnection();
    if (conn == nil) {
        Log(LOG_E, @"ArInit called without connection context");
        return -1;
    }

    int err;
    AudioChannelLayout channelLayout = {};
    OPUS_MULTISTREAM_CONFIGURATION opusConfig = *originalOpusConfig;
    
    // Initialize the circular buffer
    conn->_audioBufferWriteIndex = conn->_audioBufferReadIndex = 0;
    conn->_audioSamplesPerFrame = opusConfig.samplesPerFrame;
    conn->_audioBufferStride = opusConfig.channelCount * opusConfig.samplesPerFrame;
    conn->_audioBufferEntries = CIRCULAR_BUFFER_DURATION / (opusConfig.samplesPerFrame / (opusConfig.sampleRate / 1000));
    conn->_audioCircularBuffer = malloc(conn->_audioBufferEntries * conn->_audioBufferStride * sizeof(short));
    if (conn->_audioCircularBuffer == NULL) {
        Log(LOG_E, @"Error allocating output queue\n");
        return -1;
    }
    
    conn->_channelCount = opusConfig.channelCount;
    
    switch (opusConfig.channelCount) {
        case 2:
            channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
            break;
        case 4:
            channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Quadraphonic;
            break;
        case 6:
            channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_AudioUnit_5_1;
            break;
        case 8:
            channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_AudioUnit_7_1;
            
            // Swap SL/SR and RL/RR to match the selected channel layout
            opusConfig.mapping[4] = originalOpusConfig->mapping[6];
            opusConfig.mapping[5] = originalOpusConfig->mapping[7];
            opusConfig.mapping[6] = originalOpusConfig->mapping[4];
            opusConfig.mapping[7] = originalOpusConfig->mapping[5];
            break;
        default:
            // Unsupported channel layout
            Log(LOG_E, @"Unsupported channel layout: %d\n", opusConfig.channelCount);
            abort();
    }
    
    conn->_opusDecoder = opus_multistream_decoder_create(opusConfig.sampleRate,
                                                         opusConfig.channelCount,
                                                         opusConfig.streams,
                                                         opusConfig.coupledStreams,
                                                         opusConfig.mapping,
                                                         &err);

#if TARGET_OS_IPHONE
    // Configure the audio session for our app
    NSError *audioSessionError = nil;
    AVAudioSession* audioSession = [AVAudioSession sharedInstance];

    [audioSession setPreferredSampleRate:opusConfig.sampleRate error:&audioSessionError];
    [audioSession setCategory:AVAudioSessionCategoryPlayback
                  withOptions:AVAudioSessionCategoryOptionMixWithOthers
                        error:&audioSessionError];
    [audioSession setPreferredIOBufferDuration:(opusConfig.samplesPerFrame / (opusConfig.sampleRate / 1000)) / 1000.0
                                         error:&audioSessionError];
    [audioSession setActive: YES error: &audioSessionError];
    
    // FIXME: Calling this breaks surround audio for some reason
    //[audioSession setPreferredOutputNumberOfChannels:opusConfig->channelCount error:&audioSessionError];
#endif

    OSStatus status;
    
    AudioStreamBasicDescription audioFormat = {0};
    audioFormat.mSampleRate = opusConfig.sampleRate;
    audioFormat.mBitsPerChannel = 16;
    audioFormat.mFormatID = kAudioFormatLinearPCM;
    audioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    audioFormat.mChannelsPerFrame = opusConfig.channelCount;
    audioFormat.mBytesPerFrame = audioFormat.mChannelsPerFrame * (audioFormat.mBitsPerChannel / 8);
    audioFormat.mBytesPerPacket = audioFormat.mBytesPerFrame;
    audioFormat.mFramesPerPacket = audioFormat.mBytesPerPacket / audioFormat.mBytesPerFrame;
    audioFormat.mReserved = 0;

    if (conn->_audioQueueContext == NULL) {
        conn->_audioQueueContext = (__bridge_retained void *)conn;
    }

    status = AudioQueueNewOutput(&audioFormat, FillOutputBuffer, conn->_audioQueueContext, nil, nil, 0, &conn->_audioQueue);
    if (status != noErr) {
        Log(LOG_E, @"Error allocating output queue: %d\n", status);
        if (conn->_audioQueueContext != NULL) {
            CFBridgingRelease(conn->_audioQueueContext);
            conn->_audioQueueContext = NULL;
        }
        return status;
    }
    
    // We need to specify a channel layout for surround sound configurations
    status = AudioQueueSetProperty(conn->_audioQueue, kAudioQueueProperty_ChannelLayout, &channelLayout, sizeof(channelLayout));
    if (status != noErr) {
        Log(LOG_E, @"Error configuring surround channel layout: %d\n", status);
        AudioQueueDispose(conn->_audioQueue, true);
        conn->_audioQueue = NULL;
        if (conn->_audioQueueContext != NULL) {
            CFBridgingRelease(conn->_audioQueueContext);
            conn->_audioQueueContext = NULL;
        }
        return status;
    }
    
    for (int i = 0; i < AUDIO_QUEUE_BUFFERS; i++) {
        status = AudioQueueAllocateBuffer(conn->_audioQueue, audioFormat.mBytesPerFrame * opusConfig.samplesPerFrame, &conn->_audioBuffers[i]);
        if (status != noErr) {
            Log(LOG_E, @"Error allocating output buffer: %d\n", status);
            AudioQueueDispose(conn->_audioQueue, true);
            conn->_audioQueue = NULL;
            if (conn->_audioQueueContext != NULL) {
                CFBridgingRelease(conn->_audioQueueContext);
                conn->_audioQueueContext = NULL;
            }
            return status;
        }

        FillOutputBuffer(conn->_audioQueueContext, conn->_audioQueue, conn->_audioBuffers[i]);
    }
    
    status = AudioQueueStart(conn->_audioQueue, nil);
    if (status != noErr) {
        Log(LOG_E, @"Error starting queue: %d\n", status);
        AudioQueueDispose(conn->_audioQueue, true);
        conn->_audioQueue = NULL;
        if (conn->_audioQueueContext != NULL) {
            CFBridgingRelease(conn->_audioQueueContext);
            conn->_audioQueueContext = NULL;
        }
        return status;
    }
    
    return status;
}

void ArCleanup(void)
{
    Connection *conn = CurrentConnection();
    if (conn == nil) {
        return;
    }

    if (conn->_opusDecoder != NULL) {
        opus_multistream_decoder_destroy(conn->_opusDecoder);
        conn->_opusDecoder = NULL;
    }
    
    // Stop before disposing to avoid massive delay inside
    // AudioQueueDispose() (iOS bug?)
    if (conn->_audioQueue != NULL) {
        AudioQueueStop(conn->_audioQueue, true);

        // Also frees buffers
        AudioQueueDispose(conn->_audioQueue, true);
        conn->_audioQueue = NULL;
    }
    
    // Must be freed after the queue is stopped
    if (conn->_audioCircularBuffer != NULL) {
        free(conn->_audioCircularBuffer);
        conn->_audioCircularBuffer = NULL;
    }

    if (conn->_audioQueueContext != NULL) {
        CFBridgingRelease(conn->_audioQueueContext);
        conn->_audioQueueContext = NULL;
    }
    
#if TARGET_OS_IPHONE
    // Audio session is now inactive
    [[AVAudioSession sharedInstance] setActive: NO error: nil];
#endif
}

void ArDecodeAndPlaySample(char* sampleData, int sampleLength)
{
    Connection *conn = CurrentConnection();
    if (conn == nil || conn->_opusDecoder == NULL) {
        return;
    }

    int decodeLen;
    
    // Check if there is space for this sample in the buffer. Again, this can race
    // but in the worst case, we'll not see the sample callback having consumed a sample.
    if (conn->_audioBufferEntries == 0 || ((conn->_audioBufferWriteIndex + 1) % conn->_audioBufferEntries) == conn->_audioBufferReadIndex) {
        return;
    }
    
    decodeLen = opus_multistream_decode(conn->_opusDecoder, (unsigned char *)sampleData, sampleLength,
                                        (short*)&conn->_audioCircularBuffer[conn->_audioBufferWriteIndex * conn->_audioBufferStride], conn->_audioSamplesPerFrame, 0);
    if (decodeLen > 0) {
        // Apply volume adjustment to each audio sample
        short* buffer = &conn->_audioCircularBuffer[conn->_audioBufferWriteIndex * conn->_audioBufferStride];
        for (int i = 0; i < decodeLen * conn->_channelCount; i++) {
            buffer[i] = (short)(buffer[i] * conn->_audioVolumeMultiplier);
        }
        
        // Use a full memory barrier to ensure the circular buffer is written before incrementing the index
        __sync_synchronize();
        
        // This can race with the reader in the sample callback, however this is a benign
        // race since we'll either read the original value of s_WriteIndex (which is safe,
        // we just won't consider this sample) or the new value of s_WriteIndex
        conn->_audioBufferWriteIndex = (conn->_audioBufferWriteIndex + 1) % conn->_audioBufferEntries;
    }
}

- (void)updateVolume {
    if (_hostAddress != nil) {
        NSString *uuid = [SettingsClass getHostUUIDFrom:_hostAddress];
        _audioVolumeMultiplier = [SettingsClass volumeLevelFor:uuid];
    }
}

void ClStageStarting(int stage)
{
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    if (callbacks) {
        [callbacks stageStarting:LiGetStageName(stage)];
    }
}

void ClStageComplete(int stage)
{
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    if (callbacks) {
        [callbacks stageComplete:LiGetStageName(stage)];
    }
}

void ClStageFailed(int stage, int errorCode)
{
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    if (callbacks) {
        [callbacks stageFailed:LiGetStageName(stage) withError:errorCode];
    }
}

void ClConnectionStarted(void)
{
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    Log(LOG_I, @"[diag] ClConnectionStarted: conn=%p callbacks=%p", conn, callbacks);
    if (!callbacks) {
        return;
    }

    PML_CONNECTION_CONTEXT callbackCtx = conn != nil ? &conn->_connectionContext : NULL;
    __weak Connection *weakMicConn = conn;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        if (callbackCtx != NULL) {
            LiSetThreadConnectionContext(callbackCtx);
        }

        Log(LOG_I, @"[diag] ClConnectionStarted dispatch begin: conn=%p callbacks=%p", conn, callbacks);
        [callbacks connectionStarted];
        Log(LOG_I, @"[diag] ClConnectionStarted callback returned");

#if defined(LI_MIC_CONTROL_START)
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong Connection *micConn = weakMicConn;
            if (micConn) {
                [micConn startMicrophoneIfNeeded];
            }
        });
#endif

        if (callbackCtx != NULL) {
            LiSetThreadConnectionContext(NULL);
        }
    });
}

void ClConnectionTerminated(int errorCode)
{
#if defined(LI_MIC_CONTROL_START)
    // Capture a weak reference to avoid retaining the connection if it's being deallocated
    __weak Connection *weakMicConn = CurrentConnection();
    // Stopping AVAudioEngine can occasionally block under CoreAudio stress.
    // Keep it off the main thread so UI doesn't appear frozen during disconnect.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong Connection *micConn = weakMicConn;
        if (micConn) {
            [micConn stopMicrophoneIfNeeded];
        }
    });
#endif
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    if (callbacks) {
        [callbacks connectionTerminated: errorCode];
    }
}

void ClLogMessage(const char* format, ...)
{
    static uint64_t lastDropLogTime = 0;
    static int accumulatedDropCount = 0;
    
    // Simple heuristic to detect dropped frame logs from common-c
    bool isDropLog = (strstr(format, "Network dropped") != NULL);
    bool isHighFrequencyDiagnostic = (strstr(format, "[inputdiag]") != NULL);

    if (isDropLog) {
        accumulatedDropCount++;
        uint64_t now = LiGetMillis();
        if (now - lastDropLogTime < 1000) {
            return; // Suppress this log
        }
        lastDropLogTime = now;
    }

    va_list va;
    va_start(va, format);

    if (!isHighFrequencyDiagnostic) {
        va_list stderrArgs;
        va_copy(stderrArgs, va);
        vfprintf(stderr, format, stderrArgs);
        va_end(stderrArgs);
    }

    va_list formatArgs;
    va_copy(formatArgs, va);
    char stackBuffer[2048];
    int requiredLength = vsnprintf(stackBuffer, sizeof(stackBuffer), format, formatArgs);
    va_end(formatArgs);

    NSString *formattedLine = nil;
    if (requiredLength >= 0 && requiredLength < (int)sizeof(stackBuffer)) {
        formattedLine = [NSString stringWithUTF8String:stackBuffer];
    } else if (requiredLength >= (int)sizeof(stackBuffer)) {
        size_t heapLength = (size_t)requiredLength + 1;
        char *heapBuffer = malloc(heapLength);
        if (heapBuffer != NULL) {
            va_list heapArgs;
            va_copy(heapArgs, va);
            vsnprintf(heapBuffer, heapLength, format, heapArgs);
            va_end(heapArgs);
            formattedLine = [NSString stringWithUTF8String:heapBuffer];
            free(heapBuffer);
        }
    }

    va_end(va);

    if (formattedLine.length > 0) {
        NSString *trimmedLine = [formattedLine stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        if (trimmedLine.length > 0) {
            LogLevel derivedLevel = isDropLog ? LOG_W : (isHighFrequencyDiagnostic ? LOG_D : LOG_I);
            [[LogBuffer shared] appendLine:trimmedLine level:derivedLevel];
            if (isHighFrequencyDiagnostic && LoggerIsInputDiagnosticsEnabled()) {
                LoggerPersistMessage(derivedLevel, trimmedLine);
            }
        }
    }

    if (isDropLog && accumulatedDropCount > 1) {
        NSString *summaryLine = [NSString stringWithFormat:@"(and %d more dropped frame messages suppressed)", accumulatedDropCount - 1];
        fprintf(stderr, " %s\n", summaryLine.UTF8String);
        [[LogBuffer shared] appendLine:summaryLine level:LOG_W];
        accumulatedDropCount = 0;
    }
}

void ClRumble(unsigned short controllerNumber, unsigned short lowFreqMotor, unsigned short highFreqMotor)
{
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    if (callbacks) {
        [callbacks rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
    }
}

void ClConnectionStatusUpdate(int status)
{
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    if (callbacks) {
        [callbacks connectionStatusUpdate:status];
    }
}

- (void)dealloc
{
    // Remove notification observer to prevent crashes from stale references
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

-(void) terminate
{
    // Interrupt any action blocking LiStartConnection(). This is
    // thread-safe and done outside initLock on purpose, since we
    // won't be able to acquire it if LiStartConnection is in
    // progress.
    LiInterruptConnectionCtx(&_connectionContext);

#if defined(LI_MIC_CONTROL_START)
    // Ensure mic queue is stopped before connection context teardown
    [self stopMicrophoneIfNeeded];
#endif

    // We dispatch this async to get out because this can be invoked
    // on a thread inside common and we don't want to deadlock. It also avoids
    // blocking on the caller's thread waiting to acquire initLock.
    // IMPORTANT: Capture self strongly in the block to keep the Connection object
    // alive until LiStopConnectionCtx finishes. The context pointer points to
    // an embedded struct inside self, so self must outlive the async block.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        // Prevent self from being deallocated during cleanup
        __strong Connection *conn = self;
        if (conn == nil) {
            return;
        }
        PML_CONNECTION_CONTEXT ctx = &conn->_connectionContext;
        os_unfair_lock_lock(&gConnectionLifecycleLock);
        LiStopConnectionCtx(ctx);
        os_unfair_lock_unlock(&gConnectionLifecycleLock);
        UnregisterConnection(ctx);
        // conn is released here after the block completes, ensuring
        // the Connection object stays alive throughout cleanup
    });
}

-(id) initWithConfig:(StreamConfiguration*)config renderer:(VideoDecoderRenderer*)myRenderer connectionCallbacks:(id<ConnectionCallbacks>)callbacks
{
    self = [super init];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateVolume) name:@"volumeSettingChanged" object:nil];
    
    // Use a lock to ensure that only one thread is initializing
    // or deinitializing a connection at a time.
    if (_initLock == nil) {
        _initLock = [[NSLock alloc] init];
    }
    
    _hostAddress = config.host;
    _audioVolumeMultiplier = 1.0f;
    _stateLock = OS_UNFAIR_LOCK_INIT;
    [self updateVolume];
    
    NSString* cleanHost;
    [Utils parseAddress:config.host intoHost:&cleanHost andPort:nil];
    
    strncpy(_hostString,
            [cleanHost cStringUsingEncoding:NSUTF8StringEncoding],
            sizeof(_hostString));
    strncpy(_appVersionString,
            [config.appVersion cStringUsingEncoding:NSUTF8StringEncoding],
            sizeof(_appVersionString));
    if (config.gfeVersion != nil) {
        strncpy(_gfeVersionString,
                [config.gfeVersion cStringUsingEncoding:NSUTF8StringEncoding],
                sizeof(_gfeVersionString));
    }

    LiInitializeServerInformation(&_serverInfo);
    _serverInfo.address = _hostString;
    _serverInfo.serverInfoAppVersion = _appVersionString;
    // Some common-c forks (e.g. microphone protocol branches) assert that this field must be set.
    // If the host hasn't been refreshed yet and we don't have it, fall back to the safest baseline.
    _serverInfo.serverCodecModeSupport = (config.serverCodecModeSupport != 0) ? config.serverCodecModeSupport : SCM_H264;
    if (config.gfeVersion != nil) {
        _serverInfo.serverInfoGfeVersion = _gfeVersionString;
    }

    if (config.sessionUrl != nil) {
        strncpy(_rtspSessionUrl, [config.sessionUrl UTF8String], sizeof(_rtspSessionUrl) - 1);
        _rtspSessionUrl[sizeof(_rtspSessionUrl) - 1] = '\0';
        _serverInfo.rtspSessionUrl = _rtspSessionUrl;
    }

    ConnectionSetRenderer(self, myRenderer);
    ConnectionSetCallbacks(self, callbacks);
    _currentUpscalingMode = config.upscalingMode;
    _rendererStreamConfig = config;

    memset(&_connectionContext, 0, sizeof(_connectionContext));

    // Initialize all socket fields to INVALID_SOCKET (-1) after memset zeroes them to 0.
    // This prevents EXC_GUARD crashes on macOS when closeSocket() is called on an
    // uninitialized socket field (fd 0 = stdin is guarded on macOS).
    _connectionContext.videoContext.rtpSocket = INVALID_SOCKET;
    _connectionContext.videoContext.firstFrameSocket = INVALID_SOCKET;
    _connectionContext.audioContext.rtpSocket = INVALID_SOCKET;
    _connectionContext.controlContext.ctlSock = INVALID_SOCKET;
    _connectionContext.inputContext.inputSock = INVALID_SOCKET;
    _connectionContext.micContext.micSocket = INVALID_SOCKET;
    RegisterConnection(&_connectionContext, self);
    VideoDecoderRenderer *renderer = ConnectionGetRendererSnapshot(self);
    if (renderer) {
        renderer.depacketizerContext = &_connectionContext.videoContext.depacketizerContext;
    }

    LiInitializeStreamConfiguration(&_streamConfig);
    _streamConfig.width = config.width;
    _streamConfig.height = config.height;
    _streamConfig.fps = config.frameRate;
    _streamConfig.bitrate = config.bitRate;
    _streamConfig.audioConfiguration = config.audioConfiguration;
    _streamConfig.colorSpace = COLORSPACE_REC_709;

#if defined(LI_MIC_CONTROL_START)
    // Enable microphone streaming only if requested in settings. The host may ignore it.
    BOOL enableMic = NO;
    @try {
        NSString* uuid = config.hostUUID;
        if (uuid == nil && config.host != nil) {
            uuid = [SettingsClass getHostUUIDFrom:config.host];
        }

        NSString* settingsKey = uuid != nil ? uuid : @"__global__";
        NSDictionary* settings = [SettingsClass getSettingsFor:settingsKey];
        if (settings != nil) {
            enableMic = [settings[@"microphone"] boolValue];
        }
        Log(LOG_I, @"Microphone setting: enableMic=%d host=%@ uuid=%@ key=%@",
            enableMic, config.host, uuid, settingsKey);
    } @catch (NSException* exception) {
        Log(LOG_W, @"Exception reading microphone setting: %@", exception);
        enableMic = NO;
    }

    _streamConfig.enableMic = enableMic;
    if (enableMic) {
        _streamConfig.encryptionFlags |= ENCFLG_MICROPHONE;
    }
#endif

#if !defined(VIDEO_FORMAT_H264_HIGH8_444)
    // Legacy moonlight-common-c
    _streamConfig.enableHdr = config.enableHdr;

    // Use some of the HEVC encoding efficiency improvements to
    // reduce bandwidth usage while still gaining some image
    // quality improvement.
    _streamConfig.hevcBitratePercentageMultiplier = 75;
#endif
    
    // Resolve LOCAL/REMOTE for packet sizing with target-route evidence.
    // This avoids misclassifying local sessions when a VPN/proxy app is active but not used by this stream.
    BOOL remoteByConfig = config.streamingRemotely;
    BOOL vpnActive = [Utils isActiveNetworkVPN];
    NSString *egressSource = nil;
    NSString *egressIf = [Utils outboundInterfaceNameForAddress:config.host sourceAddress:&egressSource];
    BOOL routeKnown = egressIf.length > 0;
    BOOL routeThroughTunnel = routeKnown && [Utils isTunnelInterfaceName:egressIf];
    BOOL remoteByVpnFallback = vpnActive && !routeKnown && !remoteByConfig;
    BOOL useRemotePacketConfig = remoteByConfig || routeThroughTunnel || remoteByVpnFallback;

    if (routeThroughTunnel && !config.autoAdjustBitrate && _streamConfig.fps >= 120 && _streamConfig.bitrate >= 12000) {
        Log(LOG_W, @"[diag] Tunnel manual profile may be too aggressive: fps=%d bitrate=%d (consider <=90fps or <=10000kbps)",
            _streamConfig.fps,
            _streamConfig.bitrate);
    }

    if (routeThroughTunnel && config.autoAdjustBitrate) {
        int tunnelBitrateCap = 8000;
        if (_streamConfig.fps >= 90) {
            tunnelBitrateCap = 12000;
        } else if (_streamConfig.fps >= 60) {
            tunnelBitrateCap = 10000;
        }
        if (_streamConfig.bitrate > tunnelBitrateCap) {
            Log(LOG_I, @"[diag] Tunnel bitrate cap applied: %d -> %d (fps=%d)",
                _streamConfig.bitrate,
                tunnelBitrateCap,
                _streamConfig.fps);
            _streamConfig.bitrate = tunnelBitrateCap;
        }
    } else if (routeThroughTunnel) {
        Log(LOG_I, @"[diag] Tunnel bitrate auto-cap skipped: autoAdjustBitrate=0 (fps=%d bitrate=%d)",
            _streamConfig.fps,
            _streamConfig.bitrate);
    }

    Log(LOG_I, @"[diag] Packet config classification: host=%@ remoteByConfig=%d routeKnown=%d routeTunnel=%d vpn=%d vpnFallback=%d egressIf=%@ source=%@ useRemote=%d",
        config.host ?: @"(null)",
        remoteByConfig ? 1 : 0,
        routeKnown ? 1 : 0,
        routeThroughTunnel ? 1 : 0,
        vpnActive ? 1 : 0,
        remoteByVpnFallback ? 1 : 0,
        egressIf ?: @"(unknown)",
        egressSource ?: @"",
        useRemotePacketConfig ? 1 : 0);

    if (useRemotePacketConfig) {
        _streamConfig.streamingRemotely = STREAM_CFG_REMOTE;
        // For tunnel paths (utun/wg), prioritize MTU safety over lower PPS.
        // Empirically, larger payloads such as 1024 bytes can behave worse than
        // 896 bytes on encapsulated/overlay routes even at lower frame rates,
        // likely due to effective PMTU headroom and loss amplification.
        if (routeThroughTunnel) {
            _streamConfig.packetSize = 896;
            Log(LOG_I, @"[diag] Tunnel MTU-first packet mode: fps=%d bitrate=%d packet=%d",
                _streamConfig.fps,
                _streamConfig.bitrate,
                _streamConfig.packetSize);
        }
        else if (_streamConfig.fps >= 120) {
            _streamConfig.packetSize = 896;
            Log(LOG_I, @"[diag] Public remote MTU-first packet mode: fps=%d bitrate=%d packet=%d",
                _streamConfig.fps,
                _streamConfig.bitrate,
                _streamConfig.packetSize);
        }
        else {
            _streamConfig.packetSize = 1024;
        }
    } else {
        _streamConfig.streamingRemotely = STREAM_CFG_LOCAL;
        _streamConfig.packetSize = 1392;
    }

    Log(LOG_I, @"[diag] Packet size chosen: %d (remote=%d tunnel=%d)",
        _streamConfig.packetSize,
        _streamConfig.streamingRemotely == STREAM_CFG_REMOTE ? 1 : 0,
        routeThroughTunnel ? 1 : 0);
    
    // HDR implies HEVC allowed
    if (config.enableHdr) {
        config.allowHevc = YES;
    }

    // On iOS 11, we can use HEVC if the server supports encoding it
    // and this device has hardware decode for it (A9 and later).
    // Additionally, iPhone X had a bug which would cause video
    // to freeze after a few minutes with HEVC prior to iOS 11.3.
    // As a result, we will only use HEVC on iOS 11.3 or later.
#if defined(VIDEO_FORMAT_H264_HIGH8_444)
    // Newer moonlight-common-c uses supportedVideoFormats for codec negotiation.
    int codecPreference = config.videoCodecPreference;
    BOOL hevcDecodeSupported = NO;
    if (@available(iOS 11.3, tvOS 11.3, macOS 10.14, *)) {
        hevcDecodeSupported = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);
    }
    BOOL hevcSupported = codecPreference >= 1 && hevcDecodeSupported;
    BOOL av1Supported = codecPreference >= 2 && VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1);

    // If HDR is requested, at least one 10-bit codec path must be available.
    assert(!config.enableHdr || hevcSupported || av1Supported);

    BOOL enableYuv444 = NO;
    @try {
        NSString* uuid = config.hostUUID;
        if (uuid == nil && config.host != nil) {
            uuid = [SettingsClass getHostUUIDFrom:config.host];
        }

        NSString* settingsKey = uuid != nil ? uuid : @"__global__";
        NSDictionary* settings = [SettingsClass getSettingsFor:settingsKey];
        if (settings != nil) {
            enableYuv444 = [settings[@"yuv444"] boolValue];
        }
    } @catch (NSException* exception) {
        enableYuv444 = NO;
    }

    int supportedVideoFormats = VIDEO_FORMAT_H264;
    if (hevcSupported) {
        supportedVideoFormats |= VIDEO_FORMAT_H265;
        if (config.enableHdr) {
            supportedVideoFormats |= VIDEO_FORMAT_H265_MAIN10;
        }
    }

    if (enableYuv444) {
        supportedVideoFormats |= VIDEO_FORMAT_H264_HIGH8_444;
        if (hevcSupported) {
            supportedVideoFormats |= VIDEO_FORMAT_H265_REXT8_444;
            if (config.enableHdr) {
                supportedVideoFormats |= VIDEO_FORMAT_H265_REXT10_444;
            }
        }
    }

    if (av1Supported && !enableYuv444) {
        if (config.enableHdr) {
            supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN10;
        } else {
            supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN8;
        }
    }

    _streamConfig.supportedVideoFormats = supportedVideoFormats;
    Log(LOG_I, @"[diag] Codec preference resolved: pref=%d av1=%d hevc=%d hdr=%d yuv444=%d formats=0x%X",
        codecPreference,
        av1Supported ? 1 : 0,
        hevcSupported ? 1 : 0,
        config.enableHdr ? 1 : 0,
        enableYuv444 ? 1 : 0,
        supportedVideoFormats);
#else
    if (@available(iOS 11.3, tvOS 11.3, macOS 10.14, *)) {
        _streamConfig.supportsHevc = config.allowHevc && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);
    }

    // HEVC must be supported when HDR is enabled
    assert(!_streamConfig.enableHdr || _streamConfig.supportsHevc);
#endif

    memcpy(_streamConfig.remoteInputAesKey, [config.riKey bytes], [config.riKey length]);
    memset(_streamConfig.remoteInputAesIv, 0, 16);
    int riKeyId = htonl(config.riKeyId);
    memcpy(_streamConfig.remoteInputAesIv, &riKeyId, sizeof(riKeyId));

    LiInitializeVideoCallbacks(&_drCallbacks);
    _drCallbacks.setup = DrDecoderSetup;
    _drCallbacks.start = DrStart;
    _drCallbacks.stop = DrStop;

//#if TARGET_OS_IPHONE
    // RFI doesn't work properly with HEVC on iOS 11 with an iPhone SE (at least)
    // It doesnt work on macOS either, tested with Network Link Conditioner.
    _drCallbacks.capabilities = CAPABILITY_PULL_RENDERER |
                                CAPABILITY_REFERENCE_FRAME_INVALIDATION_HEVC |
                                CAPABILITY_REFERENCE_FRAME_INVALIDATION_AV1;
//#endif

    LiInitializeAudioCallbacks(&_arCallbacks);
    _arCallbacks.init = ArInit;
    _arCallbacks.cleanup = ArCleanup;
    _arCallbacks.decodeAndPlaySample = ArDecodeAndPlaySample;
    _arCallbacks.capabilities = CAPABILITY_DIRECT_SUBMIT |
                                CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION;

    LiInitializeConnectionCallbacks(&_clCallbacks);
    _clCallbacks.stageStarting = ClStageStarting;
    _clCallbacks.stageComplete = ClStageComplete;
    _clCallbacks.stageFailed = ClStageFailed;
    _clCallbacks.connectionStarted = ClConnectionStarted;
    _clCallbacks.connectionTerminated = ClConnectionTerminated;
    _clCallbacks.logMessage = ClLogMessage;
    _clCallbacks.rumble = ClRumble;
    _clCallbacks.connectionStatusUpdate = ClConnectionStatusUpdate;

    return self;
}

- (void *)inputStreamContext {
    return LiGetInputContextFromConnectionCtx(&_connectionContext);
}

- (void *)controlStreamContext {
    return &_connectionContext.controlContext;
}

- (BOOL)getVideoDiagnosticSnapshot:(MLVideoDiagnosticSnapshot *)snapshot {
    if (snapshot == NULL) {
        return NO;
    }

    memset(snapshot, 0, sizeof(*snapshot));

    snapshot->appVersionMajor = _connectionContext.AppVersionQuad[0];
    snapshot->appVersionMinor = _connectionContext.AppVersionQuad[1];
    snapshot->appVersionPatch = _connectionContext.AppVersionQuad[2];
    snapshot->videoReceivedDataFromPeer = _connectionContext.videoContext.receivedDataFromPeer ? YES : NO;
    snapshot->videoReceivedFullFrame = _connectionContext.videoContext.receivedFullFrame ? YES : NO;
    snapshot->videoRtpSocketValid = _connectionContext.videoContext.rtpSocket != INVALID_SOCKET ? 1 : 0;
    snapshot->videoCurrentFrameNumber = _connectionContext.videoContext.rtpQueue.currentFrameNumber;
    snapshot->videoMissingPackets = _connectionContext.videoContext.rtpQueue.missingPackets;
    snapshot->videoPendingFecBlocks = _connectionContext.videoContext.rtpQueue.pendingFecBlockList.count;
    snapshot->videoCompletedFecBlocks = _connectionContext.videoContext.rtpQueue.completedFecBlockList.count;
    snapshot->videoBufferDataPackets = _connectionContext.videoContext.rtpQueue.bufferDataPackets;
    snapshot->videoBufferParityPackets = _connectionContext.videoContext.rtpQueue.bufferParityPackets;
    snapshot->videoReceivedDataPackets = _connectionContext.videoContext.rtpQueue.receivedDataPackets;
    snapshot->videoReceivedParityPackets = _connectionContext.videoContext.rtpQueue.receivedParityPackets;
    snapshot->videoReceivedHighestSequenceNumber = _connectionContext.videoContext.rtpQueue.receivedHighestSequenceNumber;
    snapshot->videoNextContiguousSequenceNumber = _connectionContext.videoContext.rtpQueue.nextContiguousSequenceNumber;

    return YES;
}

#if defined(LI_MIC_CONTROL_START)
- (void)notifyInputStreamReadyForMicrophoneControlIfNeeded
{
    if (!_streamConfig.enableMic || _micStopping || _micControlStarted) {
        return;
    }

    if (self.micAudioEngine == nil || !self.micAudioEngine.isRunning) {
        return;
    }

    if (!_connectionContext.inputContext.initialized) {
        return;
    }

    _micControlStarted = [self sendMicrophoneControlPacket:LI_MIC_CONTROL_START reason:@"start-input-ready"];
}

- (void)startMicrophoneIfNeeded
{
    if (!_streamConfig.enableMic) {
        Log(LOG_I, @"Microphone disabled in settings, skipping mic start");
        return;
    }
    Log(LOG_I, @"Starting microphone capture...");

    _micSendFailures = 0;
    _micStopping = NO;
    _micControlStarted = NO;
    _micEncryptionStatusLogged = NO;

    // Create encoder/queue once
    if (_micQueue == nil) {
        _micQueue = dispatch_queue_create("moonlight.mic.encode", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_micQueue, gMicQueueKey, gMicQueueKey, NULL);
    }
    if (_micPcmQueue == nil) {
        _micPcmQueue = [NSMutableData data];
    }

    // Ask for permission on macOS
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
        if (!granted) {
            Log(LOG_W, @"Microphone permission denied\n");
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self startMicrophoneEngineLocked];
        });
    }];
}

- (AudioDeviceID)audioDeviceIDForUID:(NSString*)uid
{
    AudioObjectPropertyAddress propAddr = {
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propAddr, 0, NULL, &dataSize);
    if (status != noErr) return 0;

    int count = (int)(dataSize / sizeof(AudioDeviceID));
    AudioDeviceID* devices = malloc(dataSize);
    if (!devices) return 0;

    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propAddr, 0, NULL, &dataSize, devices);
    if (status != noErr) { free(devices); return 0; }

    AudioDeviceID result = 0;
    for (int i = 0; i < count; i++) {
        AudioObjectPropertyAddress uidAddr = {
            .mSelector = kAudioDevicePropertyDeviceUID,
            .mScope = kAudioObjectPropertyScopeGlobal,
            .mElement = kAudioObjectPropertyElementMain
        };
        CFStringRef deviceUID = NULL;
        UInt32 uidSize = sizeof(CFStringRef);
        if (AudioObjectGetPropertyData(devices[i], &uidAddr, 0, NULL, &uidSize, &deviceUID) == noErr && deviceUID) {
            if ([(__bridge NSString*)deviceUID isEqualToString:uid]) {
                result = devices[i];
                CFRelease(deviceUID);
                break;
            }
            CFRelease(deviceUID);
        }
    }
    free(devices);
    return result;
}

- (BOOL)sendMicrophoneControlPacket:(uint8_t)control reason:(NSString *)reason
{
    PML_INPUT_STREAM_CONTEXT inputCtx = &_connectionContext.inputContext;
    if (!inputCtx->initialized) {
        Log(LOG_W, @"Skipping microphone control %@: input stream not initialized", reason);
        return NO;
    }

    int err = LiSendMicrophoneControlCtx(inputCtx,
                                         control,
                                         micSampleRate,
                                         micChannels,
                                         micBitrate);
    if (err < 0) {
        Log(LOG_W, @"Failed to send microphone control %@: %d", reason, err);
        return NO;
    }

    Log(LOG_I, @"Sent microphone control %@ (rate=%d channels=%d bitrate=%d)",
        reason,
        micSampleRate,
        micChannels,
        micBitrate);
    return YES;
}

- (void)startMicrophoneEngineLocked
{
    if (self.micAudioEngine != nil && self.micAudioEngine.isRunning) {
        return;
    }

    if (initializeMicrophoneStreamCtx(&_connectionContext.micContext, &_connectionContext) != 0) {
        Log(LOG_W, @"Failed to initialize microphone stream socket\n");
        return;
    }

    // Log resolved addresses for diagnosis
    {
        char connAddrStr[INET6_ADDRSTRLEN] = {0};
        char micAddrStr[INET6_ADDRSTRLEN] = {0};
        struct sockaddr_storage *connAddr = &_connectionContext.RemoteAddr;
        struct sockaddr_storage *micAddr = &_connectionContext.micContext.micRemoteAddr;
        if (connAddr->ss_family == AF_INET) {
            inet_ntop(AF_INET, &((struct sockaddr_in*)connAddr)->sin_addr, connAddrStr, sizeof(connAddrStr));
        } else if (connAddr->ss_family == AF_INET6) {
            inet_ntop(AF_INET6, &((struct sockaddr_in6*)connAddr)->sin6_addr, connAddrStr, sizeof(connAddrStr));
        }
        if (micAddr->ss_family == AF_INET) {
            inet_ntop(AF_INET, &((struct sockaddr_in*)micAddr)->sin_addr, micAddrStr, sizeof(micAddrStr));
        } else if (micAddr->ss_family == AF_INET6) {
            inet_ntop(AF_INET6, &((struct sockaddr_in6*)micAddr)->sin6_addr, micAddrStr, sizeof(micAddrStr));
        }
        Log(LOG_I, @"Mic diag: connRemoteAddr=%s (family=%d addrLen=%d) micRemoteAddr=%s (family=%d addrLen=%d) micPort=%u",
            connAddrStr, connAddr->ss_family, _connectionContext.AddrLen,
            micAddrStr, micAddr->ss_family, _connectionContext.micContext.micAddrLen,
            _connectionContext.micContext.micPortNumber);
    }

    _micPingCount = 0;
    _micLastPingTimeMs = PltGetMillis();
    Log(LOG_I, @"Mic mode: default");

    int err = 0;
    if (_micEncoder == NULL) {
        unsigned char mapping[1] = { 0 };
        _micEncoder = opus_multistream_encoder_create(micSampleRate,
                                                      micChannels,
                                                      1, /* streams */
                                                      0, /* coupled */
                                                      mapping,
                                                      OPUS_APPLICATION_VOIP,
                                                      &err);
        if (_micEncoder == NULL || err != OPUS_OK) {
            Log(LOG_W, @"Failed to create Opus encoder for microphone: %d\n", err);
            _micEncoder = NULL;
            return;
        }

        opus_multistream_encoder_ctl(_micEncoder, OPUS_SET_BITRATE(micBitrate));
    }

    self.micAudioEngine = [[AVAudioEngine alloc] init];

    // Set selected microphone device if configured
    NSString* micDeviceUID = [[NSUserDefaults standardUserDefaults] stringForKey:@"selectedMicDeviceUID"];
    if (micDeviceUID.length > 0) {
        AudioDeviceID deviceID = [self audioDeviceIDForUID:micDeviceUID];
        if (deviceID != 0) {
            AVAudioInputNode* inputNode = self.micAudioEngine.inputNode;
            AudioUnit audioUnit = inputNode.audioUnit;
            if (audioUnit != NULL) {
                OSStatus status = AudioUnitSetProperty(audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0,
                    &deviceID, sizeof(AudioDeviceID));
                Log(LOG_I, @"Mic device set: uid=%@ deviceID=%u status=%d", micDeviceUID, deviceID, (int)status);
            }
        } else {
            Log(LOG_W, @"Mic device not found for UID: %@, using system default", micDeviceUID);
        }
    }

    AVAudioInputNode* input = self.micAudioEngine.inputNode;
    self.micOutputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                            sampleRate:micSampleRate
                                                              channels:micChannels
                                                           interleaved:YES];

    // Use the hardware input format and convert manually.
    // Passing a non-nil format to installTapOnBus can throw an exception on some devices
    // when AVAudioIONodeImpl::SetOutputFormat rejects the requested conversion.
    AVAudioFormat* hwFormat = [input outputFormatForBus:0];
    Log(LOG_I, @"Microphone hardware format: %@", hwFormat);

    // Check if we can do a direct Float32→Int16 conversion (same sample rate)
    BOOL directConvert = (fabs(hwFormat.sampleRate - micSampleRate) < 1.0 &&
                          hwFormat.commonFormat == AVAudioPCMFormatFloat32);

    if (!directConvert) {
        // Create a converter from hardware format → 48 kHz mono int16
        self.micConverter = [[AVAudioConverter alloc] initFromFormat:hwFormat toFormat:self.micOutputFormat];
        if (self.micConverter == nil) {
            Log(LOG_W, @"Cannot create AVAudioConverter from %@ to %@", hwFormat, self.micOutputFormat);
            self.micAudioEngine = nil;
            return;
        }
        Log(LOG_I, @"Microphone using AVAudioConverter (sample rate conversion needed)");
    } else {
        Log(LOG_I, @"Microphone using direct Float32→Int16 conversion (same sample rate)");
    }

    __weak typeof(self) weakSelf = self;
    __block BOOL micDataLogged = NO;
    __block int micAmplitudeLogCount = 0;
    [input removeTapOnBus:0];

    @try {
        // Pass nil format to receive audio in the hardware's native format.
        [input installTapOnBus:0 bufferSize:(AVAudioFrameCount)(micFrameSize * (hwFormat.sampleRate / micSampleRate + 1)) format:nil block:^(AVAudioPCMBuffer* buffer, AVAudioTime* when) {
            __strong typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil || !strongSelf->_streamConfig.enableMic) {
                return;
            }

            NSData* chunk = nil;

            if (directConvert) {
                // Direct Float32 → Int16 conversion (bypasses AVAudioConverter entirely)
                const float* srcFloat = buffer.floatChannelData ? buffer.floatChannelData[0] : NULL;
                AVAudioFrameCount srcFrames = buffer.frameLength;
                if (srcFloat == NULL || srcFrames == 0) {
                    return;
                }

                NSMutableData* pcmData = [NSMutableData dataWithLength:srcFrames * sizeof(int16_t)];
                int16_t* dst = (int16_t*)pcmData.mutableBytes;
                float maxAbs = 0.0f;
                for (AVAudioFrameCount i = 0; i < srcFrames; i++) {
                    float raw = srcFloat[i];
                    float absVal = raw < 0 ? -raw : raw;
                    if (absVal > maxAbs) maxAbs = absVal;
                    float s = raw * 32767.0f;
                    if (s > 32767.0f) s = 32767.0f;
                    else if (s < -32768.0f) s = -32768.0f;
                    dst[i] = (int16_t)s;
                }
                // Log amplitude of first 10 buffers to verify real audio
                if (micAmplitudeLogCount < 10) {
                    micAmplitudeLogCount++;
                    Log(LOG_I, @"Mic amplitude [%d]: maxAbs=%.6f frames=%u (Int16 max=%d)",
                        micAmplitudeLogCount, maxAbs, (unsigned)srcFrames, (int)(maxAbs * 32767.0f));
                }
                chunk = pcmData;
            } else {
                // Use AVAudioConverter for sample rate conversion
                AVAudioConverter* converter = strongSelf.micConverter;
                AVAudioFormat* outFmt = strongSelf.micOutputFormat;
                if (converter == nil || outFmt == nil) {
                    return;
                }

                AVAudioFrameCount outputFrames = (AVAudioFrameCount)(buffer.frameLength * micSampleRate / hwFormat.sampleRate) + 1;
                AVAudioPCMBuffer* converted = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outFmt frameCapacity:outputFrames];
                if (converted == nil) {
                    return;
                }

                __block BOOL inputConsumed = NO;
                NSError* convErr = nil;
                [converter convertToBuffer:converted error:&convErr withInputFromBlock:^AVAudioBuffer* _Nullable(AVAudioFrameCount inNumberOfPackets, AVAudioConverterInputStatus* _Nonnull outStatus) {
                    if (inputConsumed) {
                        *outStatus = AVAudioConverterInputStatus_NoDataNow;
                        return nil;
                    }
                    inputConsumed = YES;
                    *outStatus = AVAudioConverterInputStatus_HaveData;
                    return buffer;
                }];

                if (convErr != nil || converted.frameLength == 0) {
                    if (!micDataLogged) {
                        Log(LOG_W, @"AVAudioConverter error: %@ (frames=%u)", convErr, (unsigned)converted.frameLength);
                        micDataLogged = YES;
                    }
                    return;
                }

                const AudioBufferList* abl = converted.audioBufferList;
                if (abl == NULL || abl->mNumberBuffers < 1) {
                    return;
                }
                const AudioBuffer ab = abl->mBuffers[0];
                if (ab.mData == NULL || ab.mDataByteSize == 0) {
                    return;
                }
                chunk = [NSData dataWithBytes:ab.mData length:(NSUInteger)ab.mDataByteSize];
            }

            if (chunk == nil || chunk.length == 0) {
                return;
            }

            if (!micDataLogged) {
                Log(LOG_I, @"Microphone PCM data flowing: %lu bytes per tap callback", (unsigned long)chunk.length);
                micDataLogged = YES;
            }

            dispatch_async(strongSelf->_micQueue, ^{
                [strongSelf->_micPcmQueue appendData:chunk];
                [strongSelf drainMicPcmAndSend];
            });
        }];
    } @catch (NSException* exception) {
        Log(LOG_W, @"Failed to install microphone tap: %@ - %@", exception.name, exception.reason);
        self.micAudioEngine = nil;
        self.micConverter = nil;
        return;
    }

    NSError* startErr = nil;
    BOOL started = [self.micAudioEngine startAndReturnError:&startErr];
    if (!started || startErr != nil) {
        Log(LOG_W, @"Failed to start microphone capture: %@\n", startErr.localizedDescription);
        [self.micAudioEngine stop];
        self.micAudioEngine = nil;
        self.micConverter = nil;
        _micControlStarted = NO;
        return;
    }

    _micControlStarted = [self sendMicrophoneControlPacket:LI_MIC_CONTROL_START reason:@"start"];
}

- (void)drainMicPcmAndSend
{
    if (_micEncoder == NULL || _micStopping || !_streamConfig.enableMic) {
        return;
    }

    LiSetThreadConnectionContext(&_connectionContext);

    if (!_micControlStarted && _connectionContext.inputContext.initialized) {
        _micControlStarted = [self sendMicrophoneControlPacket:LI_MIC_CONTROL_START reason:@"start-deferred"];
    }

    if (!_micEncryptionStatusLogged) {
        BOOL micEncryptionEnabled = (_connectionContext.EncryptionFeaturesEnabled & SS_ENC_MICROPHONE) != 0;
        Log(LOG_I, @"Microphone uplink encryption negotiated: %@", micEncryptionEnabled ? @"enabled" : @"disabled");
        _micEncryptionStatusLogged = YES;
    }

    const NSUInteger bytesPerFrame = sizeof(int16_t) * micChannels;
    const NSUInteger packetPcmBytes = (NSUInteger)micFrameSize * bytesPerFrame;

    while (_micPcmQueue.length >= packetPcmBytes) {
        const int16_t* pcm = (const int16_t*)_micPcmQueue.bytes;

        unsigned char opusPayload[1500];
        int opusLen = opus_multistream_encode(_micEncoder, pcm, micFrameSize, opusPayload, (opus_int32)sizeof(opusPayload));
        if (opusLen > 0) {
            int sent = sendMicrophoneOpusDataCtx(&_connectionContext.micContext,
                                                 opusPayload,
                                                 opusLen);

            if (sent < 0) {
                _micSendFailures++;
                if (sent == -1 || _micSendFailures >= 5) {
                    Log(LOG_W, @"sendMicrophoneData failed: %d (stopping mic)\n", sent);
                    _streamConfig.enableMic = NO;
                    [self stopMicrophoneIfNeeded];
                    return;
                }
            } else {
                _micSendFailures = 0;
            }
        }

        [_micPcmQueue replaceBytesInRange:NSMakeRange(0, packetPcmBytes) withBytes:NULL length:0];
    }
}

- (void)stopMicrophoneIfNeeded
{
    _micStopping = YES;
    if (_micControlStarted) {
        [self sendMicrophoneControlPacket:LI_MIC_CONTROL_STOP reason:@"stop"];
        _micControlStarted = NO;
    }
    _micEncryptionStatusLogged = NO;

    if (self.micAudioEngine != nil) {
        [self.micAudioEngine.inputNode removeTapOnBus:0];
        [self.micAudioEngine stop];
        self.micAudioEngine = nil;
    }
    self.micConverter = nil;

    _micSendFailures = 0;
    if (_micEncoder != NULL) {
        opus_multistream_encoder_destroy(_micEncoder);
        _micEncoder = NULL;
    }

    dispatch_block_t clearBlock = ^{
        [self->_micPcmQueue setLength:0];
    };
    if (_micQueue != nil) {
        if (dispatch_get_specific(gMicQueueKey) == gMicQueueKey) {
            clearBlock();
        } else {
            dispatch_sync(_micQueue, clearBlock);
        }
    } else {
        clearBlock();
    }

    _micQueue = nil;
    destroyMicrophoneStreamCtx(&_connectionContext.micContext);
}
#endif

static void FillOutputBuffer(void *aqData,
                             AudioQueueRef inAQ,
                             AudioQueueBufferRef inBuffer) {
    Connection *conn = (__bridge Connection *)aqData;
    UInt32 bytesPerBuffer = (conn && conn->_audioBufferStride > 0) ? (UInt32)(conn->_audioBufferStride * sizeof(short)) : 0;
    if (conn == nil || bytesPerBuffer == 0 || conn->_audioCircularBuffer == NULL || conn->_audioBufferEntries == 0) {
        bytesPerBuffer = MIN(inBuffer->mAudioDataBytesCapacity, bytesPerBuffer);
        inBuffer->mAudioDataByteSize = bytesPerBuffer;
        if (bytesPerBuffer > 0) {
            memset(inBuffer->mAudioData, 0, bytesPerBuffer);
        }
        AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
        return;
    }

    if (bytesPerBuffer > inBuffer->mAudioDataBytesCapacity) {
        bytesPerBuffer = inBuffer->mAudioDataBytesCapacity;
    }

    inBuffer->mAudioDataByteSize = bytesPerBuffer;

    // If the indexes aren't equal, we have a sample
    if (conn->_audioBufferWriteIndex != conn->_audioBufferReadIndex) {
        // Copy data to the audio buffer
         memcpy(inBuffer->mAudioData,
             &conn->_audioCircularBuffer[conn->_audioBufferReadIndex * conn->_audioBufferStride],
             inBuffer->mAudioDataByteSize);
        
        // Use a full memory barrier to ensure the circular buffer is read before incrementing the index
        __sync_synchronize();
        
        // This can race with the reader in the AudDecDecodeAndPlaySample function. This is
        // not a problem because at worst, it just won't see that we've consumed this sample yet.
        conn->_audioBufferReadIndex = (conn->_audioBufferReadIndex + 1) % conn->_audioBufferEntries;
    }
    else {
        // No data, so play silence
        memset(inBuffer->mAudioData, 0, inBuffer->mAudioDataByteSize);
    }
    
    AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
}

-(void) main
{
    os_unfair_lock_lock(&gConnectionLifecycleLock);
    LiSetThreadConnectionContext(&_connectionContext);
    Log(LOG_I, @"LiStartConnectionCtx: connCtx=%p globalCtx=%p inputCtx=%p", &_connectionContext, LiGetGlobalConnectionContextPtr(), LiGetInputContextFromConnectionCtx(&_connectionContext));
    LiStartConnectionCtx(&_connectionContext,
                         &_serverInfo,
                         &_streamConfig,
                         &_clCallbacks,
                         &_drCallbacks,
                         &_arCallbacks,
                         (__bridge void *)self, 0,
                         (__bridge void *)self, 0);
    os_unfair_lock_unlock(&gConnectionLifecycleLock);
}

@end
