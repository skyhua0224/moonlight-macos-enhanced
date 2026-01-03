//
//  Connection.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/19/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "Connection.h"
#import "Utils.h"

#import "Moonlight-Swift.h"

#import <AudioUnit/AudioUnit.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

#import <arpa/inet.h>

#include "Limelight.h"
#include "opus_multistream.h"

@interface Connection ()
#if defined(LI_MIC_CONTROL_START)
@property (nonatomic, strong) AVAudioEngine* micAudioEngine;
@property (nonatomic, strong) AVAudioConverter* micConverter;
@property (nonatomic, strong) AVAudioFormat* micOutputFormat;
#endif
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
}

@synthesize renderer = _renderer;

static NSLock* initLock;
static OpusMSDecoder* opusDecoder;
static id<ConnectionCallbacks> _callbacks;

static Connection* activeConnection;

#define OUTPUT_BUS 0

// My iPod touch 5th Generation seems to really require 80 ms
// of buffering to deliver glitch-free playback :(
// FIXME: Maybe we can use a smaller buffer on more modern iOS versions?
#define CIRCULAR_BUFFER_DURATION 80

static int audioBufferEntries;
static int audioBufferWriteIndex;
static int audioBufferReadIndex;
static int audioBufferStride;
static int audioSamplesPerFrame;
static short* audioCircularBuffer;

static int channelCount;
static float audioVolumeMultiplier = 1.0f;
static NSString *hostAddress;
static int currentUpscalingMode = 0;

#define AUDIO_QUEUE_BUFFERS 4

static AudioQueueRef audioQueue;
static AudioQueueBufferRef audioBuffers[AUDIO_QUEUE_BUFFERS];
static VideoDecoderRenderer* renderer;

static void FillOutputBuffer(void *aqData,
                             AudioQueueRef inAQ,
                             AudioQueueBufferRef inBuffer);

#if defined(LI_MIC_CONTROL_START)
static dispatch_queue_t micQueue;
static OpusMSEncoder* micEncoder;
static NSMutableData* micPcmQueue;
static uint16_t micSeq;
static uint32_t micTimestamp;
static uint32_t micSsrc;
static const int micSampleRate = 48000;
static const int micChannels = 1;
static const int micFrameSize = 960; // 20 ms at 48 kHz
static const int micBitrate = 64000;
#endif

int DrDecoderSetup(int videoFormat, int width, int height, int redrawRate, void* context, int drFlags)
{
    [renderer setupWithVideoFormat:videoFormat frameRate:redrawRate upscalingMode:currentUpscalingMode];
    return 0;
}

void DrStart(void)
{
    [renderer start];
}

void DrStop(void)
{
    [renderer stop];

    _callbacks = nil;
    renderer = nil;
}

int DrSubmitDecodeUnit(PDECODE_UNIT decodeUnit)
{
    // Use the optimized renderer path which includes buffer pooling
    return [renderer submitDecodeUnit:decodeUnit];
}

int ArInit(int audioConfiguration, POPUS_MULTISTREAM_CONFIGURATION originalOpusConfig, void* context, int flags)
{
    int err;
    AudioChannelLayout channelLayout = {};
    OPUS_MULTISTREAM_CONFIGURATION opusConfig = *originalOpusConfig;
    
    // Initialize the circular buffer
    audioBufferWriteIndex = audioBufferReadIndex = 0;
    audioSamplesPerFrame = opusConfig.samplesPerFrame;
    audioBufferStride = opusConfig.channelCount * opusConfig.samplesPerFrame;
    audioBufferEntries = CIRCULAR_BUFFER_DURATION / (opusConfig.samplesPerFrame / (opusConfig.sampleRate / 1000));
    audioCircularBuffer = malloc(audioBufferEntries * audioBufferStride * sizeof(short));
    if (audioCircularBuffer == NULL) {
        Log(LOG_E, @"Error allocating output queue\n");
        return -1;
    }
    
    channelCount = opusConfig.channelCount;
    
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
    
    opusDecoder = opus_multistream_decoder_create(opusConfig.sampleRate,
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

    status = AudioQueueNewOutput(&audioFormat, FillOutputBuffer, nil, nil, nil, 0, &audioQueue);
    if (status != noErr) {
        Log(LOG_E, @"Error allocating output queue: %d\n", status);
        return status;
    }
    
    // We need to specify a channel layout for surround sound configurations
    status = AudioQueueSetProperty(audioQueue, kAudioQueueProperty_ChannelLayout, &channelLayout, sizeof(channelLayout));
    if (status != noErr) {
        Log(LOG_E, @"Error configuring surround channel layout: %d\n", status);
        return status;
    }
    
    for (int i = 0; i < AUDIO_QUEUE_BUFFERS; i++) {
        status = AudioQueueAllocateBuffer(audioQueue, audioFormat.mBytesPerFrame * opusConfig.samplesPerFrame, &audioBuffers[i]);
        if (status != noErr) {
            Log(LOG_E, @"Error allocating output buffer: %d\n", status);
            return status;
        }
        
        FillOutputBuffer(nil, audioQueue, audioBuffers[i]);
    }
    
    status = AudioQueueStart(audioQueue, nil);
    if (status != noErr) {
        Log(LOG_E, @"Error starting queue: %d\n", status);
        return status;
    }
    
    return status;
}

void ArCleanup(void)
{
    if (opusDecoder != NULL) {
        opus_multistream_decoder_destroy(opusDecoder);
        opusDecoder = NULL;
    }
    
    // Stop before disposing to avoid massive delay inside
    // AudioQueueDispose() (iOS bug?)
    AudioQueueStop(audioQueue, true);
    
    // Also frees buffers
    AudioQueueDispose(audioQueue, true);
    
    // Must be freed after the queue is stopped
    if (audioCircularBuffer != NULL) {
        free(audioCircularBuffer);
        audioCircularBuffer = NULL;
    }
    
#if TARGET_OS_IPHONE
    // Audio session is now inactive
    [[AVAudioSession sharedInstance] setActive: NO error: nil];
#endif
}

void ArDecodeAndPlaySample(char* sampleData, int sampleLength)
{
    int decodeLen;
    
    // Check if there is space for this sample in the buffer. Again, this can race
    // but in the worst case, we'll not see the sample callback having consumed a sample.
    if (((audioBufferWriteIndex + 1) % audioBufferEntries) == audioBufferReadIndex) {
        return;
    }
    
    decodeLen = opus_multistream_decode(opusDecoder, (unsigned char *)sampleData, sampleLength,
                                        (short*)&audioCircularBuffer[audioBufferWriteIndex * audioBufferStride], audioSamplesPerFrame, 0);
    if (decodeLen > 0) {
        // Apply volume adjustment to each audio sample
        short* buffer = &audioCircularBuffer[audioBufferWriteIndex * audioBufferStride];
        for (int i = 0; i < decodeLen * channelCount; i++) {
            buffer[i] = (short)(buffer[i] * audioVolumeMultiplier);
        }
        
        // Use a full memory barrier to ensure the circular buffer is written before incrementing the index
        __sync_synchronize();
        
        // This can race with the reader in the sample callback, however this is a benign
        // race since we'll either read the original value of s_WriteIndex (which is safe,
        // we just won't consider this sample) or the new value of s_WriteIndex
        audioBufferWriteIndex = (audioBufferWriteIndex + 1) % audioBufferEntries;
    }
}

- (void)updateVolume {
    if (hostAddress != nil) {
        NSString *uuid = [SettingsClass getHostUUIDFrom:hostAddress];
        audioVolumeMultiplier = [SettingsClass volumeLevelFor:uuid];
    }
}

void ClStageStarting(int stage)
{
    [_callbacks stageStarting:LiGetStageName(stage)];
}

void ClStageComplete(int stage)
{
    [_callbacks stageComplete:LiGetStageName(stage)];
}

void ClStageFailed(int stage, int errorCode)
{
    [_callbacks stageFailed:LiGetStageName(stage) withError:errorCode];
}

void ClConnectionStarted(void)
{
    [_callbacks connectionStarted];

#if defined(LI_MIC_CONTROL_START)
    // Start microphone after the stream is fully established
    dispatch_async(dispatch_get_main_queue(), ^{
        [activeConnection startMicrophoneIfNeeded];
    });
#endif
}

void ClConnectionTerminated(int errorCode)
{
#if defined(LI_MIC_CONTROL_START)
    // Stopping AVAudioEngine can occasionally block under CoreAudio stress.
    // Keep it off the main thread so UI doesn't appear frozen during disconnect.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [activeConnection stopMicrophoneIfNeeded];
    });
#endif
    [_callbacks connectionTerminated: errorCode];
}

void ClLogMessage(const char* format, ...)
{
    static uint64_t lastDropLogTime = 0;
    static int accumulatedDropCount = 0;
    
    // Simple heuristic to detect dropped frame logs from common-c
    bool isDropLog = (strstr(format, "Network dropped") != NULL);

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
    vfprintf(stderr, format, va);
    va_end(va);
    
    if (isDropLog && accumulatedDropCount > 1) {
        fprintf(stderr, " (and %d more dropped frame messages suppressed)\n", accumulatedDropCount - 1);
        accumulatedDropCount = 0;
    }
}

void ClRumble(unsigned short controllerNumber, unsigned short lowFreqMotor, unsigned short highFreqMotor)
{
    [_callbacks rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
}

void ClConnectionStatusUpdate(int status)
{
    [_callbacks connectionStatusUpdate:status];
}

-(void) terminate
{
    // Interrupt any action blocking LiStartConnection(). This is
    // thread-safe and done outside initLock on purpose, since we
    // won't be able to acquire it if LiStartConnection is in
    // progress.
    LiInterruptConnection();
    
    // We dispatch this async to get out because this can be invoked
    // on a thread inside common and we don't want to deadlock. It also avoids
    // blocking on the caller's thread waiting to acquire initLock.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [initLock lock];
        LiStopConnection();
        [initLock unlock];
    });
}

-(id) initWithConfig:(StreamConfiguration*)config renderer:(VideoDecoderRenderer*)myRenderer connectionCallbacks:(id<ConnectionCallbacks>)callbacks
{
    self = [super init];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateVolume) name:@"volumeSettingChanged" object:nil];
    
    // Use a lock to ensure that only one thread is initializing
    // or deinitializing a connection at a time.
    if (initLock == nil) {
        initLock = [[NSLock alloc] init];
    }
    
    hostAddress = config.host;
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

    renderer = myRenderer;
    _renderer = myRenderer;
    _callbacks = callbacks;

    activeConnection = self;
    
    currentUpscalingMode = config.upscalingMode;

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
        NSString* uuid = nil;
        if (config.host != nil) {
            uuid = [SettingsClass getHostUUIDFrom:config.host];
        }

        NSString* settingsKey = uuid != nil ? uuid : @"__global__";
        NSDictionary* settings = [SettingsClass getSettingsFor:settingsKey];
        if (settings != nil) {
            enableMic = [settings[@"microphone"] boolValue];
        }
    } @catch (NSException* exception) {
        enableMic = NO;
    }

    _streamConfig.enableMic = enableMic;
#endif

#if !defined(VIDEO_FORMAT_H264_HIGH8_444)
    // Legacy moonlight-common-c
    _streamConfig.enableHdr = config.enableHdr;

    // Use some of the HEVC encoding efficiency improvements to
    // reduce bandwidth usage while still gaining some image
    // quality improvement.
    _streamConfig.hevcBitratePercentageMultiplier = 75;
#endif
    
    // Some moonlight-common-c builds assert if streamingRemotely remains AUTO by SDP generation time.
    // We resolve it here to LOCAL/REMOTE using our own remote detection.
    if ([Utils isActiveNetworkVPN] || config.streamingRemotely) {
        // Force remote streaming mode when a VPN is connected or when the caller has determined
        // this is a remote session.
        _streamConfig.streamingRemotely = STREAM_CFG_REMOTE;
        _streamConfig.packetSize = 1024;
    }
    else {
        _streamConfig.streamingRemotely = STREAM_CFG_LOCAL;
        _streamConfig.packetSize = 1392;
    }
    
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
    BOOL hevcSupported = NO;
    if (@available(iOS 11.3, tvOS 11.3, macOS 10.14, *)) {
        hevcSupported = config.allowHevc && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);
    }

    // If HDR is requested, HEVC decode support is required.
    assert(!config.enableHdr || hevcSupported);

    BOOL enableYuv444 = NO;
    @try {
        NSString* uuid = nil;
        if (config.host != nil) {
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

    _streamConfig.supportedVideoFormats = supportedVideoFormats;
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
    _drCallbacks.capabilities = CAPABILITY_PULL_RENDERER;
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

#if defined(LI_MIC_CONTROL_START)
- (void)startMicrophoneIfNeeded
{
    if (!_streamConfig.enableMic) {
        return;
    }

    // Create encoder/queue once
    if (micQueue == nil) {
        micQueue = dispatch_queue_create("moonlight.mic.encode", DISPATCH_QUEUE_SERIAL);
    }
    if (micPcmQueue == nil) {
        micPcmQueue = [NSMutableData data];
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

- (void)startMicrophoneEngineLocked
{
    if (self.micAudioEngine != nil && self.micAudioEngine.isRunning) {
        return;
    }

    if (initializeMicrophoneStream() != 0) {
        Log(LOG_W, @"Failed to initialize microphone stream socket\n");
        return;
    }

    // Tell the host to start accepting microphone packets and which format we'll send.
    // Qt sends this control message; without it the host may ignore UDP mic packets.
    int micCtlErr = LiSendMicrophoneControl(LI_MIC_CONTROL_START, micSampleRate, micChannels, micBitrate);
    if (micCtlErr != 0) {
        Log(LOG_W, @"Failed to send microphone START control: %d\n", micCtlErr);
    }

    int err = 0;
    if (micEncoder == NULL) {
        unsigned char mapping[1] = { 0 };
        micEncoder = opus_multistream_encoder_create(micSampleRate,
                                                     micChannels,
                                                     1, /* streams */
                                                     0, /* coupled */
                                                     mapping,
                                                     OPUS_APPLICATION_VOIP,
                                                     &err);
        if (micEncoder == NULL || err != OPUS_OK) {
            Log(LOG_W, @"Failed to create Opus encoder for microphone: %d\n", err);
            micEncoder = NULL;
            return;
        }

        micSeq = 0;
        micTimestamp = 0;
        micSsrc = (uint32_t)arc4random();

        opus_multistream_encoder_ctl(micEncoder, OPUS_SET_BITRATE(micBitrate));
    }

    self.micAudioEngine = [[AVAudioEngine alloc] init];
    AVAudioInputNode* input = self.micAudioEngine.inputNode;
    self.micOutputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                            sampleRate:micSampleRate
                                                              channels:micChannels
                                                           interleaved:YES];

    __weak typeof(self) weakSelf = self;
    [input removeTapOnBus:0];
    // Ask the engine to provide 48 kHz mono int16 directly. This avoids doing format conversion
    // on the real-time audio thread and reduces the chance of HAL overloads.
    [input installTapOnBus:0 bufferSize:(AVAudioFrameCount)micFrameSize format:self.micOutputFormat block:^(AVAudioPCMBuffer* buffer, AVAudioTime* when) {
        __strong typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (!strongSelf->_streamConfig.enableMic) {
            return;
        }

        // Copy data off the audio thread (engine provides int16 PCM in AudioBufferList)
        const AudioBufferList* abl = buffer.audioBufferList;
        if (abl == NULL || abl->mNumberBuffers < 1) {
            return;
        }

        const AudioBuffer ab = abl->mBuffers[0];
        if (ab.mData == NULL || ab.mDataByteSize == 0) {
            return;
        }

        NSData* chunk = [NSData dataWithBytes:ab.mData length:(NSUInteger)ab.mDataByteSize];
        dispatch_async(micQueue, ^{
            [micPcmQueue appendData:chunk];
            [strongSelf drainMicPcmAndSend];
        });
    }];

    NSError* startErr = nil;
    BOOL started = [self.micAudioEngine startAndReturnError:&startErr];
    if (!started || startErr != nil) {
        Log(LOG_W, @"Failed to start microphone capture: %@\n", startErr.localizedDescription);
        [self.micAudioEngine stop];
        self.micAudioEngine = nil;
    }
}

- (void)drainMicPcmAndSend
{
    if (micEncoder == NULL) {
        return;
    }

    const NSUInteger bytesPerFrame = sizeof(int16_t) * micChannels;
    const NSUInteger packetPcmBytes = (NSUInteger)micFrameSize * bytesPerFrame;

    while (micPcmQueue.length >= packetPcmBytes) {
        const int16_t* pcm = (const int16_t*)micPcmQueue.bytes;

        unsigned char opusPayload[1500];
        int opusLen = opus_multistream_encode(micEncoder, pcm, micFrameSize, opusPayload, (opus_int32)sizeof(opusPayload));
        if (opusLen > 0) {
            // RTP header (V=2, PT=97) + Opus payload
            unsigned char packet[12 + 1500];
            packet[0] = 0x80;
            packet[1] = 0x61;
            *(uint16_t*)(packet + 2) = htons(micSeq++);
            *(uint32_t*)(packet + 4) = htonl(micTimestamp);
            *(uint32_t*)(packet + 8) = htonl(micSsrc);
            memcpy(packet + 12, opusPayload, (size_t)opusLen);

            int sent = sendMicrophoneData((const char*)packet, 12 + opusLen);
            if (sent < 0) {
                // Log errors, but keep running to tolerate transient network issues.
                Log(LOG_W, @"sendMicrophoneData failed: %d\n", sent);
            }
            micTimestamp += micFrameSize;
        }

        // Pop consumed PCM
        [micPcmQueue replaceBytesInRange:NSMakeRange(0, packetPcmBytes) withBytes:NULL length:0];
    }
}

- (void)stopMicrophoneIfNeeded
{
    if (self.micAudioEngine != nil) {
        [self.micAudioEngine.inputNode removeTapOnBus:0];
        [self.micAudioEngine stop];
        self.micAudioEngine = nil;
    }

    dispatch_async(micQueue ?: dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [micPcmQueue setLength:0];
    });

    LiSendMicrophoneControl(LI_MIC_CONTROL_STOP, 0, 0, 0);

    destroyMicrophoneStream();
}
#endif

static void FillOutputBuffer(void *aqData,
                             AudioQueueRef inAQ,
                             AudioQueueBufferRef inBuffer) {
    inBuffer->mAudioDataByteSize = audioBufferStride * sizeof(short);
    
    assert(inBuffer->mAudioDataByteSize == inBuffer->mAudioDataBytesCapacity);
    
    // If the indexes aren't equal, we have a sample
    if (audioBufferWriteIndex != audioBufferReadIndex) {
        // Copy data to the audio buffer
        memcpy(inBuffer->mAudioData,
               &audioCircularBuffer[audioBufferReadIndex * audioBufferStride],
               inBuffer->mAudioDataByteSize);
        
        // Use a full memory barrier to ensure the circular buffer is read before incrementing the index
        __sync_synchronize();
        
        // This can race with the reader in the AudDecDecodeAndPlaySample function. This is
        // not a problem because at worst, it just won't see that we've consumed this sample yet.
        audioBufferReadIndex = (audioBufferReadIndex + 1) % audioBufferEntries;
    }
    else {
        // No data, so play silence
        memset(inBuffer->mAudioData, 0, inBuffer->mAudioDataByteSize);
    }
    
    AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
}

-(void) main
{
    [initLock lock];
    LiStartConnection(&_serverInfo,
                      &_streamConfig,
                      &_clCallbacks,
                      &_drCallbacks,
                      &_arCallbacks,
                      NULL, 0,
                      NULL, 0);
    [initLock unlock];
}

@end
