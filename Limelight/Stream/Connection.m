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
#include <limits.h>
#include <math.h>
#include <pthread.h>

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
#define AUDIO_DIRECT_BUFFER_DURATION 55
#define AUDIO_ENHANCED_BUFFER_DURATION 60
#define AUDIO_RENDER_SCRATCH_FRAMES 2048

static const float kDirectRendererMakeupGain = 1.24f;
static const float kEnhancedRendererOutputGain = 1.08f;

static const double kLegacyEnhancedEQFrequencies[] = {
    32.0, 64.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0,
};
static const NSUInteger kLegacyEnhancedEQBandCount = sizeof(kLegacyEnhancedEQFrequencies) / sizeof(kLegacyEnhancedEQFrequencies[0]);
static const double kEnhancedEQFrequencies12Band[] = {
    32.0, 64.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 6000.0, 8000.0, 12000.0, 16000.0,
};
static const NSUInteger kEnhancedEQBandCount12 = sizeof(kEnhancedEQFrequencies12Band) / sizeof(kEnhancedEQFrequencies12Band[0]);
static const double kEnhancedEQFrequencies24Band[] = {
    20.0, 25.0, 32.0, 40.0, 50.0, 63.0, 80.0, 100.0, 125.0, 160.0, 200.0, 250.0,
    315.0, 400.0, 500.0, 630.0, 800.0, 1000.0, 1600.0, 2500.0, 4000.0, 6300.0, 10000.0, 16000.0,
};
static const NSUInteger kEnhancedEQBandCount24 = sizeof(kEnhancedEQFrequencies24Band) / sizeof(kEnhancedEQFrequencies24Band[0]);

static int MLResolvedDynamicRangeModeForPreference(BOOL hdrEnabled, int hdrTransferFunction) {
    if (!hdrEnabled) {
        return DYNAMIC_RANGE_MODE_SDR;
    }

    switch (hdrTransferFunction) {
        case 1:
            return DYNAMIC_RANGE_MODE_HDR10_PQ;
        case 2:
            return DYNAMIC_RANGE_MODE_HLG;
        case 0:
        default:
            return DYNAMIC_RANGE_MODE_HLG;
    }
}

static inline float MLApplyMakeupGainAndSoftClip(float sample, float gain) {
    float x = sample * gain;
    float ax = fabsf(x);
    if (ax <= 0.85f) {
        return x;
    }

    float excess = ax - 0.85f;
    float compressed = 0.85f + (excess / (1.0f + excess * 6.0f));
    return copysignf(MIN(compressed, 1.0f), x);
}

typedef NS_ENUM(NSInteger, MLAudioOutputMode) {
    MLAudioOutputModeDirect = 0,
    MLAudioOutputModeEnhanced = 1,
};

typedef NS_ENUM(NSInteger, MLAudioEnhancedOutputTarget) {
    MLAudioEnhancedOutputTargetHeadphones = 0,
    MLAudioEnhancedOutputTargetSpeakers = 1,
    MLAudioEnhancedOutputTargetAutomatic = 2,
};

typedef NS_ENUM(NSInteger, MLAudioRendererBackend) {
    MLAudioRendererBackendLegacyQueue = 0,
    MLAudioRendererBackendDirect = 1,
    MLAudioRendererBackendEnhanced = 2,
};

@interface Connection ()
#if defined(LI_MIC_CONTROL_START)
@property (nonatomic, strong) AVAudioEngine* micAudioEngine;
@property (nonatomic, strong) AVAudioConverter* micConverter;
@property (nonatomic, strong) AVAudioFormat* micOutputFormat;
#endif
- (BOOL)initializeDirectAudioRendererWithOpusConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig
                                      channelLayout:(const AudioChannelLayout *)channelLayout;
- (BOOL)initializeEnhancedAudioRendererWithOpusConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig;
- (void)cleanupSelectedAudioRenderer;
- (void)configureEnhancedAudioUnits;
- (BOOL)prepareEnhancedDownmixConverterWithOpusConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig;
- (void)copyPCMFrames:(UInt32)frameCount toInterleavedBuffer:(short *)outputBuffer;
- (void)copyPCMFrames:(UInt32)frameCount
 toFloatBufferList:(AudioBufferList *)outputData
 expectedChannels:(UInt32)expectedChannels;
- (void)renderEnhancedStereoPCMFrames:(UInt32)frameCount
                    toFloatBufferList:(AudioBufferList *)outputData;
- (BOOL)recreateAudioDecoderWithConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig
                                reason:(NSString *)reason;
- (BOOL)attempt714DecoderTopologyFallbackAfterDecodeError:(int)decodeError;
- (BOOL)attempt714PrimaryDecoderReprobeWithSampleData:(char *)sampleData
                                         sampleLength:(int)sampleLength;
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
    UInt32 _audioBufferReadFrameOffset;
    short *_audioRenderScratchBuffer;

    int _audioOutputMode;
    int _enhancedAudioOutputTarget;
    int _enhancedAudioPreset;
    CGFloat _enhancedAudioSpatialIntensity;
    CGFloat _enhancedAudioSoundstageWidth;
    CGFloat _enhancedAudioReverbAmount;
    NSArray<NSNumber *> *_enhancedAudioEQGains;
    int _audioDeviceChannelCount;
    int _audioRenderChannelCount;
    MLAudioRendererBackend _audioRendererBackend;

    AudioQueueRef _audioQueue;
    AudioQueueBufferRef _audioBuffers[AUDIO_QUEUE_BUFFERS];
    void *_audioQueueContext;
    AudioComponentInstance _audioUnit;
    AVAudioEngine *_enhancedAudioEngine;
    AVAudioSourceNode *_enhancedAudioSourceNode;
    AVAudioUnitReverb *_enhancedAudioReverb;
    AVAudioUnitEQ *_enhancedAudioEQ;
    AVAudioConverter *_enhancedDownmixConverter;
    AVAudioPCMBuffer *_enhancedDownmixInputBuffer;
    AVAudioPCMBuffer *_enhancedDownmixOutputBuffer;
    BOOL _enhancedUsesCoreAudioDownmix;
    uint64_t _enhancedDownmixFailureCount;
    uint64_t _audioUnderrunCount;
    BOOL _audioDecodeThreadPriorityRaised;
    uint64_t _audioDecodeSampleCount;
    uint64_t _audioDecodeFailureCount;
    uint64_t _audioConsecutiveDecodeFailures;
    uint64_t _audioFallbackDecodeSuccessCount;
    OPUS_MULTISTREAM_CONFIGURATION _audioAdvertisedOpusConfig;
    OPUS_MULTISTREAM_CONFIGURATION _audioCurrentDecoderConfig;
    OPUS_MULTISTREAM_CONFIGURATION _audioFallbackDecoderConfig;
    BOOL _hasAudioFallbackDecoderConfig;
    BOOL _usingAudioFallbackDecoderConfig;
    BOOL _audioPrimaryReprobeAttempted;

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
    dispatch_queue_t _clipboardControlQueue;
}

- (void)ensureControlContextBacklink {
    if (_connectionContext.controlContext.connectionContext == NULL) {
        _connectionContext.controlContext.connectionContext = &_connectionContext;
    }
}

static NSMutableDictionary<NSValue*, Connection*>* gConnectionMap;
static dispatch_queue_t gConnectionMapQueue;
static void *gConnectionMapQueueKey = &gConnectionMapQueueKey;
static os_unfair_lock gConnectionMapLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock gConnectionLifecycleLock = OS_UNFAIR_LOCK_INIT;
static void *gMicQueueKey = &gMicQueueKey;
static void *gClipboardQueueKey = &gClipboardQueueKey;

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
static OSStatus RenderDirectAudioUnit(void *inRefCon,
                                      AudioUnitRenderActionFlags *ioActionFlags,
                                      const AudioTimeStamp *inTimeStamp,
                                      UInt32 inBusNumber,
                                      UInt32 inNumberFrames,
                                      AudioBufferList *ioData);

static int MLDefaultOutputChannelCount(void) {
    AudioDeviceID deviceID = kAudioObjectUnknown;
    UInt32 propertySize = sizeof(deviceID);
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    if (AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                   &address,
                                   0,
                                   NULL,
                                   &propertySize,
                                   &deviceID) != noErr || deviceID == kAudioObjectUnknown) {
        return 2;
    }

    AudioObjectPropertyAddress streamConfigAddress = {
        kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    UInt32 streamConfigSize = 0;
    if (AudioObjectGetPropertyDataSize(deviceID,
                                       &streamConfigAddress,
                                       0,
                                       NULL,
                                       &streamConfigSize) != noErr || streamConfigSize == 0) {
        return 2;
    }

    AudioBufferList *bufferList = (AudioBufferList *)malloc(streamConfigSize);
    if (bufferList == NULL) {
        return 2;
    }

    int channels = 2;
    if (AudioObjectGetPropertyData(deviceID,
                                   &streamConfigAddress,
                                   0,
                                   NULL,
                                   &streamConfigSize,
                                   bufferList) == noErr) {
        channels = 0;
        for (UInt32 i = 0; i < bufferList->mNumberBuffers; i++) {
            channels += (int)bufferList->mBuffers[i].mNumberChannels;
        }
        if (channels <= 0) {
            channels = 2;
        }
    }

    free(bufferList);
    return channels;
}

static NSString *MLDefaultOutputDeviceName(void) {
    AudioDeviceID deviceID = kAudioObjectUnknown;
    UInt32 propertySize = sizeof(deviceID);
    AudioObjectPropertyAddress deviceAddress = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    if (AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                   &deviceAddress,
                                   0,
                                   NULL,
                                   &propertySize,
                                   &deviceID) != noErr || deviceID == kAudioObjectUnknown) {
        return @"Unknown Output";
    }

    CFStringRef deviceName = NULL;
    propertySize = sizeof(deviceName);
    AudioObjectPropertyAddress nameAddress = {
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(deviceID,
                                   &nameAddress,
                                   0,
                                   NULL,
                                   &propertySize,
                                   &deviceName) != noErr || deviceName == NULL) {
        return @"Unknown Output";
    }

    return CFBridgingRelease(deviceName);
}

static UInt32 MLDefaultOutputTransportType(void) {
    AudioDeviceID deviceID = kAudioObjectUnknown;
    UInt32 propertySize = sizeof(deviceID);
    AudioObjectPropertyAddress deviceAddress = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    if (AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                   &deviceAddress,
                                   0,
                                   NULL,
                                   &propertySize,
                                   &deviceID) != noErr || deviceID == kAudioObjectUnknown) {
        return 0;
    }

    UInt32 transportType = 0;
    propertySize = sizeof(transportType);
    AudioObjectPropertyAddress transportAddress = {
        kAudioDevicePropertyTransportType,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(deviceID,
                                   &transportAddress,
                                   0,
                                   NULL,
                                   &propertySize,
                                   &transportType) != noErr) {
        return 0;
    }

    return transportType;
}

static BOOL MLDefaultOutputLooksLikeHeadphones(NSString *deviceName, UInt32 transportType, int channelCount) {
    NSString *normalized = deviceName.lowercaseString ?: @"";
    NSArray<NSString *> *headphoneHints = @[
        @"airpods", @"headphone", @"headset", @"earbud", @"耳机", @"buds", @"qc ", @"wh-", @"wf-"
    ];
    for (NSString *hint in headphoneHints) {
        if ([normalized containsString:hint]) {
            return YES;
        }
    }

    NSArray<NSString *> *speakerHints = @[
        @"speaker", @"display", @"monitor", @"hdmi", @"tv", @"studio display", @"homepod", @"音箱"
    ];
    for (NSString *hint in speakerHints) {
        if ([normalized containsString:hint]) {
            return NO;
        }
    }

    if (channelCount > 2) {
        return NO;
    }

    switch (transportType) {
        case kAudioDeviceTransportTypeBluetooth:
        case kAudioDeviceTransportTypeBluetoothLE:
        case kAudioDeviceTransportTypeUSB:
            return YES;
        default:
            return NO;
    }
}

static MLAudioEnhancedOutputTarget MLResolveEnhancedOutputTarget(MLAudioEnhancedOutputTarget configuredTarget) {
    if (configuredTarget != MLAudioEnhancedOutputTargetAutomatic) {
        return configuredTarget;
    }

    NSString *deviceName = MLDefaultOutputDeviceName();
    UInt32 transportType = MLDefaultOutputTransportType();
    int channelCount = MLDefaultOutputChannelCount();
    BOOL headphones = MLDefaultOutputLooksLikeHeadphones(deviceName, transportType, channelCount);
    Log(LOG_I, @"Enhanced output target auto-resolved: device=%@ transport=%u channels=%d target=%@",
        deviceName,
        (unsigned int)transportType,
        channelCount,
        headphones ? @"Headphones" : @"Speakers");
    return headphones ? MLAudioEnhancedOutputTargetHeadphones : MLAudioEnhancedOutputTargetSpeakers;
}

static const double *MLEnhancedEQFrequencyTable(NSUInteger bandCount, NSUInteger *resolvedBandCount) {
    switch (bandCount) {
        case 24:
            if (resolvedBandCount != NULL) {
                *resolvedBandCount = kEnhancedEQBandCount24;
            }
            return kEnhancedEQFrequencies24Band;
        case 12:
        case 0:
            if (resolvedBandCount != NULL) {
                *resolvedBandCount = kEnhancedEQBandCount12;
            }
            return kEnhancedEQFrequencies12Band;
        case 10:
        default:
            if (resolvedBandCount != NULL) {
                *resolvedBandCount = kLegacyEnhancedEQBandCount;
            }
            return kLegacyEnhancedEQFrequencies;
    }
}

static AudioChannelLayoutTag MLChannelLayoutTagForChannelCount(int channelCount) {
    switch (channelCount) {
        case 1:
            return kAudioChannelLayoutTag_Mono;
        case 2:
            return kAudioChannelLayoutTag_Stereo;
        case 4:
            return kAudioChannelLayoutTag_Quadraphonic;
        case 6:
            return kAudioChannelLayoutTag_AudioUnit_5_1;
        case 8:
            return kAudioChannelLayoutTag_AudioUnit_7_1;
        case 12:
            return kAudioChannelLayoutTag_Atmos_7_1_4;
        default:
            return kAudioChannelLayoutTag_UseChannelDescriptions;
    }
}

static void MLFillChannelLayout(AudioChannelLayout *channelLayout, int channelCount) {
    memset(channelLayout, 0, sizeof(AudioChannelLayout));
    channelLayout->mChannelLayoutTag = MLChannelLayoutTagForChannelCount(channelCount);
}

static BOOL MLIs714HighQualityOpusConfig(const OPUS_MULTISTREAM_CONFIGURATION *opusConfig) {
    return opusConfig != NULL &&
           opusConfig->channelCount == 12 &&
           opusConfig->streams == 12 &&
           opusConfig->coupledStreams == 0;
}

static BOOL MLIs714CompatibilityOpusConfig(const OPUS_MULTISTREAM_CONFIGURATION *opusConfig) {
    return opusConfig != NULL &&
           opusConfig->channelCount == 12 &&
           opusConfig->streams == 8 &&
           opusConfig->coupledStreams == 4;
}

static void MLPrepareOpusDecoderConfig(const OPUS_MULTISTREAM_CONFIGURATION *sourceConfig,
                                       OPUS_MULTISTREAM_CONFIGURATION *preparedConfig) {
    if (sourceConfig == NULL || preparedConfig == NULL) {
        return;
    }

    *preparedConfig = *sourceConfig;
    if (preparedConfig->channelCount == 8) {
        preparedConfig->mapping[4] = sourceConfig->mapping[6];
        preparedConfig->mapping[5] = sourceConfig->mapping[7];
        preparedConfig->mapping[6] = sourceConfig->mapping[4];
        preparedConfig->mapping[7] = sourceConfig->mapping[5];
    }
}

static AVAudioChannelLayout *MLCreateAVAudioChannelLayout(int channelCount) {
    AudioChannelLayoutTag tag = MLChannelLayoutTagForChannelCount(channelCount);
    if (tag == kAudioChannelLayoutTag_UseChannelDescriptions) {
        return nil;
    }

    return [[AVAudioChannelLayout alloc] initWithLayoutTag:tag];
}

static int MLAudioRingBufferDurationForMode(MLAudioOutputMode mode) {
    switch (mode) {
        case MLAudioOutputModeEnhanced:
            return AUDIO_ENHANCED_BUFFER_DURATION;
        case MLAudioOutputModeDirect:
            return AUDIO_DIRECT_BUFFER_DURATION;
        default:
            return CIRCULAR_BUFFER_DURATION;
    }
}

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
    OPUS_MULTISTREAM_CONFIGURATION opusConfig = {};
    MLPrepareOpusDecoderConfig(originalOpusConfig, &opusConfig);
    
    // Initialize the circular buffer
    conn->_audioBufferWriteIndex = conn->_audioBufferReadIndex = 0;
    conn->_audioBufferReadFrameOffset = 0;
    conn->_audioSamplesPerFrame = opusConfig.samplesPerFrame;
    conn->_audioBufferStride = opusConfig.channelCount * opusConfig.samplesPerFrame;
    int frameDurationMs = MAX(1, (int)(opusConfig.samplesPerFrame / (opusConfig.sampleRate / 1000)));
    int targetBufferDurationMs = MLAudioRingBufferDurationForMode((MLAudioOutputMode)conn->_audioOutputMode);
    int bufferedFramesTarget = MAX(1, (targetBufferDurationMs + frameDurationMs - 1) / frameDurationMs);
    conn->_audioBufferEntries = MAX(2, bufferedFramesTarget + 1);
    conn->_audioCircularBuffer = malloc(conn->_audioBufferEntries * conn->_audioBufferStride * sizeof(short));
    if (conn->_audioCircularBuffer == NULL) {
        Log(LOG_E, @"Error allocating output queue\n");
        return -1;
    }
    
    conn->_channelCount = opusConfig.channelCount;
    conn->_audioAdvertisedOpusConfig = *originalOpusConfig;
    conn->_audioCurrentDecoderConfig = *originalOpusConfig;
    memset(&conn->_audioFallbackDecoderConfig, 0, sizeof(conn->_audioFallbackDecoderConfig));
    conn->_hasAudioFallbackDecoderConfig = NO;
    conn->_usingAudioFallbackDecoderConfig = NO;
    
    MLFillChannelLayout(&channelLayout, opusConfig.channelCount);
    if (channelLayout.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions) {
        Log(LOG_E, @"Unsupported channel layout: %d\n", opusConfig.channelCount);
        free(conn->_audioCircularBuffer);
        conn->_audioCircularBuffer = NULL;
        return -1;
    }

    if (MLIs714HighQualityOpusConfig(originalOpusConfig)) {
        conn->_audioFallbackDecoderConfig = *originalOpusConfig;
        conn->_audioFallbackDecoderConfig.streams = 8;
        conn->_audioFallbackDecoderConfig.coupledStreams = 4;
        conn->_hasAudioFallbackDecoderConfig = YES;
        Log(LOG_I, @"Armed 7.1.4 Opus decoder fallback: primary=%d/%d fallback=%d/%d",
            originalOpusConfig->streams,
            originalOpusConfig->coupledStreams,
            conn->_audioFallbackDecoderConfig.streams,
            conn->_audioFallbackDecoderConfig.coupledStreams);
    }

    OPUS_MULTISTREAM_CONFIGURATION decoderConfig = opusConfig;
    BOOL preferCompatibility714Topology =
        conn->_streamConfig.disableHighQualitySurround &&
        conn->_hasAudioFallbackDecoderConfig;
    if (preferCompatibility714Topology) {
        MLPrepareOpusDecoderConfig(&conn->_audioFallbackDecoderConfig, &decoderConfig);
        conn->_audioCurrentDecoderConfig = conn->_audioFallbackDecoderConfig;
        conn->_usingAudioFallbackDecoderConfig = YES;
        Log(LOG_I, @"Starting 7.1.4 audio decoder in compatibility topology: streams=%d coupled=%d",
            decoderConfig.streams,
            decoderConfig.coupledStreams);
    }
    
    conn->_opusDecoder = opus_multistream_decoder_create(decoderConfig.sampleRate,
                                                         decoderConfig.channelCount,
                                                         decoderConfig.streams,
                                                         decoderConfig.coupledStreams,
                                                         decoderConfig.mapping,
                                                         &err);
    if (conn->_opusDecoder == NULL || err != OPUS_OK) {
        Log(LOG_E, @"Failed to create Opus decoder: %d\n", err);
        free(conn->_audioCircularBuffer);
        conn->_audioCircularBuffer = NULL;
        return -1;
    }
    conn->_audioRenderScratchBuffer = calloc(AUDIO_RENDER_SCRATCH_FRAMES * conn->_channelCount, sizeof(short));
    if (conn->_audioRenderScratchBuffer == NULL) {
        Log(LOG_E, @"Failed to allocate audio render scratch buffer\n");
        opus_multistream_decoder_destroy(conn->_opusDecoder);
        conn->_opusDecoder = NULL;
        free(conn->_audioCircularBuffer);
        conn->_audioCircularBuffer = NULL;
        return -1;
    }
    conn->_audioDeviceChannelCount = MLDefaultOutputChannelCount();
    conn->_audioRenderChannelCount = conn->_channelCount;
    conn->_audioRendererBackend = MLAudioRendererBackendLegacyQueue;
    conn->_audioUnderrunCount = 0;
    conn->_audioDecodeThreadPriorityRaised = NO;
    conn->_audioDecodeSampleCount = 0;
    conn->_audioDecodeFailureCount = 0;
    conn->_audioConsecutiveDecodeFailures = 0;
    conn->_audioFallbackDecodeSuccessCount = 0;
    conn->_audioPrimaryReprobeAttempted = preferCompatibility714Topology;

    Log(LOG_I, @"Audio renderer init request: backendMode=%d audioConfiguration=0x%08X channels=%d streams=%d coupled=%d samplesPerFrame=%d disableHighQuality714=%d",
        (int)conn->_audioOutputMode,
        audioConfiguration,
        opusConfig.channelCount,
        decoderConfig.streams,
        decoderConfig.coupledStreams,
        opusConfig.samplesPerFrame,
        preferCompatibility714Topology ? 1 : 0);

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

    OSStatus status = noErr;

    if ((MLAudioOutputMode)conn->_audioOutputMode == MLAudioOutputModeDirect) {
        if ([conn initializeDirectAudioRendererWithOpusConfig:&opusConfig channelLayout:&channelLayout]) {
            conn->_audioRendererBackend = MLAudioRendererBackendDirect;
            return noErr;
        }
        Log(LOG_W, @"Direct audio renderer unavailable; falling back to legacy audio queue backend");
    } else if ((MLAudioOutputMode)conn->_audioOutputMode == MLAudioOutputModeEnhanced) {
        if ([conn initializeEnhancedAudioRendererWithOpusConfig:&opusConfig]) {
            conn->_audioRendererBackend = MLAudioRendererBackendEnhanced;
            return noErr;
        }
        Log(LOG_W, @"Enhanced audio renderer unavailable; falling back to legacy audio queue backend");
    }
    
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

    [conn cleanupSelectedAudioRenderer];

    if (conn->_opusDecoder != NULL) {
        opus_multistream_decoder_destroy(conn->_opusDecoder);
        conn->_opusDecoder = NULL;
    }
    
    // Must be freed after the queue is stopped
    if (conn->_audioCircularBuffer != NULL) {
        free(conn->_audioCircularBuffer);
        conn->_audioCircularBuffer = NULL;
    }

    if (conn->_audioRenderScratchBuffer != NULL) {
        free(conn->_audioRenderScratchBuffer);
        conn->_audioRenderScratchBuffer = NULL;
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

    if (!conn->_audioDecodeThreadPriorityRaised) {
        int qosResult = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        if (qosResult == 0) {
            Log(LOG_I, @"Audio decode thread QoS promoted: backend=%d",
                (int)conn->_audioRendererBackend);
        } else {
            Log(LOG_W, @"Audio decode thread QoS promotion failed: backend=%d error=%d",
                (int)conn->_audioRendererBackend,
                qosResult);
        }
        conn->_audioDecodeThreadPriorityRaised = YES;
    }
    
    // Check if there is space for this sample in the buffer. Again, this can race
    // but in the worst case, we'll not see the sample callback having consumed a sample.
    if (conn->_audioBufferEntries == 0 || ((conn->_audioBufferWriteIndex + 1) % conn->_audioBufferEntries) == conn->_audioBufferReadIndex) {
        return;
    }
    
    decodeLen = opus_multistream_decode(conn->_opusDecoder, (unsigned char *)sampleData, sampleLength,
                                        (short*)&conn->_audioCircularBuffer[conn->_audioBufferWriteIndex * conn->_audioBufferStride], conn->_audioSamplesPerFrame, 0);
    if (decodeLen > 0) {
        if (conn->_audioDecodeSampleCount == 0) {
            Log(LOG_I, @"Audio decode primed: backend=%d sampleLength=%d decodedFrames=%d channels=%d samplesPerFrame=%d",
                (int)conn->_audioRendererBackend,
                sampleLength,
                decodeLen,
                conn->_channelCount,
                conn->_audioSamplesPerFrame);
        }
        conn->_audioDecodeSampleCount++;
        conn->_audioConsecutiveDecodeFailures = 0;
        if (conn->_usingAudioFallbackDecoderConfig) {
            conn->_audioFallbackDecodeSuccessCount++;
            if ([conn attempt714PrimaryDecoderReprobeWithSampleData:sampleData
                                                      sampleLength:sampleLength]) {
                return;
            }
        }

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
    } else if (decodeLen < 0) {
        conn->_audioDecodeFailureCount++;
        conn->_audioConsecutiveDecodeFailures++;

        if ([conn attempt714DecoderTopologyFallbackAfterDecodeError:decodeLen]) {
            decodeLen = opus_multistream_decode(conn->_opusDecoder, (unsigned char *)sampleData, sampleLength,
                                                (short*)&conn->_audioCircularBuffer[conn->_audioBufferWriteIndex * conn->_audioBufferStride], conn->_audioSamplesPerFrame, 0);
            if (decodeLen > 0) {
                Log(LOG_I, @"Audio decode recovered after 7.1.4 topology fallback: backend=%d sampleLength=%d decodedFrames=%d channels=%d samplesPerFrame=%d",
                    (int)conn->_audioRendererBackend,
                    sampleLength,
                    decodeLen,
                    conn->_channelCount,
                    conn->_audioSamplesPerFrame);
                conn->_audioDecodeSampleCount++;
                conn->_audioConsecutiveDecodeFailures = 0;

                short *buffer = &conn->_audioCircularBuffer[conn->_audioBufferWriteIndex * conn->_audioBufferStride];
                for (int i = 0; i < decodeLen * conn->_channelCount; i++) {
                    buffer[i] = (short)(buffer[i] * conn->_audioVolumeMultiplier);
                }

                __sync_synchronize();
                conn->_audioBufferWriteIndex = (conn->_audioBufferWriteIndex + 1) % conn->_audioBufferEntries;
                return;
            }
        }

        if (conn->_audioDecodeFailureCount <= 5 || (conn->_audioDecodeFailureCount % 50) == 0) {
            Log(LOG_W, @"Audio decode failed: backend=%d sampleLength=%d error=%d channels=%d samplesPerFrame=%d failures=%llu",
                (int)conn->_audioRendererBackend,
                sampleLength,
                decodeLen,
                conn->_channelCount,
                conn->_audioSamplesPerFrame,
                (unsigned long long)conn->_audioDecodeFailureCount);
        }
    }
}

- (void)updateVolume {
    if (_hostAddress != nil) {
        NSString *uuid = [SettingsClass getHostUUIDFrom:_hostAddress];
        _audioVolumeMultiplier = [SettingsClass volumeLevelFor:uuid];
    }
}

- (void)copyPCMFrames:(UInt32)frameCount toInterleavedBuffer:(short *)outputBuffer
{
    if (outputBuffer == NULL || _audioCircularBuffer == NULL || _channelCount <= 0) {
        return;
    }

    memset(outputBuffer, 0, frameCount * _channelCount * sizeof(short));

    UInt32 copiedFrames = 0;
    while (copiedFrames < frameCount &&
           _audioBufferEntries > 0 &&
           _audioBufferReadIndex != _audioBufferWriteIndex) {
        short *entryBase = &_audioCircularBuffer[_audioBufferReadIndex * _audioBufferStride];
        UInt32 framesAvailable = (UInt32)_audioSamplesPerFrame - _audioBufferReadFrameOffset;
        UInt32 framesToCopy = MIN(framesAvailable, frameCount - copiedFrames);

        memcpy(outputBuffer + (copiedFrames * _channelCount),
               entryBase + (_audioBufferReadFrameOffset * _channelCount),
               framesToCopy * _channelCount * sizeof(short));

        copiedFrames += framesToCopy;
        _audioBufferReadFrameOffset += framesToCopy;

        if (_audioBufferReadFrameOffset >= (UInt32)_audioSamplesPerFrame) {
            __sync_synchronize();
            _audioBufferReadIndex = (_audioBufferReadIndex + 1) % _audioBufferEntries;
            _audioBufferReadFrameOffset = 0;
        }
    }

    if (copiedFrames < frameCount) {
        _audioUnderrunCount++;
        if ((_audioUnderrunCount % 25) == 1) {
            Log(LOG_W, @"Audio underrun on backend=%d requested=%u copied=%u entries=%d",
                (int)_audioRendererBackend,
                (unsigned int)frameCount,
                (unsigned int)copiedFrames,
                _audioBufferEntries);
        }
    }
}

- (void)downmixPCMFrames:(UInt32)frameCount
             fromBuffer:(const short *)inputBuffer
     toStereoInt16Buffer:(short *)outputBuffer
{
    if (inputBuffer == NULL || outputBuffer == NULL) {
        return;
    }

    for (UInt32 frame = 0; frame < frameCount; frame++) {
        const short *src = inputBuffer + (frame * _channelCount);

        float left = 0.0f;
        float right = 0.0f;

        if (_channelCount >= 2) {
            left += src[0];
            right += src[1];
        } else if (_channelCount == 1) {
            left += src[0];
            right += src[0];
        }
        if (_channelCount >= 3) {
            left += src[2] * 0.707f;
            right += src[2] * 0.707f;
        }
        if (_channelCount >= 4) {
            left += src[3] * 0.22f;
            right += src[3] * 0.22f;
        }
        if (_channelCount >= 6) {
            left += src[4] * 0.60f;
            right += src[5] * 0.60f;
        }
        if (_channelCount >= 8) {
            left += src[6] * 0.45f;
            right += src[7] * 0.45f;
        }
        if (_channelCount >= 10) {
            left += src[8] * 0.32f;
            right += src[9] * 0.32f;
        }
        if (_channelCount >= 12) {
            left += src[10] * 0.25f;
            right += src[11] * 0.25f;
        }

        left = MAX(MIN(left, SHRT_MAX), SHRT_MIN);
        right = MAX(MIN(right, SHRT_MAX), SHRT_MIN);
        outputBuffer[(frame * 2)] = (short)left;
        outputBuffer[(frame * 2) + 1] = (short)right;
    }
}

- (void)copyPCMFrames:(UInt32)frameCount
         toFloatBufferList:(AudioBufferList *)outputData
          expectedChannels:(UInt32)expectedChannels
{
    if (outputData == NULL || _audioRenderScratchBuffer == NULL || expectedChannels == 0) {
        return;
    }

    [self copyPCMFrames:frameCount toInterleavedBuffer:_audioRenderScratchBuffer];

    BOOL interleaved = outputData->mNumberBuffers == 1 && expectedChannels > 1;
    if (interleaved) {
        float *dst = (float *)outputData->mBuffers[0].mData;
        if (dst == NULL) {
            return;
        }
        for (UInt32 frame = 0; frame < frameCount; frame++) {
            const short *src = _audioRenderScratchBuffer + (frame * _channelCount);
            for (UInt32 channel = 0; channel < expectedChannels; channel++) {
                dst[(frame * expectedChannels) + channel] = src[channel] / 32768.0f;
            }
        }
        outputData->mBuffers[0].mDataByteSize = frameCount * expectedChannels * sizeof(float);
        return;
    }

    UInt32 buffersToFill = MIN(outputData->mNumberBuffers, expectedChannels);
    for (UInt32 channel = 0; channel < outputData->mNumberBuffers; channel++) {
        AudioBuffer buffer = outputData->mBuffers[channel];
        if (buffer.mData == NULL) {
            continue;
        }

        float *dst = (float *)buffer.mData;
        memset(dst, 0, frameCount * sizeof(float));
        if (channel < buffersToFill) {
            for (UInt32 frame = 0; frame < frameCount; frame++) {
                dst[frame] = _audioRenderScratchBuffer[(frame * _channelCount) + channel] / 32768.0f;
            }
        }
        outputData->mBuffers[channel].mDataByteSize = frameCount * sizeof(float);
    }
}

- (void)downmixPCMFrames:(UInt32)frameCount
             fromBuffer:(const short *)inputBuffer
    toStereoFloatBufferList:(AudioBufferList *)outputData
{
    if (inputBuffer == NULL || outputData == NULL || outputData->mNumberBuffers == 0) {
        return;
    }

    BOOL interleaved = outputData->mNumberBuffers == 1;
    float *left = interleaved ? (float *)outputData->mBuffers[0].mData : (float *)outputData->mBuffers[0].mData;
    float *right = interleaved
        ? ((float *)outputData->mBuffers[0].mData) + 1
        : (outputData->mNumberBuffers > 1 ? (float *)outputData->mBuffers[1].mData : NULL);
    if (left == NULL || right == NULL) {
        return;
    }

    if (interleaved) {
        memset(outputData->mBuffers[0].mData, 0, frameCount * 2 * sizeof(float));
    } else {
        memset(left, 0, frameCount * sizeof(float));
        memset(right, 0, frameCount * sizeof(float));
    }

    for (UInt32 frame = 0; frame < frameCount; frame++) {
        const short *src = inputBuffer + (frame * _channelCount);
        float leftSample = 0.0f;
        float rightSample = 0.0f;

        if (_channelCount >= 2) {
            leftSample += src[0];
            rightSample += src[1];
        } else if (_channelCount == 1) {
            leftSample += src[0];
            rightSample += src[0];
        }
        if (_channelCount >= 3) {
            leftSample += src[2] * 0.707f;
            rightSample += src[2] * 0.707f;
        }
        if (_channelCount >= 4) {
            leftSample += src[3] * 0.22f;
            rightSample += src[3] * 0.22f;
        }
        if (_channelCount >= 6) {
            leftSample += src[4] * 0.60f;
            rightSample += src[5] * 0.60f;
        }
        if (_channelCount >= 8) {
            leftSample += src[6] * 0.45f;
            rightSample += src[7] * 0.45f;
        }
        if (_channelCount >= 10) {
            leftSample += src[8] * 0.32f;
            rightSample += src[9] * 0.32f;
        }
        if (_channelCount >= 12) {
            leftSample += src[10] * 0.25f;
            rightSample += src[11] * 0.25f;
        }

        float normalizedLeft = MAX(MIN(leftSample / 32768.0f, 1.0f), -1.0f);
        float normalizedRight = MAX(MIN(rightSample / 32768.0f, 1.0f), -1.0f);
        if (interleaved) {
            ((float *)outputData->mBuffers[0].mData)[frame * 2] = normalizedLeft;
            ((float *)outputData->mBuffers[0].mData)[frame * 2 + 1] = normalizedRight;
        } else {
            left[frame] = normalizedLeft;
            right[frame] = normalizedRight;
        }
    }

    if (interleaved) {
        outputData->mBuffers[0].mDataByteSize = frameCount * 2 * sizeof(float);
    } else {
        outputData->mBuffers[0].mDataByteSize = frameCount * sizeof(float);
        if (outputData->mNumberBuffers > 1) {
            outputData->mBuffers[1].mDataByteSize = frameCount * sizeof(float);
        }
    }
}

- (BOOL)initializeDirectAudioRendererWithOpusConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig
                                      channelLayout:(const AudioChannelLayout *)channelLayout
{
    if (opusConfig == NULL) {
        return NO;
    }

    _audioDeviceChannelCount = MLDefaultOutputChannelCount();
    UInt32 requestedRenderChannels = (UInt32)opusConfig->channelCount;

    for (NSUInteger attempt = 0; attempt < 2; attempt++) {
        BOOL stereoFallback = (attempt == 1 && requestedRenderChannels > 2);
        _audioRenderChannelCount = stereoFallback ? 2 : requestedRenderChannels;

        AudioComponentDescription desc = {0};
        desc.componentType = kAudioUnitType_Output;
        desc.componentSubType = kAudioUnitSubType_DefaultOutput;
        desc.componentManufacturer = kAudioUnitManufacturer_Apple;

        AudioComponent component = AudioComponentFindNext(NULL, &desc);
        if (component == NULL) {
            return NO;
        }

        OSStatus status = AudioComponentInstanceNew(component, &_audioUnit);
        if (status != noErr) {
            _audioUnit = NULL;
            return NO;
        }

        AURenderCallbackStruct callback = {0};
        callback.inputProc = RenderDirectAudioUnit;
        callback.inputProcRefCon = (__bridge void *)self;
        status = AudioUnitSetProperty(_audioUnit,
                                      kAudioUnitProperty_SetRenderCallback,
                                      kAudioUnitScope_Input,
                                      0,
                                      &callback,
                                      sizeof(callback));
        if (status != noErr) {
            [self cleanupSelectedAudioRenderer];
            if (!stereoFallback && requestedRenderChannels > 2) {
                Log(LOG_W, @"Direct renderer multichannel callback setup failed (%d); retrying with stereo downmix", status);
                continue;
            }
            return NO;
        }

        UInt32 maxFrames = MAX((UInt32)opusConfig->samplesPerFrame, (UInt32)512);
        AudioUnitSetProperty(_audioUnit,
                             kAudioUnitProperty_MaximumFramesPerSlice,
                             kAudioUnitScope_Global,
                             0,
                             &maxFrames,
                             sizeof(maxFrames));

        AudioStreamBasicDescription audioFormat = {0};
        audioFormat.mSampleRate = opusConfig->sampleRate;
        audioFormat.mBitsPerChannel = 32;
        audioFormat.mFormatID = kAudioFormatLinearPCM;
        audioFormat.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
        audioFormat.mChannelsPerFrame = _audioRenderChannelCount;
        audioFormat.mBytesPerFrame = sizeof(float);
        audioFormat.mBytesPerPacket = sizeof(float);
        audioFormat.mFramesPerPacket = 1;
        audioFormat.mReserved = 0;

        status = AudioUnitSetProperty(_audioUnit,
                                      kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input,
                                      0,
                                      &audioFormat,
                                      sizeof(audioFormat));
        if (status != noErr) {
            [self cleanupSelectedAudioRenderer];
            if (!stereoFallback && requestedRenderChannels > 2) {
                Log(LOG_W, @"Direct renderer multichannel stream format rejected (%d); retrying with stereo downmix", status);
                continue;
            }
            return NO;
        }

        if (!stereoFallback && channelLayout != NULL && opusConfig->channelCount > 2) {
            status = AudioUnitSetProperty(_audioUnit,
                                          kAudioUnitProperty_AudioChannelLayout,
                                          kAudioUnitScope_Input,
                                          0,
                                          channelLayout,
                                          sizeof(AudioChannelLayout));
            if (status != noErr) {
                [self cleanupSelectedAudioRenderer];
                Log(LOG_W, @"Direct renderer channel layout rejected (%d); retrying with stereo downmix", status);
                continue;
            }
        }

        status = AudioUnitInitialize(_audioUnit);
        if (status != noErr) {
            [self cleanupSelectedAudioRenderer];
            if (!stereoFallback && requestedRenderChannels > 2) {
                Log(LOG_W, @"Direct renderer multichannel initialization failed (%d); retrying with stereo downmix", status);
                continue;
            }
            return NO;
        }

        status = AudioOutputUnitStart(_audioUnit);
        if (status != noErr) {
            [self cleanupSelectedAudioRenderer];
            if (!stereoFallback && requestedRenderChannels > 2) {
                Log(LOG_W, @"Direct renderer multichannel start failed (%d); retrying with stereo downmix", status);
                continue;
            }
            return NO;
        }

        if (stereoFallback) {
            Log(LOG_W, @"Direct renderer active with stereo downmix fallback: streamChannels=%d deviceChannels=%d",
                opusConfig->channelCount,
                _audioDeviceChannelCount);
        }

        Log(LOG_I, @"Initialized direct audio renderer: streamChannels=%d deviceChannels=%d renderChannels=%d samplesPerFrame=%d bufferEntries=%d",
            opusConfig->channelCount,
            _audioDeviceChannelCount,
            _audioRenderChannelCount,
            opusConfig->samplesPerFrame,
            _audioBufferEntries);
        return YES;
    }

    return NO;
}

- (void)renderEnhancedStereoPCMFrames:(UInt32)frameCount
                    toFloatBufferList:(AudioBufferList *)outputData
{
    if (outputData == NULL || _audioRenderScratchBuffer == NULL || outputData->mNumberBuffers == 0) {
        return;
    }

    BOOL interleaved = outputData->mNumberBuffers == 1;
    float *interleavedDst = interleaved ? (float *)outputData->mBuffers[0].mData : NULL;
    float *leftDst = interleaved ? NULL : (float *)outputData->mBuffers[0].mData;
    float *rightDst = interleaved
        ? NULL
        : (outputData->mNumberBuffers > 1 ? (float *)outputData->mBuffers[1].mData : NULL);
    if ((interleaved && interleavedDst == NULL) || (!interleaved && (leftDst == NULL || rightDst == NULL))) {
        return;
    }

    const BOOL headphones = _enhancedAudioOutputTarget == MLAudioEnhancedOutputTargetHeadphones;
    const BOOL fallbackDecoderActive = _usingAudioFallbackDecoderConfig;
    const float spatial = MAX(0.0f, MIN(1.0f, (float)_enhancedAudioSpatialIntensity));
    const float width = MAX(0.0f, MIN(1.0f, (float)_enhancedAudioSoundstageWidth));
    const float centerGain = headphones ? (0.84f - (width * 0.05f)) : (0.86f - (width * 0.04f));
    const float lfeGain = fallbackDecoderActive ? 0.03f : (headphones ? 0.08f : 0.12f);
    const float sideSame = fallbackDecoderActive ? 0.02f : (0.22f + (spatial * 0.28f));
    const float sideCross = fallbackDecoderActive ? 0.01f : (0.03f + (width * 0.06f));
    const float rearSame = fallbackDecoderActive ? 0.01f : (0.17f + (spatial * 0.22f));
    const float rearCross = fallbackDecoderActive ? 0.00f : (0.06f + (width * 0.08f));
    const float topSame = fallbackDecoderActive ? 0.00f : (0.10f + (spatial * 0.14f));
    const float topCross = fallbackDecoderActive ? 0.00f : (0.05f + (width * 0.06f));
    const float widthScale = 1.0f + (width * (headphones ? 0.34f : 0.16f));
    const float outputTrim = headphones ? 0.98f : 1.0f;

    UInt32 framesRemaining = frameCount;
    UInt32 frameOffset = 0;
    while (framesRemaining > 0) {
        UInt32 chunkFrames = MIN(framesRemaining, (UInt32)AUDIO_RENDER_SCRATCH_FRAMES);
        BOOL usedCoreAudioDownmix = NO;
        float *coreAudioLeft = NULL;
        float *coreAudioRight = NULL;

        if (_enhancedUsesCoreAudioDownmix &&
            _enhancedDownmixConverter != nil &&
            _enhancedDownmixInputBuffer != nil &&
            _enhancedDownmixOutputBuffer != nil) {
            [self copyPCMFrames:chunkFrames toInterleavedBuffer:_audioRenderScratchBuffer];

            AudioBufferList *inputBufferList = _enhancedDownmixInputBuffer.mutableAudioBufferList;
            if (inputBufferList != NULL &&
                inputBufferList->mNumberBuffers > 0 &&
                inputBufferList->mBuffers[0].mData != NULL) {
                UInt32 byteCount = chunkFrames * _channelCount * sizeof(short);
                memcpy(inputBufferList->mBuffers[0].mData, _audioRenderScratchBuffer, byteCount);
                inputBufferList->mBuffers[0].mDataByteSize = byteCount;
                _enhancedDownmixInputBuffer.frameLength = chunkFrames;
                _enhancedDownmixOutputBuffer.frameLength = 0;

                NSError *conversionError = nil;
                if ([_enhancedDownmixConverter convertToBuffer:_enhancedDownmixOutputBuffer
                                                   fromBuffer:_enhancedDownmixInputBuffer
                                                        error:&conversionError] &&
                    _enhancedDownmixOutputBuffer.frameLength == chunkFrames &&
                    _enhancedDownmixOutputBuffer.floatChannelData != NULL) {
                    coreAudioLeft = _enhancedDownmixOutputBuffer.floatChannelData[0];
                    coreAudioRight =
                        (_enhancedDownmixOutputBuffer.format.channelCount > 1 &&
                         _enhancedDownmixOutputBuffer.floatChannelData[1] != NULL)
                        ? _enhancedDownmixOutputBuffer.floatChannelData[1]
                        : _enhancedDownmixOutputBuffer.floatChannelData[0];
                    usedCoreAudioDownmix = (coreAudioLeft != NULL && coreAudioRight != NULL);
                } else {
                    _enhancedDownmixFailureCount++;
                    if (_enhancedDownmixFailureCount <= 5 || (_enhancedDownmixFailureCount % 50) == 0) {
                        Log(LOG_W, @"Enhanced Core Audio downmix failed: channels=%d frames=%u error=%@ failures=%llu",
                            _channelCount,
                            (unsigned int)chunkFrames,
                            conversionError.localizedDescription ?: @"unknown",
                            (unsigned long long)_enhancedDownmixFailureCount);
                    }
                }
            }
        }

        if (!usedCoreAudioDownmix) {
            [self copyPCMFrames:chunkFrames toInterleavedBuffer:_audioRenderScratchBuffer];
        }

        for (UInt32 frame = 0; frame < chunkFrames; frame++) {
            float normalizedLeft = 0.0f;
            float normalizedRight = 0.0f;

            if (usedCoreAudioDownmix) {
                normalizedLeft = coreAudioLeft[frame];
                normalizedRight = coreAudioRight[frame];
            } else {
                const short *src = _audioRenderScratchBuffer + (frame * _channelCount);

                float left = 0.0f;
                float right = 0.0f;

                if (_channelCount >= 2) {
                    left += src[0];
                    right += src[1];
                } else if (_channelCount == 1) {
                    left += src[0];
                    right += src[0];
                }
                if (_channelCount >= 3) {
                    left += src[2] * centerGain;
                    right += src[2] * centerGain;
                }
                if (_channelCount >= 4) {
                    left += src[3] * lfeGain;
                    right += src[3] * lfeGain;
                }
                if (_channelCount >= 6) {
                    left += src[4] * rearSame;
                    right += src[4] * rearCross;
                    right += src[5] * rearSame;
                    left += src[5] * rearCross;
                }
                if (_channelCount >= 8) {
                    left += src[6] * sideSame;
                    right += src[6] * sideCross;
                    right += src[7] * sideSame;
                    left += src[7] * sideCross;
                }
                if (_channelCount >= 10) {
                    left += src[8] * topSame;
                    right += src[8] * topCross;
                    right += src[9] * topSame;
                    left += src[9] * topCross;
                }
                if (_channelCount >= 12) {
                    left += src[10] * (topSame * 0.88f);
                    right += src[10] * (topCross + 0.03f);
                    right += src[11] * (topSame * 0.88f);
                    left += src[11] * (topCross + 0.03f);
                }

                normalizedLeft = left / 32768.0f;
                normalizedRight = right / 32768.0f;
            }

            float mid = (normalizedLeft + normalizedRight) * 0.5f;
            float side = (normalizedLeft - normalizedRight) * 0.5f;
            float widenedSide = side * widthScale;
            float finalLeft = MLApplyMakeupGainAndSoftClip((mid + widenedSide) * outputTrim, kEnhancedRendererOutputGain);
            float finalRight = MLApplyMakeupGainAndSoftClip((mid - widenedSide) * outputTrim, kEnhancedRendererOutputGain);

            if (interleaved) {
                UInt32 dstIndex = (frameOffset + frame) * 2;
                interleavedDst[dstIndex] = finalLeft;
                interleavedDst[dstIndex + 1] = finalRight;
            } else {
                leftDst[frameOffset + frame] = finalLeft;
                rightDst[frameOffset + frame] = finalRight;
            }
        }

        frameOffset += chunkFrames;
        framesRemaining -= chunkFrames;
    }

    if (interleaved) {
        outputData->mBuffers[0].mDataByteSize = frameCount * 2 * sizeof(float);
    } else {
        outputData->mBuffers[0].mDataByteSize = frameCount * sizeof(float);
        if (outputData->mNumberBuffers > 1) {
            outputData->mBuffers[1].mDataByteSize = frameCount * sizeof(float);
        }
    }
}

- (void)configureEnhancedAudioUnits
{
    if (_enhancedAudioEQ == nil || _enhancedAudioReverb == nil || _enhancedAudioSourceNode == nil) {
        return;
    }

    NSArray<NSNumber *> *gains = _enhancedAudioEQGains;
    NSUInteger resolvedBandCount = 0;
    const double *frequencies = MLEnhancedEQFrequencyTable(gains.count, &resolvedBandCount);
    if (gains.count != resolvedBandCount) {
        frequencies = MLEnhancedEQFrequencyTable(kEnhancedEQBandCount12, &resolvedBandCount);
        gains = nil;
    }

    float maxPositiveGain = 0.0f;
    for (NSUInteger i = 0; i < MIN((NSUInteger)_enhancedAudioEQ.bands.count, resolvedBandCount); i++) {
        AVAudioUnitEQFilterParameters *band = _enhancedAudioEQ.bands[i];
        band.filterType = AVAudioUnitEQFilterTypeParametric;
        band.frequency = frequencies[i];
        band.bandwidth = 0.7f;
        band.gain = (float)(i < gains.count ? gains[i].doubleValue : 0.0);
        maxPositiveGain = MAX(maxPositiveGain, band.gain);
        band.bypass = NO;
    }

    float clampedReverb = MAX(0.0f, MIN(1.0f, (float)_enhancedAudioReverbAmount));
    [_enhancedAudioReverb loadFactoryPreset:
        (_enhancedAudioOutputTarget == MLAudioEnhancedOutputTargetHeadphones)
        ? AVAudioUnitReverbPresetSmallRoom
        : AVAudioUnitReverbPresetMediumRoom];
    _enhancedAudioReverb.wetDryMix =
        clampedReverb *
        (_enhancedAudioOutputTarget == MLAudioEnhancedOutputTargetHeadphones ? 10.0f : 18.0f);

    _enhancedAudioEQ.globalGain =
        -MIN(2.5f,
             MAX(0.0f, maxPositiveGain) * 0.20f +
             clampedReverb * 0.8f);

    _enhancedAudioSourceNode.volume = 1.0f;
}

- (BOOL)prepareEnhancedDownmixConverterWithOpusConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig
{
    if (opusConfig == NULL || opusConfig->channelCount <= 0) {
        return NO;
    }

    _enhancedDownmixConverter = nil;
    _enhancedDownmixInputBuffer = nil;
    _enhancedDownmixOutputBuffer = nil;
    _enhancedUsesCoreAudioDownmix = NO;
    _enhancedDownmixFailureCount = 0;

    if (opusConfig->channelCount > 2) {
        // Manual virtualization preserves surround placement better than AVAudioConverter.
        // Empirically, AVAudioConverter with 5.1/7.1/7.1.4 layouts on macOS can collapse to
        // front-L/R only instead of performing a real surround-to-stereo downmix, which makes
        // Enhanced mode lose side/rear/top content entirely.
        return NO;
    }

    AVAudioChannelLayout *sourceLayout = MLCreateAVAudioChannelLayout(opusConfig->channelCount);
    AVAudioFormat *sourceFormat = sourceLayout != nil
        ? [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                           sampleRate:opusConfig->sampleRate
                                          interleaved:YES
                                        channelLayout:sourceLayout]
        : [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                           sampleRate:opusConfig->sampleRate
                                             channels:opusConfig->channelCount
                                          interleaved:YES];
    AVAudioFormat *stereoFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:opusConfig->sampleRate
                                                                                  channels:2];
    if (sourceFormat == nil || stereoFormat == nil) {
        return NO;
    }

    _enhancedDownmixConverter = [[AVAudioConverter alloc] initFromFormat:sourceFormat toFormat:stereoFormat];
    if (_enhancedDownmixConverter == nil) {
        return NO;
    }

    _enhancedDownmixInputBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:sourceFormat
                                                                 frameCapacity:AUDIO_RENDER_SCRATCH_FRAMES];
    _enhancedDownmixOutputBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:stereoFormat
                                                                  frameCapacity:AUDIO_RENDER_SCRATCH_FRAMES];
    if (_enhancedDownmixInputBuffer == nil || _enhancedDownmixOutputBuffer == nil) {
        _enhancedDownmixConverter = nil;
        _enhancedDownmixInputBuffer = nil;
        _enhancedDownmixOutputBuffer = nil;
        return NO;
    }

    _enhancedUsesCoreAudioDownmix = YES;
    return YES;
}

- (BOOL)recreateAudioDecoderWithConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig
                                reason:(NSString *)reason
{
    if (opusConfig == NULL) {
        return NO;
    }

    OPUS_MULTISTREAM_CONFIGURATION preparedConfig = {};
    MLPrepareOpusDecoderConfig(opusConfig, &preparedConfig);

    int err = OPUS_OK;
    OpusMSDecoder *replacementDecoder = opus_multistream_decoder_create(preparedConfig.sampleRate,
                                                                        preparedConfig.channelCount,
                                                                        preparedConfig.streams,
                                                                        preparedConfig.coupledStreams,
                                                                        preparedConfig.mapping,
                                                                        &err);
    if (replacementDecoder == NULL || err != OPUS_OK) {
        Log(LOG_W, @"Failed to recreate Opus decoder (%@): streams=%d coupled=%d error=%d",
            reason ?: @"unknown",
            preparedConfig.streams,
            preparedConfig.coupledStreams,
            err);
        if (replacementDecoder != NULL) {
            opus_multistream_decoder_destroy(replacementDecoder);
        }
        return NO;
    }

    if (_opusDecoder != NULL) {
        opus_multistream_decoder_destroy(_opusDecoder);
    }
    _opusDecoder = replacementDecoder;
    _audioCurrentDecoderConfig = *opusConfig;
    _usingAudioFallbackDecoderConfig = _hasAudioFallbackDecoderConfig &&
        MLIs714CompatibilityOpusConfig(opusConfig);
    _audioBufferWriteIndex = 0;
    _audioBufferReadIndex = 0;
    _audioBufferReadFrameOffset = 0;
    _audioUnderrunCount = 0;
    _audioDecodeFailureCount = 0;
    _audioConsecutiveDecodeFailures = 0;
    _audioDecodeSampleCount = 0;
    _audioFallbackDecodeSuccessCount = 0;
    if (_audioCircularBuffer != NULL) {
        memset(_audioCircularBuffer, 0, _audioBufferEntries * _audioBufferStride * sizeof(short));
    }

    Log(LOG_I, @"Recreated Opus decoder (%@): channels=%d streams=%d coupled=%d",
        reason ?: @"unknown",
        preparedConfig.channelCount,
        preparedConfig.streams,
        preparedConfig.coupledStreams);
    return YES;
}

- (BOOL)attempt714DecoderTopologyFallbackAfterDecodeError:(int)decodeError
{
    if (decodeError >= 0 ||
        !_hasAudioFallbackDecoderConfig ||
        _usingAudioFallbackDecoderConfig ||
        _audioConsecutiveDecodeFailures < 8) {
        return NO;
    }

    Log(LOG_W, @"Attempting 7.1.4 Opus decoder fallback after %llu consecutive failures: current=%d/%d fallback=%d/%d error=%d",
        (unsigned long long)_audioConsecutiveDecodeFailures,
        _audioCurrentDecoderConfig.streams,
        _audioCurrentDecoderConfig.coupledStreams,
        _audioFallbackDecoderConfig.streams,
        _audioFallbackDecoderConfig.coupledStreams,
        decodeError);
    _audioPrimaryReprobeAttempted = NO;
    return [self recreateAudioDecoderWithConfig:&_audioFallbackDecoderConfig
                                         reason:@"7.1.4 fallback"];
}

- (BOOL)attempt714PrimaryDecoderReprobeWithSampleData:(char *)sampleData
                                         sampleLength:(int)sampleLength
{
    if (_streamConfig.disableHighQualitySurround ||
        !_usingAudioFallbackDecoderConfig ||
        _audioPrimaryReprobeAttempted ||
        !MLIs714HighQualityOpusConfig(&_audioAdvertisedOpusConfig) ||
        _audioFallbackDecodeSuccessCount < 120) {
        return NO;
    }

    _audioPrimaryReprobeAttempted = YES;
    Log(LOG_I, @"Attempting 7.1.4 primary decoder reprobe after %llu successful fallback decodes",
        (unsigned long long)_audioFallbackDecodeSuccessCount);

    if (![self recreateAudioDecoderWithConfig:&_audioAdvertisedOpusConfig
                                       reason:@"7.1.4 primary reprobe"]) {
        return NO;
    }

    int decodeLen = opus_multistream_decode(_opusDecoder,
                                            (unsigned char *)sampleData,
                                            sampleLength,
                                            (short *)&_audioCircularBuffer[_audioBufferWriteIndex * _audioBufferStride],
                                            _audioSamplesPerFrame,
                                            0);
    if (decodeLen > 0) {
        short *buffer = &_audioCircularBuffer[_audioBufferWriteIndex * _audioBufferStride];
        for (int i = 0; i < decodeLen * _channelCount; i++) {
            buffer[i] = (short)(buffer[i] * _audioVolumeMultiplier);
        }

        __sync_synchronize();
        _audioBufferWriteIndex = (_audioBufferWriteIndex + 1) % _audioBufferEntries;
        _audioDecodeSampleCount++;
        Log(LOG_I, @"7.1.4 primary decoder restored after fallback: decodedFrames=%d sampleLength=%d",
            decodeLen,
            sampleLength);
        return YES;
    }

    Log(LOG_W, @"7.1.4 primary decoder reprobe failed: error=%d; returning to fallback",
        decodeLen);
    [self recreateAudioDecoderWithConfig:&_audioFallbackDecoderConfig
                                  reason:@"7.1.4 fallback reprobe rollback"];
    return NO;
}

- (BOOL)initializeEnhancedAudioRendererWithOpusConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig
{
    if (opusConfig == NULL) {
        return NO;
    }

    if (@available(macOS 10.15, *)) {
        AVAudioFormat *sourceFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:opusConfig->sampleRate
                                                                                     channels:2];
        AVAudioFormat *renderFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:opusConfig->sampleRate
                                                                                     channels:2];
        [self prepareEnhancedDownmixConverterWithOpusConfig:opusConfig];
        __weak Connection *weakSelf = self;
        _enhancedAudioSourceNode = [[AVAudioSourceNode alloc] initWithFormat:sourceFormat renderBlock:^OSStatus(BOOL * _Nonnull isSilence,
                                                                                                                const AudioTimeStamp * _Nonnull timestamp,
                                                                                                                AVAudioFrameCount frameCount,
                                                                                                                AudioBufferList * _Nonnull outputData) {
            __strong Connection *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return noErr;
            }

            [strongSelf renderEnhancedStereoPCMFrames:frameCount
                                    toFloatBufferList:outputData];
            *isSilence = NO;
            return noErr;
        }];

        NSUInteger resolvedBandCount = 0;
        MLEnhancedEQFrequencyTable(_enhancedAudioEQGains.count, &resolvedBandCount);
        _enhancedAudioEngine = [[AVAudioEngine alloc] init];
        _enhancedAudioReverb = [[AVAudioUnitReverb alloc] init];
        _enhancedAudioEQ = [[AVAudioUnitEQ alloc] initWithNumberOfBands:(uint32_t)resolvedBandCount];

        [_enhancedAudioEngine attachNode:_enhancedAudioSourceNode];
        [_enhancedAudioEngine attachNode:_enhancedAudioReverb];
        [_enhancedAudioEngine attachNode:_enhancedAudioEQ];

        [_enhancedAudioEngine connect:_enhancedAudioSourceNode to:_enhancedAudioReverb format:sourceFormat];
        [_enhancedAudioEngine connect:_enhancedAudioReverb to:_enhancedAudioEQ format:renderFormat];
        [_enhancedAudioEngine connect:_enhancedAudioEQ to:_enhancedAudioEngine.mainMixerNode format:renderFormat];
        [self configureEnhancedAudioUnits];

        [_enhancedAudioEngine prepare];

        NSError *error = nil;
        if (![_enhancedAudioEngine startAndReturnError:&error]) {
            Log(LOG_W, @"Failed to start enhanced audio renderer: %@", error.localizedDescription);
            [self cleanupSelectedAudioRenderer];
            return NO;
        }

        _audioRenderChannelCount = 2;
        Log(LOG_I, @"Enhanced renderer using stereo virtualizer: streamChannels=%d target=%d preset=%d spatial=%.2f width=%.2f reverb=%.2f",
            opusConfig->channelCount,
            _enhancedAudioOutputTarget,
            _enhancedAudioPreset,
            _enhancedAudioSpatialIntensity,
            _enhancedAudioSoundstageWidth,
            _enhancedAudioReverbAmount);
        if (_enhancedUsesCoreAudioDownmix) {
            Log(LOG_I, @"Enhanced renderer Core Audio downmix active: streamChannels=%d -> stereo", opusConfig->channelCount);
        } else if (opusConfig->channelCount > 2) {
            Log(LOG_I, @"Enhanced renderer using manual surround virtualization: streamChannels=%d -> stereo", opusConfig->channelCount);
        } else {
            Log(LOG_W, @"Enhanced renderer Core Audio downmix unavailable; using manual stereo virtualization fallback");
        }
        if (opusConfig->channelCount > 2) {
            Log(LOG_I, @"Enhanced multichannel virtualization active: streamChannels=%d -> stereo", opusConfig->channelCount);
        }
        Log(LOG_I, @"Initialized enhanced audio renderer: preset=%d target=%d spatial=%.2f width=%.2f samplesPerFrame=%d bufferEntries=%d",
            _enhancedAudioPreset,
            _enhancedAudioOutputTarget,
            _enhancedAudioSpatialIntensity,
            _enhancedAudioSoundstageWidth,
            opusConfig->samplesPerFrame,
            _audioBufferEntries);
        return YES;
    }

    return NO;
}

- (void)cleanupSelectedAudioRenderer
{
    if (_audioQueue != NULL) {
        AudioQueueStop(_audioQueue, true);
        AudioQueueDispose(_audioQueue, true);
        _audioQueue = NULL;
    }

    if (_audioQueueContext != NULL) {
        CFBridgingRelease(_audioQueueContext);
        _audioQueueContext = NULL;
    }

    if (_audioUnit != NULL) {
        AudioOutputUnitStop(_audioUnit);
        AudioUnitUninitialize(_audioUnit);
        AudioComponentInstanceDispose(_audioUnit);
        _audioUnit = NULL;
    }

    if (_enhancedAudioEngine != nil) {
        [_enhancedAudioEngine stop];
        _enhancedAudioEngine = nil;
        _enhancedAudioSourceNode = nil;
        _enhancedAudioReverb = nil;
        _enhancedAudioEQ = nil;
    }

    _enhancedDownmixConverter = nil;
    _enhancedDownmixInputBuffer = nil;
    _enhancedDownmixOutputBuffer = nil;
    _enhancedUsesCoreAudioDownmix = NO;
    _enhancedDownmixFailureCount = 0;

    _audioRendererBackend = MLAudioRendererBackendLegacyQueue;
    _audioRenderChannelCount = 0;
}

static OSStatus RenderDirectAudioUnit(void *inRefCon,
                                      AudioUnitRenderActionFlags *ioActionFlags,
                                      const AudioTimeStamp *inTimeStamp,
                                      UInt32 inBusNumber,
                                      UInt32 inNumberFrames,
                                      AudioBufferList *ioData) {
    Connection *conn = (__bridge Connection *)inRefCon;
    if (conn == nil || ioData == NULL || conn->_audioRenderScratchBuffer == NULL) {
        return noErr;
    }

    UInt32 framesRemaining = inNumberFrames;
    UInt32 frameOffset = 0;
    BOOL interleaved = ioData->mNumberBuffers == 1 && conn->_audioRenderChannelCount > 1;
    while (framesRemaining > 0) {
        UInt32 chunkFrames = MIN(framesRemaining, (UInt32)AUDIO_RENDER_SCRATCH_FRAMES);
        [conn copyPCMFrames:chunkFrames toInterleavedBuffer:conn->_audioRenderScratchBuffer];

        if (conn->_audioRenderChannelCount == conn->_channelCount) {
            if (interleaved) {
                float *dst = ((float *)ioData->mBuffers[0].mData) + (frameOffset * conn->_audioRenderChannelCount);
                for (UInt32 frame = 0; frame < chunkFrames; frame++) {
                    const short *src = conn->_audioRenderScratchBuffer + (frame * conn->_channelCount);
                    for (UInt32 channel = 0; channel < (UInt32)conn->_audioRenderChannelCount; channel++) {
                        dst[(frame * conn->_audioRenderChannelCount) + channel] =
                            MLApplyMakeupGainAndSoftClip(src[channel] / 32768.0f, kDirectRendererMakeupGain);
                    }
                }
            } else {
                for (UInt32 channel = 0; channel < MIN(ioData->mNumberBuffers, (UInt32)conn->_audioRenderChannelCount); channel++) {
                    float *dst = ((float *)ioData->mBuffers[channel].mData) + frameOffset;
                    for (UInt32 frame = 0; frame < chunkFrames; frame++) {
                        dst[frame] = MLApplyMakeupGainAndSoftClip(
                            conn->_audioRenderScratchBuffer[(frame * conn->_channelCount) + channel] / 32768.0f,
                            kDirectRendererMakeupGain);
                    }
                }
            }
        } else if (conn->_audioRenderChannelCount == 2) {
            if (interleaved) {
                float *dst = ((float *)ioData->mBuffers[0].mData) + (frameOffset * 2);
                for (UInt32 frame = 0; frame < chunkFrames; frame++) {
                    const short *src = conn->_audioRenderScratchBuffer + (frame * conn->_channelCount);
                    float left = 0.0f;
                    float right = 0.0f;
                    if (conn->_channelCount >= 2) {
                        left += src[0];
                        right += src[1];
                    } else if (conn->_channelCount == 1) {
                        left += src[0];
                        right += src[0];
                    }
                    if (conn->_channelCount >= 3) {
                        left += src[2] * 0.707f;
                        right += src[2] * 0.707f;
                    }
                    if (conn->_channelCount >= 4) {
                        left += src[3] * 0.22f;
                        right += src[3] * 0.22f;
                    }
                    if (conn->_channelCount >= 6) {
                        left += src[4] * 0.60f;
                        right += src[5] * 0.60f;
                    }
                    if (conn->_channelCount >= 8) {
                        left += src[6] * 0.45f;
                        right += src[7] * 0.45f;
                    }
                    if (conn->_channelCount >= 10) {
                        left += src[8] * 0.32f;
                        right += src[9] * 0.32f;
                    }
                    if (conn->_channelCount >= 12) {
                        left += src[10] * 0.25f;
                        right += src[11] * 0.25f;
                    }
                    dst[frame * 2] = MLApplyMakeupGainAndSoftClip(left / 32768.0f, kDirectRendererMakeupGain);
                    dst[frame * 2 + 1] = MLApplyMakeupGainAndSoftClip(right / 32768.0f, kDirectRendererMakeupGain);
                }
            } else if (ioData->mNumberBuffers >= 2) {
                float *leftDst = ((float *)ioData->mBuffers[0].mData) + frameOffset;
                float *rightDst = ((float *)ioData->mBuffers[1].mData) + frameOffset;
                for (UInt32 frame = 0; frame < chunkFrames; frame++) {
                    const short *src = conn->_audioRenderScratchBuffer + (frame * conn->_channelCount);
                    float left = 0.0f;
                    float right = 0.0f;
                    if (conn->_channelCount >= 2) {
                        left += src[0];
                        right += src[1];
                    } else if (conn->_channelCount == 1) {
                        left += src[0];
                        right += src[0];
                    }
                    if (conn->_channelCount >= 3) {
                        left += src[2] * 0.707f;
                        right += src[2] * 0.707f;
                    }
                    if (conn->_channelCount >= 4) {
                        left += src[3] * 0.22f;
                        right += src[3] * 0.22f;
                    }
                    if (conn->_channelCount >= 6) {
                        left += src[4] * 0.60f;
                        right += src[5] * 0.60f;
                    }
                    if (conn->_channelCount >= 8) {
                        left += src[6] * 0.45f;
                        right += src[7] * 0.45f;
                    }
                    if (conn->_channelCount >= 10) {
                        left += src[8] * 0.32f;
                        right += src[9] * 0.32f;
                    }
                    if (conn->_channelCount >= 12) {
                        left += src[10] * 0.25f;
                        right += src[11] * 0.25f;
                    }
                    leftDst[frame] = MLApplyMakeupGainAndSoftClip(left / 32768.0f, kDirectRendererMakeupGain);
                    rightDst[frame] = MLApplyMakeupGainAndSoftClip(right / 32768.0f, kDirectRendererMakeupGain);
                }
            }
        } else {
            for (UInt32 channel = 0; channel < ioData->mNumberBuffers; channel++) {
                memset(((float *)ioData->mBuffers[channel].mData) + frameOffset,
                       0,
                       chunkFrames * sizeof(float));
            }
        }

        frameOffset += chunkFrames;
        framesRemaining -= chunkFrames;
    }

    if (interleaved) {
        ioData->mBuffers[0].mDataByteSize = inNumberFrames * conn->_audioRenderChannelCount * sizeof(float);
    } else {
        for (UInt32 channel = 0; channel < ioData->mNumberBuffers; channel++) {
            ioData->mBuffers[channel].mDataByteSize = inNumberFrames * sizeof(float);
        }
    }
    return noErr;
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
            if (!isHighFrequencyDiagnostic || LoggerIsInputDiagnosticsEnabled()) {
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

void ClClipboardItemReceived(const LI_CLIPBOARD_ITEM *item)
{
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);

    Log(LOG_I, @"Clipboard item received: type=%u length=%u flags=0x%x itemId=%llu mime=%s name=%s",
        item != NULL ? item->type : 0,
        item != NULL ? item->length : 0,
        item != NULL ? item->flags : 0,
        item != NULL ? item->itemId : 0,
        item != NULL && item->mimeType != NULL ? item->mimeType : "",
        item != NULL && item->name != NULL ? item->name : "");

    if (callbacks != nil &&
        [callbacks respondsToSelector:@selector(clipboardItemReceived:)]) {
        [callbacks clipboardItemReceived:item];
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
    _audioOutputMode = config.audioOutputMode;
    _enhancedAudioOutputTarget = (int)MLResolveEnhancedOutputTarget((MLAudioEnhancedOutputTarget)config.enhancedAudioOutputTarget);
    _enhancedAudioPreset = config.enhancedAudioPreset;
    _enhancedAudioSpatialIntensity = config.enhancedAudioSpatialIntensity;
    _enhancedAudioSoundstageWidth = config.enhancedAudioSoundstageWidth;
    _enhancedAudioReverbAmount = config.enhancedAudioReverbAmount;
    _enhancedAudioEQGains = [config.enhancedAudioEQGains copy];
    _audioRendererBackend = MLAudioRendererBackendLegacyQueue;
    _audioDeviceChannelCount = 2;
    _audioRenderChannelCount = 0;
    _audioBufferReadFrameOffset = 0;
    _clipboardControlQueue = dispatch_queue_create("moonlight.connection.clipboard", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_clipboardControlQueue, gClipboardQueueKey, gClipboardQueueKey, NULL);
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
    _connectionContext.controlContext.connectionContext = &_connectionContext;

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
    _streamConfig.disableHighQualitySurround = config.disableHighQualitySurround;
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

    if (av1Supported) {
        if (config.enableHdr) {
            supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN10;
        } else {
            supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN8;
        }

        if (enableYuv444) {
            supportedVideoFormats |= VIDEO_FORMAT_AV1_HIGH8_444;
            if (config.enableHdr) {
                supportedVideoFormats |= VIDEO_FORMAT_AV1_HIGH10_444;
            }
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

    _streamConfig.dynamicRangeMode =
        MLResolvedDynamicRangeModeForPreference(config.enableHdr, config.hdrTransferFunction);
    Log(LOG_I, @"[diag] HDR transfer preference resolved: hdr=%d tf=%d dynamicRangeMode=%d",
        config.enableHdr ? 1 : 0,
        config.hdrTransferFunction,
        _streamConfig.dynamicRangeMode);

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
    _clCallbacks.clipboardItemReceived = ClClipboardItemReceived;

    return self;
}

- (void *)inputStreamContext {
    return LiGetInputContextFromConnectionCtx(&_connectionContext);
}

- (void *)controlStreamContext {
    return &_connectionContext.controlContext;
}

- (BOOL)isClipboardControlReady {
    [self ensureControlContextBacklink];
    PML_CONTROL_STREAM_CONTEXT ctx = &_connectionContext.controlContext;
    if (ctx->stopping || ctx->connectionContext == NULL || ctx->packetTypes == NULL) {
        return NO;
    }

    if (APP_VERSION_AT_LEAST_CTX(ctx->connectionContext, 5, 0, 0)) {
        if (ctx->client == NULL || ctx->peer == NULL || ctx->peer->state != ENET_PEER_STATE_CONNECTED) {
            return NO;
        }
    }
    else if (ctx->ctlSock == INVALID_SOCKET) {
        return NO;
    }

    if (ctx->encryptedControlStream && ctx->encryptionCtx == NULL) {
        return NO;
    }

    return YES;
}

- (NSString *)clipboardControlReadinessReason {
    [self ensureControlContextBacklink];
    PML_CONTROL_STREAM_CONTEXT ctx = &_connectionContext.controlContext;
    if (ctx->stopping) {
        return [NSString stringWithFormat:@"control-stopping-stage-%d", _connectionContext.stage];
    }
    if (ctx->connectionContext == NULL) {
        return [NSString stringWithFormat:@"missing-connection-context-stage-%d", _connectionContext.stage];
    }
    if (ctx->packetTypes == NULL) {
        return [NSString stringWithFormat:@"missing-packet-types-stage-%d", _connectionContext.stage];
    }

    if (APP_VERSION_AT_LEAST_CTX(ctx->connectionContext, 5, 0, 0)) {
        if (ctx->client == NULL) {
            return [NSString stringWithFormat:@"missing-enet-client-stage-%d", _connectionContext.stage];
        }
        if (ctx->peer == NULL) {
            return [NSString stringWithFormat:@"missing-enet-peer-stage-%d", _connectionContext.stage];
        }
        if (ctx->peer->state != ENET_PEER_STATE_CONNECTED) {
            return [NSString stringWithFormat:@"enet-peer-state-%u-stage-%d",
                    (unsigned int)ctx->peer->state,
                    _connectionContext.stage];
        }
    }
    else if (ctx->ctlSock == INVALID_SOCKET) {
        return [NSString stringWithFormat:@"invalid-tcp-control-socket-stage-%d", _connectionContext.stage];
    }

    if (ctx->encryptedControlStream && ctx->encryptionCtx == NULL) {
        return [NSString stringWithFormat:@"missing-control-encryption-context-stage-%d", _connectionContext.stage];
    }

    return [NSString stringWithFormat:@"ready-stage-%d", _connectionContext.stage];
}

- (uint32_t)clipboardHostFeatureFlags {
    [self ensureControlContextBacklink];
    return LiGetHostFeatureFlagsCtx(&_connectionContext);
}

- (NSString *)clipboardControlDebugSummary {
    [self ensureControlContextBacklink];
    PML_CONTROL_STREAM_CONTEXT ctx = &_connectionContext.controlContext;
    unsigned int peerState = ctx->peer != NULL ? (unsigned int)ctx->peer->state : 0;
    return [NSString stringWithFormat:@"conn=%p connCtx=%p ctrlCtx=%p stage=%d packetTypes=%p client=%p peer=%p peerState=%u encrypted=%d encCtx=%p ctlSock=%d hostFlags=0x%08x",
            self,
            &_connectionContext,
            ctx,
            _connectionContext.stage,
            ctx->packetTypes,
            ctx->client,
            ctx->peer,
            peerState,
            ctx->encryptedControlStream ? 1 : 0,
            ctx->encryptionCtx,
            (int)ctx->ctlSock,
            [self clipboardHostFeatureFlags]];
}

- (int)performClipboardControlOperationNamed:(NSString *)name
                                       block:(int (^)(void))block {
    if (block == nil) {
        return -1;
    }

    __block int result = -1;
    void (^operation)(void) = ^{
        [self ensureControlContextBacklink];
        LiSetThreadConnectionContext(&_connectionContext);
        os_unfair_lock_lock(&gConnectionLifecycleLock);
        result = block();
        os_unfair_lock_unlock(&gConnectionLifecycleLock);
        Log(LOG_I, @"[clipboard] %@ result=%d summary=%@",
            name ?: @"operation",
            result,
            [self clipboardControlDebugSummary]);
    };

    if (dispatch_get_specific(gClipboardQueueKey) == gClipboardQueueKey) {
        operation();
    } else {
        dispatch_sync(_clipboardControlQueue, operation);
    }

    return result;
}

- (int)bindClipboardSession {
    Log(LOG_I, @"[clipboard] bind request conn=%p connCtx=%p ctrlCtx=%p",
        self,
        &_connectionContext,
        &_connectionContext.controlContext);
    return [self performClipboardControlOperationNamed:@"bind"
                                                 block:^int {
        return LiBindClipboardSession();
    }];
}

- (int)unbindClipboardSession {
    Log(LOG_I, @"[clipboard] unbind request conn=%p connCtx=%p ctrlCtx=%p",
        self,
        &_connectionContext,
        &_connectionContext.controlContext);
    return [self performClipboardControlOperationNamed:@"unbind"
                                                 block:^int {
        return LiUnbindClipboardSession();
    }];
}

- (int)requestClipboardSnapshot {
    Log(LOG_I, @"[clipboard] snapshot request conn=%p connCtx=%p ctrlCtx=%p",
        self,
        &_connectionContext,
        &_connectionContext.controlContext);
    return [self performClipboardControlOperationNamed:@"snapshot"
                                                 block:^int {
        return LiRequestClipboardSnapshot();
    }];
}

- (int)sendClipboardItemData:(NSData *)data
                        type:(uint8_t)type
                    mimeType:(NSString *)mimeType
                        name:(NSString *)name
                      itemId:(uint64_t)itemId
                 contentHash:(uint64_t)contentHash {
    LI_CLIPBOARD_ITEM item;
    memset(&item, 0, sizeof(item));

    item.type = type;
    item.data = data.bytes;
    item.length = (uint32_t)data.length;
    item.mimeType = mimeType.length > 0 ? mimeType.UTF8String : NULL;
    item.name = name.length > 0 ? name.UTF8String : NULL;
    item.itemId = itemId;
    item.contentHash = contentHash;

    Log(LOG_I, @"[clipboard] send item request conn=%p connCtx=%p ctrlCtx=%p type=%u length=%u itemId=%llu",
        self,
        &_connectionContext,
        &_connectionContext.controlContext,
        item.type,
        item.length,
        item.itemId);
    return [self performClipboardControlOperationNamed:@"send-item"
                                                 block:^int {
        return LiSendClipboardItem(&item);
    }];
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

    AVAuthorizationStatus authStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (authStatus != AVAuthorizationStatusAuthorized) {
        Log(LOG_I, @"Microphone start skipped because permission is not authorized: status=%ld",
            (long)authStatus);
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_micStopping || !self->_streamConfig.enableMic) {
            Log(LOG_I, @"Microphone start skipped because capture is stopping");
            return;
        }
        [self startMicrophoneEngineLocked];
    });
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
    if (_micStopping || !_streamConfig.enableMic) {
        return;
    }

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

    dispatch_block_t teardownBlock = ^{
        self->_micSendFailures = 0;
        if (self->_micEncoder != NULL) {
            opus_multistream_encoder_destroy(self->_micEncoder);
            self->_micEncoder = NULL;
        }
        [self->_micPcmQueue setLength:0];
    };
    if (_micQueue != nil) {
        if (dispatch_get_specific(gMicQueueKey) == gMicQueueKey) {
            teardownBlock();
        } else {
            dispatch_sync(_micQueue, teardownBlock);
        }
    } else {
        teardownBlock();
    }

    destroyMicrophoneStreamCtx(&_connectionContext.micContext);
}
#endif

#if !defined(LI_MIC_CONTROL_START)
- (void)notifyInputStreamReadyForMicrophoneControlIfNeeded
{
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
    UInt32 frames = (conn->_channelCount > 0) ? (bytesPerBuffer / (UInt32)(conn->_channelCount * sizeof(short))) : 0;
    [conn copyPCMFrames:frames toInterleavedBuffer:(short *)inBuffer->mAudioData];
    
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
