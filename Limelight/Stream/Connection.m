//
//  Connection.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/19/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "Connection.h"
#import "Ds5HapticsAudioRenderer.h"
#import "MLAudioBitstreamOutput.h"
#import "Logger.h"
#import "Utils.h"

#import "MoonlightEnhanced-Swift.h"

#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <CoreAudio/CoreAudio.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#if TARGET_OS_OSX
@import AppKit;
#endif
#import <os/lock.h>

#import <arpa/inet.h>
#include <netinet/in.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <stddef.h>

#include "Limelight.h"
#include "Limelight-internal.h"
#include "DynamicHdr.h"
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

// Audio codec ids, identical to AUDIO_CODEC_* in moonlight-common-c.
enum {
    MLAudioCodecOpus = 0,
    MLAudioCodecAc3 = 1,
    MLAudioCodecEac3 = 2,
    MLAudioCodecPcm = 3,
};

// Receive state machine of the PCM / AC3 / E-AC3 paths (audio decode thread only).
enum {
    MLAudioRxStateAwaitingFirstPacket = 0, // nothing validated yet
    MLAudioRxStateStreaming = 1,           // the first packet matched the negotiated codec
    MLAudioRxStateMuted = 2,               // the host does not deliver the codec; nothing is rendered
};
// Consecutive invalid packets, after the stream was validated, that are reported
// to the user (250 ms of damaged audio for 5 ms PCM packets).
#define ML_AUDIO_RX_LATE_INVALID_BURST 50
#define ML_AUDIO_RX_STATS_INTERVAL_MS 10000
// Pause bursts per report interval that are still unremarkable for passthrough.
#define ML_AUDIO_PASSTHROUGH_REPORT_PAUSES 4
// Frames in a row the bitstream output may reject before the session decodes locally.
#define ML_AUDIO_PASSTHROUGH_MAX_CONSECUTIVE_REJECTS 10

static void MLAudioRxReportStats(Connection *conn, uint64_t nowMs, BOOL force);

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
            // PQ is the interoperable HDR default for game-streaming hosts;
            // HLG remains an explicit user preference.
            return DYNAMIC_RANGE_MODE_HDR10_PQ;
    }
}

BOOL MLAppleDolbyVisionDirectSurfaceAvailable(unsigned int targetDisplayID) {
#if TARGET_OS_OSX
    if (@available(macOS 15.0, *)) {
        if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_DolbyVisionHEVC) ||
            ![AVPlayer eligibleForHDRPlayback]) {
            return NO;
        }
        // Judge the display that shows the stream window, not whichever screen
        // happens to hold the menu bar.
        NSScreen *screen = nil;
        if (targetDisplayID != 0) {
            for (NSScreen *candidate in NSScreen.screens) {
                NSNumber *number = candidate.deviceDescription[@"NSScreenNumber"];
                if (number != nil && number.unsignedIntValue == targetDisplayID) {
                    screen = candidate;
                    break;
                }
            }
        }
        screen = screen ?: NSScreen.mainScreen ?: NSScreen.screens.firstObject;
        return screen != nil &&
            screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0;
    }
#endif
    return NO;
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
    // AC3 / E-AC3 sent untouched to the output device (MLAudioBitstreamOutput).
    MLAudioRendererBackendBitstream = 3,
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
- (OSStatus)initializeLegacyAudioQueueRendererWithOpusConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig
                                               channelLayout:(const AudioChannelLayout *)channelLayout;
- (void)prepareAudioOutputQueue;
- (void)beginAudioOutputStartWithOpusConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig
                              channelLayout:(const AudioChannelLayout *)channelLayout;
- (void)shutdownAudioOutput;
- (BOOL)audioOutputAttemptCancelled;
- (void)discardBufferedAudio;
- (UInt32)bufferedRingFrames;
- (NSString *)audioPassthroughRejectionReason;
- (BOOL)startAudioPassthroughOnOutputQueue;
- (void)stopAudioPassthroughOnOutputQueue;
- (void)audioPassthroughLostWithDetail:(NSString *)detail generation:(int32_t)generation;
- (void)requestAudioPassthroughFallbackWithDetail:(NSString *)detail;
- (void)noteAudioCodecProblemWithNoticeKey:(NSString *)noticeKey markUnsupported:(BOOL)markUnsupported;
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
    BOOL _foundationHost;
    BOOL _wantsRemoteTextContext;

    VideoDecoderRenderer *_renderer;
    id<ConnectionCallbacks> _callbacks;

    OpusMSDecoder *_opusDecoder;
    // Audio codec of this session. Planned in -initWithConfig:, confirmed against
    // the library's negotiated value in ArInit.
    int _audioCodec;
    MLAudioStreamPlan *_audioPlan;
    NSString *_audioHostKey;
    BOOL _continuousAudio;
    int _audioRequestedCodec;
    int32_t _audioNoticeSent;
    // Packet validation counters of the non-Opus paths, touched by the audio decode thread only.
    int _pcmExpectedBytes;
    int _audioRxState;
    uint64_t _audioRxValidPackets;
    uint64_t _audioRxInvalidPackets;
    uint64_t _audioRxLossPlaceholders;
    uint64_t _audioRxConsecutiveInvalid;
    uint64_t _audioRxReportedValid;
    uint64_t _audioRxReportedInvalid;
    uint64_t _audioRxReportedLoss;
    uint64_t _audioRxLastReportMs;
    // AC3 / E-AC3: AudioToolbox decoder plus a FIFO that turns whatever the
    // decoder returns into whole ring entries (decode thread only).
    AudioConverterRef _compressedConverter;
    short *_compressedFifo;
    short *_compressedScratch;
    int _compressedFifoFrames;
    int _compressedFifoCapacityFrames;
    uint64_t _compressedDecodedFrames;
    uint64_t _compressedConsecutiveErrors;
    uint64_t _compressedFifoOverflows;
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
    // Ring health for the periodic [audio] ring line. Full-ring drops are counted by the
    // decode thread, the largest pull by the enhanced render callback (never reset: it
    // also sizes the start-up buffering). All plain statistics; torn reads are harmless.
    uint64_t _audioRingFullDrops;
    uint64_t _audioRingReportedDrops;
    uint64_t _audioRingReportedUnderruns;
    UInt32 _audioMaxPullFrames;
    uint64_t _enhancedRebufferCount;
    uint64_t _audioRingReportedRebuffers;
    // Enhanced render thread only: YES while output is held back to build a buffer.
    BOOL _enhancedHoldingForBuffer;
    // Written by the audio decode thread, read by the render callback.
    uint64_t _lastAudioSampleMs;
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

    // Output start and teardown. Starting an output device can block inside
    // CoreAudio for ~10 s and fail (HDMI/DisplayPort clocks stall while the
    // display reconfigures), so ArInit never starts it itself: it prepares the
    // decoder and ring and schedules the start on _audioOutputQueue. That serial
    // queue owns every output backend (_audioUnit, _audioQueue, the enhanced
    // engine) and the ring/scratch memory the render callbacks read, so starts
    // never overlap and teardown is ordered after any in-flight start.
    //  - _audioOutputGeneration is bumped by ArInit and ArCleanup (atomic). Every
    //    queued block carries the generation it was created for and does nothing
    //    when it is stale, which cancels pending retries and device-change
    //    triggers. A start that is already inside CoreAudio cannot be aborted;
    //    it is simply torn down by the cleanup block queued behind it.
    //  - ArCleanup waits (bounded) for that cleanup block: the ring may only be
    //    freed after the unit that reads it is stopped. If CoreAudio wedges past
    //    the bound, the block still frees everything later and ArCleanup returns
    //    without touching the ring, so there is no use-after-free either way.
    //  - Written and read on _audioOutputQueue only unless noted.
    dispatch_queue_t _audioOutputQueue;
    int32_t _audioOutputGeneration;       // atomic; any thread
    int32_t _audioAttemptGeneration;      // generation of the attempt in progress
    int32_t _audioOutputRetryToken;       // invalidates an earlier scheduled retry
    BOOL _audioOutputRunning;
    BOOL _audioOutputFailureNoticed;
    int _audioOutputStartAttempts;
    OSStatus _audioOutputStartStatus;     // last failure reported by a backend
    OPUS_MULTISTREAM_CONFIGURATION _audioOutputOpusConfig;
    AudioChannelLayout _audioOutputChannelLayout;
    AudioObjectPropertyListenerBlock _audioOutputListener; // set by ArInit, removed by ArCleanup

    // AC3 / E-AC3 bitstream passthrough: one more output backend, owned by
    // _audioOutputQueue like the others. The decode thread hands raw frames to
    // _bitstreamOutput instead of the AudioConverter while _audioPassthroughActive is set.
    //  - Lifetime: _bitstreamOutput is assigned on the output queue before it is
    //    published through _audioPassthroughEverStarted (release store; the decode
    //    thread loads with acquire), and reassigned only by -begin... (ArInit),
    //    which runs before the library starts the decode thread. -stop leaves the
    //    object alive, so the decode thread can never message a deallocated output:
    //    it either sees no output or one that stays valid until the next session.
    //    ArCleanup runs after the library has stopped the decode thread.
    //  - _audioPassthroughActive (atomic) is cleared on the output queue before the
    //    output is stopped; a frame that races with it is rejected by the output.
    //  - The converter, FIFO and ring are prepared in ArInit regardless, so falling
    //    back needs nothing new.
    MLAudioBitstreamOutput *_bitstreamOutput;
    int32_t _audioAnyPacketSeen;              // atomic; set by the decode thread on the first packet
    int32_t _audioPassthroughActive;          // atomic
    int32_t _audioPassthroughEverStarted;     // atomic
    int32_t _audioPassthroughFallbackRequested; // atomic; decode thread asks at most once
    BOOL _audioPassthroughGivenUp;            // output queue; for the rest of the session
    BOOL _audioLeftoverChecked;               // output queue
    uint64_t _audioPassthroughConsecutiveRejects; // decode thread
    MLAudioBitstreamStats _bitstreamReported;     // decode thread (and ArCleanup after it ended)

#if defined(LI_MIC_CONTROL_START)
    dispatch_queue_t _micQueue;
    OpusMSEncoder* _micEncoder;
    NSMutableData* _micPcmQueue;
    int _micSendFailures;
    BOOL _micStopping;
    BOOL _micEncryptionStatusLogged;
    uint64_t _micLastPingTimeMs;
    uint32_t _micPingCount;
#endif
    dispatch_queue_t _clipboardControlQueue;
    BOOL _connectionLayoutCompatible;
}

- (uint64_t)audioUnderrunCount {
    @synchronized (self) {
        return _audioUnderrunCount;
    }
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

// I/O buffer size in frames of the default output device, 0 when unknown. Logged once
// per start next to the size the render callback actually asks for.
static UInt32 MLDefaultOutputBufferFrames(void) {
    AudioDeviceID deviceID = kAudioObjectUnknown;
    UInt32 propertySize = sizeof(deviceID);
    AudioObjectPropertyAddress deviceAddress = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &deviceAddress, 0, NULL,
                                   &propertySize, &deviceID) != noErr || deviceID == kAudioObjectUnknown) {
        return 0;
    }

    UInt32 frames = 0;
    propertySize = sizeof(frames);
    AudioObjectPropertyAddress sizeAddress = {
        kAudioDevicePropertyBufferFrameSize,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(deviceID, &sizeAddress, 0, NULL, &propertySize, &frames) != noErr) {
        return 0;
    }
    return frames;
}

// The device clock did not start ('stop'). Every further backend in the same
// attempt would wait out the same ~10 s timeout and fail identically.
static BOOL MLAudioStatusIsDeviceNotRunning(OSStatus status) {
    return status == kAudioHardwareNotRunningError;
}

// Renders an OSStatus that is a four-character code as 'abcd'; "n/a" otherwise.
static NSString *MLAudioStatusFourCC(OSStatus status) {
    char code[4] = {
        (char)((status >> 24) & 0xFF), (char)((status >> 16) & 0xFF),
        (char)((status >> 8) & 0xFF), (char)(status & 0xFF)
    };
    for (int i = 0; i < 4; i++) {
        if (code[i] < 0x20 || code[i] > 0x7E) {
            return @"n/a";
        }
    }
    return [NSString stringWithFormat:@"'%c%c%c%c'", code[0], code[1], code[2], code[3]];
}

static NSString *MLAudioRendererBackendName(MLAudioRendererBackend backend) {
    switch (backend) {
        case MLAudioRendererBackendDirect:
            return @"direct";
        case MLAudioRendererBackendEnhanced:
            return @"enhanced";
        case MLAudioRendererBackendBitstream:
            return @"bitstream-passthrough";
        case MLAudioRendererBackendLegacyQueue:
        default:
            return @"legacy-queue";
    }
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
    renderer.directSubmission = (conn->_drCallbacks.capabilities & CAPABILITY_DIRECT_SUBMIT) != 0;
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

    // Must precede the buffer allocations below: it waits for a teardown of an
    // earlier run that may still be queued and would free what is allocated here.
    [conn prepareAudioOutputQueue];

    // The library may have downgraded the request (not Sunshine, too many
    // channels). What it negotiated is what it puts into the SDP, so it wins.
    int negotiatedCodec = MLAudioCodecOpus;
#if defined(AUDIO_CODEC_PCM_S16)
    negotiatedCodec = LiGetNegotiatedAudioCodec();
#endif
    if (negotiatedCodec != conn->_audioCodec) {
        Log(LOG_W, @"[audio] Library negotiated codec %d but the client planned %d; following the library",
            negotiatedCodec, conn->_audioCodec);
        conn->_audioCodec = negotiatedCodec;
    }
    const BOOL usePcm = conn->_audioCodec == MLAudioCodecPcm;
    const BOOL useCompressed = conn->_audioCodec == MLAudioCodecAc3 || conn->_audioCodec == MLAudioCodecEac3;
    conn->_pcmExpectedBytes = 0;
    conn->_audioRxState = MLAudioRxStateAwaitingFirstPacket;
    conn->_audioRxValidPackets = conn->_audioRxInvalidPackets = conn->_audioRxLossPlaceholders = 0;
    conn->_audioRxConsecutiveInvalid = 0;
    conn->_audioRxReportedValid = conn->_audioRxReportedInvalid = conn->_audioRxReportedLoss = 0;
    conn->_audioRxLastReportMs = 0;
    conn->_compressedFifoFrames = 0;
    conn->_compressedDecodedFrames = 0;
    conn->_compressedConsecutiveErrors = 0;
    conn->_compressedFifoOverflows = 0;
    conn->_audioRingFullDrops = conn->_audioRingReportedDrops = conn->_audioRingReportedUnderruns = 0;
    conn->_audioMaxPullFrames = 0;
    conn->_enhancedRebufferCount = conn->_audioRingReportedRebuffers = 0;
    conn->_enhancedHoldingForBuffer = YES;
    
    // Initialize the circular buffer
    conn->_audioBufferWriteIndex = conn->_audioBufferReadIndex = 0;
    conn->_audioBufferReadFrameOffset = 0;
    conn->_audioSamplesPerFrame = opusConfig.samplesPerFrame;
    conn->_audioBufferStride = opusConfig.channelCount * opusConfig.samplesPerFrame;
    int frameDurationMs = MAX(1, (int)(opusConfig.samplesPerFrame / (opusConfig.sampleRate / 1000)));
    int targetBufferDurationMs = MLAudioRingBufferDurationForMode((MLAudioOutputMode)conn->_audioOutputMode);
    int bufferedFramesTarget = MAX(1, (targetBufferDurationMs + frameDurationMs - 1) / frameDurationMs);
    if (frameDurationMs >= 20) {
        // AC3 / E-AC3 frames are 32 ms long: keep at least three of them in flight so a
        // late packet does not run the output dry.
        bufferedFramesTarget = MAX(bufferedFramesTarget, 3);
    }
    if (conn->_audioOutputMode == MLAudioOutputModeEnhanced) {
        // The enhanced engine pulls up to AUDIO_RENDER_SCRATCH_FRAMES per render call and
        // was logged calling twice back to back (4096 frames per ~85 ms) on a DisplayPort
        // output. A ring that holds less than one such burst plus margin overflows between
        // the bursts (the newest packets are dropped) and runs dry inside them, so about a
        // third of the audio was replaced by silence in 25 ms pieces. Size it for a burst
        // measured in whole entries, plus one entry for the partly read one.
        const int burstFrames = 2 * AUDIO_RENDER_SCRATCH_FRAMES + 1024;
        const int burstEntries = (burstFrames + opusConfig.samplesPerFrame - 1) / opusConfig.samplesPerFrame + 1;
        bufferedFramesTarget = MAX(bufferedFramesTarget, burstEntries);
    }
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
    
    if (usePcm) {
        // Raw s16le PCM needs no decoder: every packet is exactly one ring entry.
        conn->_opusDecoder = NULL;
        conn->_pcmExpectedBytes = opusConfig.samplesPerFrame * opusConfig.channelCount * (int)sizeof(short);
        if (conn->_pcmExpectedBytes != conn->_audioBufferStride * (int)sizeof(short)) {
            Log(LOG_E, @"[audio] PCM packet size %d does not match the ring entry size %d",
                conn->_pcmExpectedBytes, conn->_audioBufferStride * (int)sizeof(short));
            free(conn->_audioCircularBuffer);
            conn->_audioCircularBuffer = NULL;
            return -1;
        }
    } else if (useCompressed) {
        // AC3 / E-AC3 are decoded by AudioToolbox; the decoder is created below.
        conn->_opusDecoder = NULL;
    } else {
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
    }
    conn->_audioRenderScratchBuffer = calloc(AUDIO_RENDER_SCRATCH_FRAMES * conn->_channelCount, sizeof(short));
    if (conn->_audioRenderScratchBuffer == NULL) {
        Log(LOG_E, @"Failed to allocate audio render scratch buffer\n");
        if (conn->_opusDecoder != NULL) {
            opus_multistream_decoder_destroy(conn->_opusDecoder);
            conn->_opusDecoder = NULL;
        }
        free(conn->_audioCircularBuffer);
        conn->_audioCircularBuffer = NULL;
        return -1;
    }
    if (useCompressed) {
        const int fifoFrames = opusConfig.samplesPerFrame * 3;
        conn->_compressedFifoCapacityFrames = fifoFrames;
        conn->_compressedFifo = calloc((size_t)fifoFrames * opusConfig.channelCount, sizeof(short));
        conn->_compressedScratch = calloc((size_t)opusConfig.samplesPerFrame * opusConfig.channelCount, sizeof(short));
        OSStatus converterStatus = -1;
        if (conn->_compressedFifo != NULL && conn->_compressedScratch != NULL) {
            converterStatus = MLCreateCompressedAudioConverter(conn->_audioCodec, opusConfig.channelCount,
                                                               &channelLayout, &conn->_compressedConverter);
        }
        if (converterStatus != noErr || conn->_compressedConverter == NULL) {
            // Not fatal for the stream: the user gets silence and a notice, and the
            // next session uses Opus.
            conn->_compressedConverter = NULL;
            conn->_audioRxState = MLAudioRxStateMuted;
            Log(LOG_E, @"[audio] Could not create the %@ decoder (status %d); audio is muted for this session",
                [MLAudioStreamPlan codecName:conn->_audioCodec], (int)converterStatus);
            [conn noteAudioCodecProblemWithNoticeKey:@"The %@ decoder failed. Audio is muted; Opus will be used next time."
                                     markUnsupported:YES];
        } else {
            UInt32 layoutSize = (UInt32)sizeof(AudioChannelLayout);
            AudioChannelLayout reported = {};
            OSStatus layoutStatus = AudioConverterGetProperty(conn->_compressedConverter,
                                                              kAudioConverterOutputChannelLayout,
                                                              &layoutSize, &reported);
            Log(LOG_I, @"[audio] %@ decoder ready: channels=%d fifoFrames=%d outputLayoutStatus=%d outputLayoutTag=0x%08X expectedLayoutTag=0x%08X",
                [MLAudioStreamPlan codecName:conn->_audioCodec], opusConfig.channelCount, fifoFrames,
                (int)layoutStatus, (unsigned int)reported.mChannelLayoutTag,
                (unsigned int)channelLayout.mChannelLayoutTag);
        }
    }
    conn->_audioDeviceChannelCount = MLDefaultOutputChannelCount();
    conn->_audioRenderChannelCount = conn->_channelCount;
    conn->_audioRendererBackend = MLAudioRendererBackendLegacyQueue;
    conn->_audioUnderrunCount = 0;
    __atomic_store_n(&conn->_lastAudioSampleMs, 0, __ATOMIC_RELAXED);
    conn->_audioDecodeThreadPriorityRaised = NO;
    conn->_audioDecodeSampleCount = 0;
    conn->_audioDecodeFailureCount = 0;
    conn->_audioConsecutiveDecodeFailures = 0;
    conn->_audioFallbackDecodeSuccessCount = 0;
    conn->_audioPrimaryReprobeAttempted = preferCompatibility714Topology;

    {
        NSString *passthroughRejection = [conn audioPassthroughRejectionReason];
        MLAudioStreamPlan *plan = conn->_audioPlan;
        int packetMs = MAX(1, opusConfig.samplesPerFrame / MAX(1, opusConfig.sampleRate / 1000));
        Log(LOG_I, @"[audio] Stream start: codec requested=%@ effective=%@ negotiated=%@ channels=%d packetMs=%d samplesPerFrame=%d expectedPacketBytes=%d wireKbps=%d payloadKbps=%d continuousAudio=%d fallback=%@ passthrough=%@",
            plan != nil ? plan.requestedCodecName : @"opus",
            plan != nil ? plan.effectiveCodecName : @"opus",
            [MLAudioStreamPlan codecName:conn->_audioCodec],
            opusConfig.channelCount,
            packetMs,
            opusConfig.samplesPerFrame,
            conn->_pcmExpectedBytes,
            plan != nil ? (int)plan.wireKbps : 0,
            plan != nil ? (int)plan.payloadKbps : 0,
            conn->_continuousAudio ? 1 : 0,
            plan != nil ? plan.fallbackLogText : @"none",
            passthroughRejection == nil ? @"planned" : [NSString stringWithFormat:@"no(%@)", passthroughRejection]);
    }

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

    // Starting the output can block for ~10 s per backend when the device clock
    // does not run, and a stream without sound is better than no stream, so the
    // start happens in the background and ArInit succeeds regardless of it.
    [conn beginAudioOutputStartWithOpusConfig:&opusConfig channelLayout:&channelLayout];
    return 0;
}

void ArCleanup(void)
{
    Connection *conn = CurrentConnection();
    if (conn == nil) {
        return;
    }

    // Stops the output (cancelling a start that is pending or in flight) and frees
    // the ring and render scratch buffer, which the render callbacks read.
    [conn shutdownAudioOutput];

    if (conn->_audioCodec != MLAudioCodecOpus) {
        MLAudioRxReportStats(conn, LiGetMillis(), YES);
    }
    if (conn->_compressedConverter != NULL) {
        AudioConverterDispose(conn->_compressedConverter);
        conn->_compressedConverter = NULL;
    }
    if (conn->_compressedFifo != NULL) {
        free(conn->_compressedFifo);
        conn->_compressedFifo = NULL;
    }
    if (conn->_compressedScratch != NULL) {
        free(conn->_compressedScratch);
        conn->_compressedScratch = NULL;
    }
    conn->_compressedFifoFrames = 0;

    if (conn->_opusDecoder != NULL) {
        opus_multistream_decoder_destroy(conn->_opusDecoder);
        conn->_opusDecoder = NULL;
    }

    // The ring and scratch buffer are freed by -shutdownAudioOutput, after the
    // output that reads them has been stopped.

#if TARGET_OS_IPHONE
    // Audio session is now inactive
    [[AVAudioSession sharedInstance] setActive: NO error: nil];
#endif
}

// Scales interleaved samples in place. Decode thread only.
static void MLApplyAudioVolume(short *samples, int count, float volume)
{
    if (volume == 1.0f) {
        return;
    }
    for (int i = 0; i < count; i++) {
        float scaled = (float)samples[i] * volume;
        if (scaled > 32767.0f) scaled = 32767.0f;
        if (scaled < -32768.0f) scaled = -32768.0f;
        samples[i] = (short)scaled;
    }
}

// Reports validation counters of the non-Opus paths. Decode thread only; silent while nothing went
// wrong, and at most one line per ML_AUDIO_RX_STATS_INTERVAL_MS unless forced.
static void MLAudioRxReportStats(Connection *conn, uint64_t nowMs, BOOL force)
{
    if (!force && nowMs - conn->_audioRxLastReportMs < ML_AUDIO_RX_STATS_INTERVAL_MS) {
        return;
    }
    uint64_t invalid = conn->_audioRxInvalidPackets - conn->_audioRxReportedInvalid;
    uint64_t loss = conn->_audioRxLossPlaceholders - conn->_audioRxReportedLoss;
    uint64_t valid = conn->_audioRxValidPackets - conn->_audioRxReportedValid;
    if (invalid > 0 || loss > 0) {
        Log(LOG_W, @"[audio] %@ packets since last report: valid=%llu invalid=%llu lossPlaceholders=%llu fifoOverflows=%llu (session totals valid=%llu invalid=%llu lossPlaceholders=%llu)",
            [MLAudioStreamPlan codecName:conn->_audioCodec],
            (unsigned long long)valid,
            (unsigned long long)invalid,
            (unsigned long long)loss,
            (unsigned long long)conn->_compressedFifoOverflows,
            (unsigned long long)conn->_audioRxValidPackets,
            (unsigned long long)conn->_audioRxInvalidPackets,
            (unsigned long long)conn->_audioRxLossPlaceholders);
    }
    conn->_audioRxReportedInvalid = conn->_audioRxInvalidPackets;
    conn->_audioRxReportedLoss = conn->_audioRxLossPlaceholders;
    conn->_audioRxReportedValid = conn->_audioRxValidPackets;
    conn->_audioRxLastReportMs = nowMs;

    // Ring health. The ring is only used when the stream is decoded on this Mac; a line
    // appears when the output side starved or the decode side found the ring full, so a
    // clean session stays silent. fullDrops with underruns in the same interval means the
    // output pulls in bigger pieces than the ring holds (maxPull is the largest request
    // the render callback saw), not that the network lost anything.
    if (__atomic_load_n(&conn->_audioPassthroughActive, __ATOMIC_ACQUIRE) == 0) {
        const uint64_t ringDrops = conn->_audioRingFullDrops - conn->_audioRingReportedDrops;
        const uint64_t underruns = conn->_audioUnderrunCount - conn->_audioRingReportedUnderruns;
        conn->_audioRingReportedDrops = conn->_audioRingFullDrops;
        conn->_audioRingReportedUnderruns = conn->_audioUnderrunCount;
        const uint64_t rebuffers = conn->_enhancedRebufferCount - conn->_audioRingReportedRebuffers;
        conn->_audioRingReportedRebuffers = conn->_enhancedRebufferCount;
        if (ringDrops > 0 || underruns > 0 || rebuffers > 0) {
            Log(LOG_W, @"[audio] ring since last report: fullDrops=%llu underruns=%llu rebuffers=%llu maxPull=%u frames ring=%d entries x %d frames backend=%@ (session totals fullDrops=%llu underruns=%llu)",
                (unsigned long long)ringDrops,
                (unsigned long long)underruns,
                (unsigned long long)rebuffers,
                (unsigned int)conn->_audioMaxPullFrames,
                conn->_audioBufferEntries,
                conn->_audioSamplesPerFrame,
                MLAudioRendererBackendName(conn->_audioRendererBackend),
                (unsigned long long)conn->_audioRingFullDrops,
                (unsigned long long)conn->_audioUnderrunCount);
        }
    }

    // Passthrough burst counters. A few pause bursts are normal (the prefill at
    // start, a jitter spike), so only more than that, drops or rejected frames
    // make a line.
    if (__atomic_load_n(&conn->_audioPassthroughEverStarted, __ATOMIC_ACQUIRE) != 0) {
        const MLAudioBitstreamStats total = [conn->_bitstreamOutput stats];
        const MLAudioBitstreamStats last = conn->_bitstreamReported;
        const uint64_t pauses = total.pauseBursts - last.pauseBursts;
        const uint64_t dropped = total.droppedBursts - last.droppedBursts;
        const uint64_t rejected = total.invalidFrames - last.invalidFrames;
        if (pauses > ML_AUDIO_PASSTHROUGH_REPORT_PAUSES || dropped > 0 || rejected > 0) {
            Log(LOG_W, @"[audio] Passthrough bursts since last report: enqueued=%llu played=%llu pause=%llu dropped=%llu invalid=%llu queued=%u (session totals enqueued=%llu played=%llu pause=%llu dropped=%llu invalid=%llu)%@",
                (unsigned long long)(total.burstsEnqueued - last.burstsEnqueued),
                (unsigned long long)(total.burstsPlayed - last.burstsPlayed),
                (unsigned long long)pauses,
                (unsigned long long)dropped,
                (unsigned long long)rejected,
                total.queuedBursts,
                (unsigned long long)total.burstsEnqueued,
                (unsigned long long)total.burstsPlayed,
                (unsigned long long)total.pauseBursts,
                (unsigned long long)total.droppedBursts,
                (unsigned long long)total.invalidFrames,
                rejected > 0 ? [NSString stringWithFormat:@" lastInvalid=%@", [conn->_bitstreamOutput lastInvalidReason]] : @"");
        }
        conn->_bitstreamReported = total;
    }
}

// Handles one packet of a PCM session on the audio decode thread. Only packets of
// exactly samplesPerFrame * channels * 2 bytes are ever copied into the ring;
// everything else becomes silence (or nothing), never raw bytes.
//
// - (NULL, 0) is the library's placeholder for a packet it could not recover: one
//   frame of silence keeps the timeline continuous.
// - If the very first packet has the wrong size, the host is not sending PCM (it
//   ignores the codec attribute and sends Opus). The session is muted for good.
// - After the first valid packet a wrong size is damage, not a codec mismatch: the
//   packet is replaced by one frame of silence and counted. A burst of
//   ML_AUDIO_RX_LATE_INVALID_BURST consecutive bad packets is reported once to the
//   user; audio resumes by itself as soon as valid packets arrive again.
static void MLPcmHandleSample(Connection *conn, const char *sampleData, int sampleLength)
{
    const uint64_t nowMs = LiGetMillis();
    const BOOL isPlaceholder = (sampleData == NULL || sampleLength == 0);

    if (conn->_audioRxState == MLAudioRxStateMuted) {
        if (isPlaceholder) {
            conn->_audioRxLossPlaceholders++;
        } else {
            conn->_audioRxInvalidPackets++;
        }
        MLAudioRxReportStats(conn, nowMs, NO);
        return;
    }

    short *entry = &conn->_audioCircularBuffer[conn->_audioBufferWriteIndex * conn->_audioBufferStride];
    const size_t entryBytes = (size_t)conn->_audioBufferStride * sizeof(short);

    if (isPlaceholder) {
        conn->_audioRxLossPlaceholders++;
        memset(entry, 0, entryBytes);
    } else if (sampleLength == conn->_pcmExpectedBytes) {
        memcpy(entry, sampleData, entryBytes);
        conn->_audioRxValidPackets++;
        conn->_audioRxConsecutiveInvalid = 0;
        if (conn->_audioRxState == MLAudioRxStateAwaitingFirstPacket) {
            conn->_audioRxState = MLAudioRxStateStreaming;
            Log(LOG_I, @"[audio] First PCM packet validated: bytes=%d channels=%d samplesPerFrame=%d",
                sampleLength, conn->_channelCount, conn->_audioSamplesPerFrame);
        }
        MLApplyAudioVolume(entry, conn->_audioBufferStride, conn->_audioVolumeMultiplier);
    } else {
        conn->_audioRxInvalidPackets++;
        conn->_audioRxConsecutiveInvalid++;
        if (conn->_audioRxState == MLAudioRxStateAwaitingFirstPacket) {
            conn->_audioRxState = MLAudioRxStateMuted;
            Log(LOG_E, @"[audio] First audio packet has %d bytes, PCM needs exactly %d: the host is not sending PCM. Audio is muted for this session and the host is remembered as not supporting PCM",
                sampleLength, conn->_pcmExpectedBytes);
            [conn noteAudioCodecProblemWithNoticeKey:@"The host did not send %@ audio. Audio is muted; Opus will be used next time."
                                     markUnsupported:YES];
            MLAudioRxReportStats(conn, nowMs, NO);
            return;
        }
        memset(entry, 0, entryBytes);
        if (conn->_audioRxConsecutiveInvalid == ML_AUDIO_RX_LATE_INVALID_BURST) {
            Log(LOG_E, @"[audio] %d consecutive PCM packets with the wrong size (expected %d, last %d). Audio stays silent until valid packets resume",
                ML_AUDIO_RX_LATE_INVALID_BURST, conn->_pcmExpectedBytes, sampleLength);
            [conn noteAudioCodecProblemWithNoticeKey:@"%@ audio is damaged. Audio is silent until it recovers."
                                     markUnsupported:NO];
        }
    }

    // Same ring discipline as the Opus path: write the entry, then publish it.
    __sync_synchronize();
    conn->_audioBufferWriteIndex = (conn->_audioBufferWriteIndex + 1) % conn->_audioBufferEntries;
    __atomic_store_n(&conn->_lastAudioSampleMs, nowMs, __ATOMIC_RELAXED);
    MLAudioRxReportStats(conn, nowMs, NO);
}

// ---- AC3 / E-AC3 -----------------------------------------------------------
//
// The host sends one raw AC3 / E-AC3 syncframe (1536 samples, 32 ms) per packet.
// AudioToolbox decodes it to 16-bit interleaved PCM, which goes into the same ring
// as every other codec, so all output backends keep working unchanged.
//
// An AudioConverter may return more or fewer frames than were fed (decoder
// priming), so decoded PCM first goes into a small FIFO and is moved into the
// ring in whole entries. Whatever goes wrong yields silence, never raw bytes.

// Input handed to the AudioConverter callback: exactly one compressed frame.
typedef struct {
    const uint8_t *data;
    UInt32 size;
    BOOL consumed;
    AudioStreamPacketDescription description;
} MLCompressedInput;

// Returned by the input callback when the frame was already consumed. A normal
// condition: the converter then hands back whatever PCM it has produced so far.
static const OSStatus kMLCompressedNeedMoreInput = -50505;
// AC3 frames are at most a few KB; anything bigger is not an AC3 frame.
#define ML_COMPRESSED_MAX_FRAME_BYTES 8192
// Consecutive converter errors before the decoder is given up for the session.
#define ML_COMPRESSED_MAX_CONSECUTIVE_ERRORS 10
// Valid frames after which a decoder that produced no PCM at all counts as failed.
#define ML_COMPRESSED_MAX_SILENT_FRAMES 16

static OSStatus MLCompressedInputProc(AudioConverterRef converter,
                                      UInt32 *ioNumberDataPackets,
                                      AudioBufferList *ioData,
                                      AudioStreamPacketDescription **outDataPacketDescription,
                                      void *inUserData)
{
    MLCompressedInput *input = (MLCompressedInput *)inUserData;
    if (input == NULL || input->consumed || input->size == 0) {
        *ioNumberDataPackets = 0;
        ioData->mNumberBuffers = 1;
        ioData->mBuffers[0].mNumberChannels = 0;
        ioData->mBuffers[0].mDataByteSize = 0;
        ioData->mBuffers[0].mData = NULL;
        if (outDataPacketDescription != NULL) {
            *outDataPacketDescription = NULL;
        }
        return kMLCompressedNeedMoreInput;
    }

    input->description.mStartOffset = 0;
    input->description.mVariableFramesInPacket = 0;
    input->description.mDataByteSize = input->size;

    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels = 0;
    ioData->mBuffers[0].mDataByteSize = input->size;
    ioData->mBuffers[0].mData = (void *)input->data;
    if (outDataPacketDescription != NULL) {
        *outDataPacketDescription = &input->description;
    }
    *ioNumberDataPackets = 1;
    input->consumed = YES;
    return noErr;
}

// Creates the AudioToolbox decoder for AC3 or E-AC3 with 16-bit interleaved output.
static OSStatus MLCreateCompressedAudioConverter(int codec, int channels, const AudioChannelLayout *outputLayout,
                                                 AudioConverterRef *outConverter)
{
    AudioStreamBasicDescription input = {0};
    input.mSampleRate = 48000.0;
    input.mFormatID = (codec == MLAudioCodecEac3) ? kAudioFormatEnhancedAC3 : kAudioFormatAC3;
    input.mChannelsPerFrame = (UInt32)channels;
    input.mFramesPerPacket = 1536;

    AudioStreamBasicDescription output = {0};
    output.mSampleRate = 48000.0;
    output.mFormatID = kAudioFormatLinearPCM;
    output.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    output.mBitsPerChannel = 16;
    output.mChannelsPerFrame = (UInt32)channels;
    output.mBytesPerFrame = output.mChannelsPerFrame * (UInt32)sizeof(short);
    output.mFramesPerPacket = 1;
    output.mBytesPerPacket = output.mBytesPerFrame;

    AudioConverterRef converter = NULL;
    OSStatus status = AudioConverterNew(&input, &output, &converter);
    if (status != noErr || converter == NULL) {
        return status != noErr ? status : -1;
    }

    // Ask for the channel order the ring uses (L R C LFE Ls Rs for 5.1). Stereo has no
    // ordering question. If the decoder refuses, keep its native order and say so.
    if (channels > 2 && outputLayout != NULL) {
        OSStatus layoutStatus = AudioConverterSetProperty(converter, kAudioConverterOutputChannelLayout,
                                                          (UInt32)sizeof(AudioChannelLayout), outputLayout);
        if (layoutStatus != noErr) {
            Log(LOG_W, @"[audio] %@ decoder did not accept the output channel layout (status %d); channel order may differ",
                [MLAudioStreamPlan codecName:codec], (int)layoutStatus);
        }
    }

    *outConverter = converter;
    return noErr;
}

// Appends frames of interleaved PCM to the FIFO; a FIFO that cannot take them is
// emptied first so the audio never lags behind by more than a few frames.
static void MLCompressedFifoAppend(Connection *conn, const short *samples, int frames)
{
    const int channels = conn->_channelCount;
    if (frames <= 0 || channels <= 0) {
        return;
    }
    if (conn->_compressedFifoFrames + frames > conn->_compressedFifoCapacityFrames) {
        conn->_compressedFifoFrames = 0;
        conn->_compressedFifoOverflows++;
        if (frames > conn->_compressedFifoCapacityFrames) {
            return;
        }
    }
    short *destination = conn->_compressedFifo + (size_t)conn->_compressedFifoFrames * channels;
    if (samples != NULL) {
        memcpy(destination, samples, (size_t)frames * channels * sizeof(short));
    } else {
        memset(destination, 0, (size_t)frames * channels * sizeof(short));
    }
    conn->_compressedFifoFrames += frames;
}

// Moves whole frames out of the FIFO into the ring while the ring has room.
static void MLCompressedFifoDrain(Connection *conn, uint64_t nowMs)
{
    const int frames = conn->_audioSamplesPerFrame;
    const int channels = conn->_channelCount;
    const size_t entrySamples = (size_t)frames * channels;
    while (conn->_compressedFifoFrames >= frames &&
           ((conn->_audioBufferWriteIndex + 1) % conn->_audioBufferEntries) != conn->_audioBufferReadIndex) {
        short *entry = &conn->_audioCircularBuffer[conn->_audioBufferWriteIndex * conn->_audioBufferStride];
        memcpy(entry, conn->_compressedFifo, entrySamples * sizeof(short));
        MLApplyAudioVolume(entry, conn->_audioBufferStride, conn->_audioVolumeMultiplier);

        conn->_compressedFifoFrames -= frames;
        if (conn->_compressedFifoFrames > 0) {
            memmove(conn->_compressedFifo, conn->_compressedFifo + entrySamples,
                    (size_t)conn->_compressedFifoFrames * channels * sizeof(short));
        }

        __sync_synchronize();
        conn->_audioBufferWriteIndex = (conn->_audioBufferWriteIndex + 1) % conn->_audioBufferEntries;
        __atomic_store_n(&conn->_lastAudioSampleMs, nowMs, __ATOMIC_RELAXED);
    }
}

// Gives up on the decoder for this session: silence from now on, the user is told
// once and the host is remembered as not delivering this codec.
static void MLCompressedFail(Connection *conn, NSString *reason)
{
    conn->_audioRxState = MLAudioRxStateMuted;
    Log(LOG_E, @"[audio] %@ decoding failed (%@). Audio is muted for this session and the host is remembered as not delivering this codec",
        [MLAudioStreamPlan codecName:conn->_audioCodec], reason);
    [conn noteAudioCodecProblemWithNoticeKey:@"The %@ decoder failed. Audio is muted; Opus will be used next time."
                             markUnsupported:YES];
}

// Passthrough: hands one validated frame to the bitstream output. Decode thread only.
// There is no mute flag in this class; volume 0 is mute, and not enqueueing
// makes the device play pause bursts. Any other volume cannot be applied to a
// bitstream and is ignored.
static void MLAudioPassthroughSubmit(Connection *conn, const uint8_t *bytes, int length)
{
    if (conn->_audioVolumeMultiplier <= 0.0f) {
        conn->_audioPassthroughConsecutiveRejects = 0;
        return;
    }
    MLAudioBitstreamOutput *output = conn->_bitstreamOutput;
    if (output == nil) {
        return;
    }
    if ([output enqueueFrame:bytes length:(size_t)length]) {
        conn->_audioPassthroughConsecutiveRejects = 0;
        return;
    }
    if (++conn->_audioPassthroughConsecutiveRejects == ML_AUDIO_PASSTHROUGH_MAX_CONSECUTIVE_REJECTS) {
        [conn requestAudioPassthroughFallbackWithDetail:
            [NSString stringWithFormat:@"the output rejected %d frames in a row (%@)",
             ML_AUDIO_PASSTHROUGH_MAX_CONSECUTIVE_REJECTS, [output lastInvalidReason]]];
    }
}

// Handles one packet of an AC3 / E-AC3 session on the audio decode thread.
//
// While passthrough is active (read once per packet) the validation, first-packet
// and muted-state logic and the counters are the same, but a valid frame goes to
// the bitstream output and the converter, FIFO and ring are left alone.
//
// - (NULL, 0) is a packet the library could not recover: one frame of silence.
// - Every frame must start with the AC-3 sync word 0x0B77 (E-AC3 uses it too). If
//   the very first packet does not, the host is not sending this codec (an Opus
//   stream starts differently): the session is muted and the host remembered.
//   Later invalid packets become one frame of silence each.
// - A converter error yields one frame of silence; repeated errors, or a decoder
//   that never produces PCM, end the decoding for the session (MLCompressedFail).
static void MLCompressedHandleSample(Connection *conn, const char *sampleData, int sampleLength)
{
    const uint64_t nowMs = LiGetMillis();
    const int frames = conn->_audioSamplesPerFrame;
    const BOOL isPlaceholder = (sampleData == NULL || sampleLength == 0);
    const BOOL passthrough = __atomic_load_n(&conn->_audioPassthroughActive, __ATOMIC_ACQUIRE) != 0;

    if (conn->_audioRxState == MLAudioRxStateMuted) {
        if (isPlaceholder) {
            conn->_audioRxLossPlaceholders++;
        } else {
            conn->_audioRxInvalidPackets++;
        }
        MLAudioRxReportStats(conn, nowMs, NO);
        return;
    }

    if (conn->_compressedConverter == NULL || conn->_compressedFifo == NULL || conn->_compressedScratch == NULL) {
        // The decoder could not be created in ArInit (already reported there).
        conn->_audioRxState = MLAudioRxStateMuted;
        return;
    }

    if (isPlaceholder) {
        // Passthrough: the device plays a pause burst when its queue runs dry.
        conn->_audioRxLossPlaceholders++;
        if (!passthrough) {
            MLCompressedFifoAppend(conn, NULL, frames);
        }
    } else {
        const uint8_t *bytes = (const uint8_t *)sampleData;
        const BOOL looksValid = sampleLength >= 8 && sampleLength <= ML_COMPRESSED_MAX_FRAME_BYTES &&
                                bytes[0] == 0x0B && bytes[1] == 0x77;
        if (!looksValid) {
            conn->_audioRxInvalidPackets++;
            conn->_audioRxConsecutiveInvalid++;
            if (conn->_audioRxState == MLAudioRxStateAwaitingFirstPacket) {
                conn->_audioRxState = MLAudioRxStateMuted;
                Log(LOG_E, @"[audio] First audio packet (%d bytes) is not an AC-3 frame: the host is not sending %@. Audio is muted for this session and the host is remembered as not supporting it",
                    sampleLength, [MLAudioStreamPlan codecName:conn->_audioCodec]);
                [conn noteAudioCodecProblemWithNoticeKey:@"The host did not send %@ audio. Audio is muted; Opus will be used next time."
                                         markUnsupported:YES];
                MLAudioRxReportStats(conn, nowMs, NO);
                return;
            }
            if (!passthrough) {
                MLCompressedFifoAppend(conn, NULL, frames);
            }
            if (conn->_audioRxConsecutiveInvalid == ML_AUDIO_RX_LATE_INVALID_BURST) {
                Log(LOG_E, @"[audio] %d consecutive packets are not valid %@ frames (last %d bytes). Audio stays silent until valid frames resume",
                    ML_AUDIO_RX_LATE_INVALID_BURST, [MLAudioStreamPlan codecName:conn->_audioCodec], sampleLength);
                [conn noteAudioCodecProblemWithNoticeKey:@"%@ audio is damaged. Audio is silent until it recovers."
                                         markUnsupported:NO];
            }
        } else {
            conn->_audioRxValidPackets++;
            conn->_audioRxConsecutiveInvalid = 0;
            if (conn->_audioRxState == MLAudioRxStateAwaitingFirstPacket) {
                conn->_audioRxState = MLAudioRxStateStreaming;
                Log(LOG_I, @"[audio] First %@ frame received: bytes=%d channels=%d samplesPerFrame=%d passthrough=%d",
                    [MLAudioStreamPlan codecName:conn->_audioCodec], sampleLength, conn->_channelCount, frames, passthrough ? 1 : 0);
            }

            if (passthrough) {
                MLAudioPassthroughSubmit(conn, bytes, sampleLength);
                MLAudioRxReportStats(conn, nowMs, NO);
                return;
            }

            MLCompressedInput input = { bytes, (UInt32)sampleLength, NO, {0} };
            BOOL converterFailed = NO;
            OSStatus failureStatus = noErr;
            int producedFrames = 0;
            // The first pass consumes the frame; a second pass collects PCM the
            // converter may still hold from its priming.
            for (int pass = 0; pass < 2; pass++) {
                AudioBufferList output;
                output.mNumberBuffers = 1;
                output.mBuffers[0].mNumberChannels = (UInt32)conn->_channelCount;
                output.mBuffers[0].mDataByteSize = (UInt32)(frames * conn->_channelCount * (int)sizeof(short));
                output.mBuffers[0].mData = conn->_compressedScratch;
                UInt32 outputFrames = (UInt32)frames;
                OSStatus status = AudioConverterFillComplexBuffer(conn->_compressedConverter,
                                                                  MLCompressedInputProc,
                                                                  &input,
                                                                  &outputFrames,
                                                                  &output,
                                                                  NULL);
                if (status != noErr && status != kMLCompressedNeedMoreInput) {
                    converterFailed = YES;
                    failureStatus = status;
                    break;
                }
                if (outputFrames == 0) {
                    break;
                }
                if (outputFrames > (UInt32)frames) {
                    outputFrames = (UInt32)frames;
                }
                MLCompressedFifoAppend(conn, conn->_compressedScratch, (int)outputFrames);
                producedFrames += (int)outputFrames;
                if (status == kMLCompressedNeedMoreInput || outputFrames < (UInt32)frames) {
                    break;
                }
            }

            if (converterFailed) {
                conn->_compressedConsecutiveErrors++;
                if (conn->_compressedConsecutiveErrors <= 3) {
                    Log(LOG_W, @"[audio] %@ conversion error %d (consecutive %llu); playing silence for this frame",
                        [MLAudioStreamPlan codecName:conn->_audioCodec], (int)failureStatus,
                        (unsigned long long)conn->_compressedConsecutiveErrors);
                }
                MLCompressedFifoAppend(conn, NULL, frames);
                if (conn->_compressedConsecutiveErrors >= ML_COMPRESSED_MAX_CONSECUTIVE_ERRORS) {
                    MLCompressedFail(conn, [NSString stringWithFormat:@"converter status %d", (int)failureStatus]);
                    MLAudioRxReportStats(conn, nowMs, NO);
                    return;
                }
            } else {
                conn->_compressedConsecutiveErrors = 0;
                conn->_compressedDecodedFrames += (uint64_t)producedFrames;
                if (conn->_compressedDecodedFrames == 0 &&
                    conn->_audioRxValidPackets >= ML_COMPRESSED_MAX_SILENT_FRAMES) {
                    MLCompressedFail(conn, @"the decoder returned no audio");
                    MLAudioRxReportStats(conn, nowMs, NO);
                    return;
                }
            }
        }
    }

    if (!passthrough) {
        MLCompressedFifoDrain(conn, nowMs);
    }
    MLAudioRxReportStats(conn, nowMs, NO);
}

void ArDecodeAndPlaySample(char* sampleData, int sampleLength)
{
    Connection *conn = CurrentConnection();
    if (conn == nil) {
        return;
    }
    const BOOL usePcm = conn->_audioCodec == MLAudioCodecPcm;
    const BOOL useCompressed = conn->_audioCodec == MLAudioCodecAc3 || conn->_audioCodec == MLAudioCodecEac3;
    if (!usePcm && !useCompressed && conn->_opusDecoder == NULL) {
        return;
    }
    if (sampleData != NULL && sampleLength > 0 &&
        __atomic_load_n(&conn->_audioAnyPacketSeen, __ATOMIC_RELAXED) == 0) {
        __atomic_store_n(&conn->_audioAnyPacketSeen, 1, __ATOMIC_RELAXED);
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
    
    // Passthrough frames never touch the ring, which nothing consumes then and
    // which therefore sits full: they must be handled before the ring check.
    if (useCompressed && __atomic_load_n(&conn->_audioPassthroughActive, __ATOMIC_ACQUIRE) != 0) {
        MLCompressedHandleSample(conn, sampleData, sampleLength);
        return;
    }

    // Check if there is space for this sample in the buffer. Again, this can race
    // but in the worst case, we'll not see the sample callback having consumed a sample.
    // While no output is running (still starting, or retrying after a failure) nothing
    // consumes, so the ring fills once and the rest is dropped here without blocking
    // or logging; the output start discards that stale content.
    if (conn->_audioBufferEntries == 0 || ((conn->_audioBufferWriteIndex + 1) % conn->_audioBufferEntries) == conn->_audioBufferReadIndex) {
        // Counted so the ring line shows when the output side keeps the ring full, which
        // is how audio is lost without any network loss (not logged per packet). Drops
        // before the output runs are expected (the start discards that content).
        if (conn->_audioOutputRunning) {
            conn->_audioRingFullDrops++;
        }
        MLAudioRxReportStats(conn, LiGetMillis(), NO);
        return;
    }

    if (usePcm) {
        MLPcmHandleSample(conn, sampleData, sampleLength);
        return;
    }
    if (useCompressed) {
        MLCompressedHandleSample(conn, sampleData, sampleLength);
        return;
    }
    
    // The PCM and AC3 paths report from their own handlers; Opus has none.
    MLAudioRxReportStats(conn, LiGetMillis(), NO);

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
        __atomic_store_n(&conn->_lastAudioSampleMs, LiGetMillis(), __ATOMIC_RELAXED);
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
                __atomic_store_n(&conn->_lastAudioSampleMs, LiGetMillis(), __ATOMIC_RELAXED);
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

// Tells the user once per session that the audio transport misbehaved and, when
// the host clearly cannot deliver the codec, remembers that for the next session.
// Called from the audio decode thread, so the work is handed to another queue.
- (void)noteAudioCodecProblemWithNoticeKey:(NSString *)noticeKey markUnsupported:(BOOL)markUnsupported {
    if (__atomic_exchange_n(&_audioNoticeSent, 1, __ATOMIC_RELAXED) != 0) {
        return;
    }
    const int codec = _audioCodec;
    NSString *hostKey = _audioHostKey;
    NSString *codecName = [MLAudioStreamPlan codecDisplayName:codec];
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(self);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (markUnsupported && hostKey.length > 0) {
            [SettingsClass markAudioCodecFailed:codec forHost:hostKey];
        }
        if (callbacks != nil && [callbacks respondsToSelector:@selector(audioCodecNotice:)]) {
            NSString *format = [[LanguageManager shared] localize:noticeKey];
            [callbacks audioCodecNotice:[NSString stringWithFormat:format, codecName]];
        }
    });
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
        // The host sends no audio packets while nothing is playing. An empty
        // buffer is an underrun only when audio was arriving a moment ago.
        uint64_t lastSampleMs = __atomic_load_n(&_lastAudioSampleMs, __ATOMIC_RELAXED);
        if (lastSampleMs == 0 || LiGetMillis() - lastSampleMs > 250) {
            return;
        }
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
        if (stereoFallback && [self audioOutputAttemptCancelled]) {
            return NO;
        }
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
            _audioOutputStartStatus = status;
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
            _audioOutputStartStatus = status;
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
            _audioOutputStartStatus = status;
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
                _audioOutputStartStatus = status;
                [self cleanupSelectedAudioRenderer];
                Log(LOG_W, @"Direct renderer channel layout rejected (%d); retrying with stereo downmix", status);
                continue;
            }
        }

        status = AudioUnitInitialize(_audioUnit);
        if (status != noErr) {
            _audioOutputStartStatus = status;
            [self cleanupSelectedAudioRenderer];
            if (MLAudioStatusIsDeviceNotRunning(status)) {
                Log(LOG_W, @"Direct renderer initialization failed (%d, device not running); skipping the stereo downmix retry", status);
                return NO;
            }
            if (!stereoFallback && requestedRenderChannels > 2) {
                Log(LOG_W, @"Direct renderer multichannel initialization failed (%d); retrying with stereo downmix", status);
                continue;
            }
            return NO;
        }

        // Whatever accumulated in the ring while the device was unavailable is
        // stale; drop it so the first thing heard is current audio.
        [self discardBufferedAudio];
        status = AudioOutputUnitStart(_audioUnit);
        if (status != noErr) {
            _audioOutputStartStatus = status;
            [self cleanupSelectedAudioRenderer];
            if (MLAudioStatusIsDeviceNotRunning(status)) {
                // The stereo retry would wait out the same ~10 s device timeout.
                Log(LOG_W, @"Direct renderer start failed (%d, device not running); skipping the stereo downmix retry", status);
                return NO;
            }
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

// Frames waiting in the ring, counting the unread rest of the entry being read.
// Render thread. The write index may advance meanwhile, which only makes the answer low.
- (UInt32)bufferedRingFrames
{
    if (_audioBufferEntries <= 0 || _audioSamplesPerFrame <= 0) {
        return 0;
    }
    int entries = _audioBufferWriteIndex - _audioBufferReadIndex;
    if (entries < 0) {
        entries += _audioBufferEntries;
    }
    if (entries == 0) {
        return 0;
    }
    return (UInt32)entries * (UInt32)_audioSamplesPerFrame - _audioBufferReadFrameOffset;
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

    if (frameCount > _audioMaxPullFrames) {
        _audioMaxPullFrames = frameCount;
    }

    // Large pulls (seen on DisplayPort output: 2048 frames, twice back to back) leave no
    // slack when the ring is read down to empty on every burst, because the stream only
    // delivers as much as one burst per burst: every small delay then cuts a piece out of
    // the audio. Hold the output until the ring holds two pulls plus 20 ms, then play on;
    // an emptied ring while audio is still arriving builds the cushion again. Small pulls
    // (512 frames) keep reading immediately, as they always did.
    if (_audioMaxPullFrames > 1024 && _audioSamplesPerFrame > 0 && _audioBufferEntries > 2) {
        const UInt32 usableLimit = (UInt32)(_audioBufferEntries - 2) * (UInt32)_audioSamplesPerFrame;
        const UInt32 wanted = MIN(2 * _audioMaxPullFrames + 960, usableLimit);
        const UInt32 buffered = [self bufferedRingFrames];
        const uint64_t lastSampleMs = __atomic_load_n(&_lastAudioSampleMs, __ATOMIC_RELAXED);
        const BOOL audioArriving = lastSampleMs != 0 && LiGetMillis() - lastSampleMs <= 50;

        if (!_enhancedHoldingForBuffer && buffered == 0 && audioArriving) {
            _enhancedHoldingForBuffer = YES;
            _enhancedRebufferCount++;
        }
        if (_enhancedHoldingForBuffer) {
            // A stream that went quiet (the host sends nothing while nothing plays) must
            // still get its last, shorter than the cushion, sound out.
            const BOOL streamPaused = lastSampleMs != 0 && !audioArriving;
            if (buffered >= wanted || (streamPaused && buffered > 0)) {
                _enhancedHoldingForBuffer = NO;
            } else {
                if (interleaved) {
                    memset(interleavedDst, 0, frameCount * 2 * sizeof(float));
                    outputData->mBuffers[0].mDataByteSize = frameCount * 2 * sizeof(float);
                } else {
                    memset(leftDst, 0, frameCount * sizeof(float));
                    memset(rightDst, 0, frameCount * sizeof(float));
                    outputData->mBuffers[0].mDataByteSize = frameCount * sizeof(float);
                    outputData->mBuffers[1].mDataByteSize = frameCount * sizeof(float);
                }
                return;
            }
        }
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
        [self discardBufferedAudio];
        if (![_enhancedAudioEngine startAndReturnError:&error]) {
            _audioOutputStartStatus = error != nil ? (OSStatus)error.code : kAudioHardwareUnspecifiedError;
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
        // The size the engine really pulls is in the later [audio] ring line (maxPull);
        // logging the device's own buffer size next to it shows whether they differ.
        Log(LOG_I, @"Initialized enhanced audio renderer: preset=%d target=%d spatial=%.2f width=%.2f samplesPerFrame=%d bufferEntries=%d outputDevice=%@ deviceBufferFrames=%u",
            _enhancedAudioPreset,
            _enhancedAudioOutputTarget,
            _enhancedAudioSpatialIntensity,
            _enhancedAudioSoundstageWidth,
            opusConfig->samplesPerFrame,
            _audioBufferEntries,
            MLDefaultOutputDeviceName(),
            (unsigned int)MLDefaultOutputBufferFrames());
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

#pragma mark - Output start, retry and teardown

// Seconds to wait after the Nth failed start attempt before trying again.
static const int kAudioOutputRetryDelaysSec[] = { 3, 5, 8, 12, 15 };
// Settle time after the system reports a device change before retrying.
static const NSTimeInterval kAudioOutputDeviceChangeRetryDelaySec = 0.5;
// How long ArCleanup waits for the output queue. An in-flight start returns
// within CoreAudio's own ~10 s timeout; this bound only protects stream
// shutdown from a wedged CoreAudio.
static const int64_t kAudioOutputTeardownWaitSec = 15;

- (BOOL)audioOutputAttemptCancelled
{
    return __atomic_load_n(&_audioOutputGeneration, __ATOMIC_SEQ_CST) != _audioAttemptGeneration;
}

// Drops everything buffered so far. Only called right before an output starts
// consuming, so no reader is active; the decode thread keeps writing, which only
// ever moves the write index forward.
- (void)discardBufferedAudio
{
    _audioBufferReadFrameOffset = 0;
    __sync_synchronize();
    _audioBufferReadIndex = _audioBufferWriteIndex;
}

- (OSStatus)initializeLegacyAudioQueueRendererWithOpusConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig
                                               channelLayout:(const AudioChannelLayout *)channelLayout
{
    AudioStreamBasicDescription audioFormat = {0};
    audioFormat.mSampleRate = opusConfig->sampleRate;
    audioFormat.mBitsPerChannel = 16;
    audioFormat.mFormatID = kAudioFormatLinearPCM;
    audioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    audioFormat.mChannelsPerFrame = opusConfig->channelCount;
    audioFormat.mBytesPerFrame = audioFormat.mChannelsPerFrame * (audioFormat.mBitsPerChannel / 8);
    audioFormat.mBytesPerPacket = audioFormat.mBytesPerFrame;
    audioFormat.mFramesPerPacket = audioFormat.mBytesPerPacket / audioFormat.mBytesPerFrame;
    audioFormat.mReserved = 0;

    if (_audioQueueContext == NULL) {
        _audioQueueContext = (__bridge_retained void *)self;
    }

    OSStatus status = AudioQueueNewOutput(&audioFormat, FillOutputBuffer, _audioQueueContext, nil, nil, 0, &_audioQueue);
    if (status != noErr) {
        Log(LOG_E, @"Error allocating output queue: %d\n", status);
        _audioQueue = NULL;
        if (_audioQueueContext != NULL) {
            CFBridgingRelease(_audioQueueContext);
            _audioQueueContext = NULL;
        }
        return status;
    }

    // We need to specify a channel layout for surround sound configurations
    status = AudioQueueSetProperty(_audioQueue, kAudioQueueProperty_ChannelLayout, channelLayout, sizeof(AudioChannelLayout));
    if (status != noErr) {
        Log(LOG_E, @"Error configuring surround channel layout: %d\n", status);
        AudioQueueDispose(_audioQueue, true);
        _audioQueue = NULL;
        if (_audioQueueContext != NULL) {
            CFBridgingRelease(_audioQueueContext);
            _audioQueueContext = NULL;
        }
        return status;
    }

    [self discardBufferedAudio];
    for (int i = 0; i < AUDIO_QUEUE_BUFFERS; i++) {
        status = AudioQueueAllocateBuffer(_audioQueue, audioFormat.mBytesPerFrame * opusConfig->samplesPerFrame, &_audioBuffers[i]);
        if (status != noErr) {
            Log(LOG_E, @"Error allocating output buffer: %d\n", status);
            AudioQueueDispose(_audioQueue, true);
            _audioQueue = NULL;
            if (_audioQueueContext != NULL) {
                CFBridgingRelease(_audioQueueContext);
                _audioQueueContext = NULL;
            }
            return status;
        }

        FillOutputBuffer(_audioQueueContext, _audioQueue, _audioBuffers[i]);
    }

    status = AudioQueueStart(_audioQueue, nil);
    if (status != noErr) {
        Log(LOG_E, @"Error starting queue: %d\n", status);
        AudioQueueDispose(_audioQueue, true);
        _audioQueue = NULL;
        if (_audioQueueContext != NULL) {
            CFBridgingRelease(_audioQueueContext);
            _audioQueueContext = NULL;
        }
        return status;
    }

    return noErr;
}

// Creates the output queue, or waits for a teardown of a previous run on this
// object that timed out and may still be queued.
- (void)prepareAudioOutputQueue
{
    if (_audioOutputQueue == nil) {
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                             QOS_CLASS_USER_INITIATED, 0);
        _audioOutputQueue = dispatch_queue_create("moonlight.audio.output", attr);
    } else {
        dispatch_sync(_audioOutputQueue, ^{});
    }
}

// Called by ArInit once decoder and ring exist. Returns immediately; the first
// start attempt runs on the output queue.
- (void)beginAudioOutputStartWithOpusConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig
                              channelLayout:(const AudioChannelLayout *)channelLayout
{
    _audioOutputOpusConfig = *opusConfig;
    _audioOutputChannelLayout = *channelLayout;
    _audioOutputRunning = NO;
    _audioOutputFailureNoticed = NO;
    _audioOutputStartAttempts = 0;
    _audioOutputStartStatus = noErr;
    // Safe to drop the previous session's output here: its teardown already ran
    // on the output queue (prepareAudioOutputQueue waited for it) and the decode
    // thread has not been started yet.
    __atomic_store_n(&_audioPassthroughActive, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&_audioPassthroughEverStarted, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&_audioPassthroughFallbackRequested, 0, __ATOMIC_SEQ_CST);
    _bitstreamOutput = nil;
    _audioPassthroughGivenUp = NO;
    _audioLeftoverChecked = NO;
    _audioPassthroughConsecutiveRejects = 0;
    memset(&_bitstreamReported, 0, sizeof(_bitstreamReported));

    const int32_t generation = __atomic_add_fetch(&_audioOutputGeneration, 1, __ATOMIC_SEQ_CST);
    __weak Connection *weakSelf = self;

    // A start that failed may succeed once the system settles (display mode
    // change finished, another default device chosen, device re-attached), so
    // those events trigger a prompt retry. The block runs on the output queue.
    AudioObjectPropertyListenerBlock listener = ^(UInt32 numberAddresses, const AudioObjectPropertyAddress *addresses) {
        [weakSelf audioOutputEnvironmentChangedForGeneration:generation];
    };
    _audioOutputListener = listener;
    const AudioObjectPropertySelector selectors[] = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDevices,
    };
    for (size_t i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        AudioObjectPropertyAddress address = {
            selectors[i],
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        OSStatus status = AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &address,
                                                              _audioOutputQueue, listener);
        if (status != noErr) {
            Log(LOG_W, @"[audio] Could not observe audio device changes (selector 0x%08X, status %d); retries are timer-only",
                (unsigned int)selectors[i], (int)status);
        }
    }

    Log(LOG_I, @"[audio] Output start scheduled in the background; the stream does not wait for the audio device");

    // Nothing in the protocol says "the host has no audio for you": a host that
    // cannot open its audio device for the requested layout, or whose oversized
    // packets are dropped on the way, simply sends nothing. When no audio packet at
    // all has arrived after a while, name the likely reason. The host also sends
    // nothing while it is silent (unless asked to keep the stream active), so this
    // is a hint, not a failure, and nothing is remembered.
    NSString *silenceHintKey = nil;
    if (_audioCodec == MLAudioCodecPcm && _pcmExpectedBytes > _streamConfig.packetSize) {
        // PCM surround packets are larger than one network packet and depend on IP fragmentation.
        silenceHintKey = @"No lossless audio has arrived yet. If the host is playing sound, the network is dropping its large audio packets; use stereo, AC3 or Opus instead.";
    } else if (_channelCount > 8) {
        // 7.1.4 needs a host audio device that accepts 12 channels; common virtual
        // sinks stop at 7.1 and the host then streams without audio.
        silenceHintKey = @"No audio has arrived yet. If the host is playing sound, its audio device does not support 7.1.4; choose 7.1 surround instead.";
    }
    __atomic_store_n(&_audioAnyPacketSeen, 0, __ATOMIC_RELAXED);
    if (silenceHintKey != nil) {
        const int channels = _channelCount;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), _audioOutputQueue, ^{
            Connection *strongSelf = weakSelf;
            if (strongSelf == nil ||
                __atomic_load_n(&strongSelf->_audioOutputGeneration, __ATOMIC_SEQ_CST) != generation ||
                __atomic_load_n(&strongSelf->_audioAnyPacketSeen, __ATOMIC_RELAXED) != 0) {
                return;
            }
            Log(LOG_W, @"[audio] No audio packet has arrived 12 s into the stream (codec=%@ channels=%d); the host may be streaming without audio or its packets are not getting through",
                [MLAudioStreamPlan codecName:strongSelf->_audioCodec], channels);
            [strongSelf postAudioOutputNoticeWithKey:silenceHintKey deviceName:nil];
        });
    }
    dispatch_async(_audioOutputQueue, ^{
        [weakSelf runAudioOutputStartAttemptForGeneration:generation];
    });
}

// Output queue only.
- (void)audioOutputEnvironmentChangedForGeneration:(int32_t)generation
{
    if (__atomic_load_n(&_audioOutputGeneration, __ATOMIC_SEQ_CST) != generation || _audioOutputRunning) {
        return;
    }
    Log(LOG_I, @"[audio] Audio devices changed while the output is not running; retrying in %.1fs",
        kAudioOutputDeviceChangeRetryDelaySec);
    [self scheduleAudioOutputRetryAfter:kAudioOutputDeviceChangeRetryDelaySec generation:generation];
}

// Output queue only. A newer schedule (or a running attempt) supersedes this one.
- (void)scheduleAudioOutputRetryAfter:(NSTimeInterval)delay generation:(int32_t)generation
{
    const int32_t token = ++_audioOutputRetryToken;
    __weak Connection *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _audioOutputQueue, ^{
        Connection *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf->_audioOutputRetryToken != token) {
            return;
        }
        [strongSelf runAudioOutputStartAttemptForGeneration:generation];
    });
}

// Tells the user about the audio output through the stream notice. Not the
// codec-problem path: that one is latched once per session on purpose.
- (void)postAudioOutputNoticeWithKey:(NSString *)noticeKey deviceName:(NSString *)deviceName
{
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(self);
    if (callbacks == nil || ![callbacks respondsToSelector:@selector(audioCodecNotice:)]) {
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *format = [[LanguageManager shared] localize:noticeKey];
        NSString *message = deviceName.length > 0 ? [NSString stringWithFormat:format, deviceName] : format;
        [callbacks audioCodecNotice:message];
    });
}

// One start attempt: the configured backend, then (unless the device clock is
// known not to run) the remaining fallbacks. Output queue only; the serial
// queue is what keeps two attempts from ever overlapping.
- (void)runAudioOutputStartAttemptForGeneration:(int32_t)generation
{
    if (__atomic_load_n(&_audioOutputGeneration, __ATOMIC_SEQ_CST) != generation || _audioOutputRunning) {
        return;
    }
    _audioAttemptGeneration = generation;
    // Supersede any timer still pending from an earlier failure.
    _audioOutputRetryToken++;

    const int attempt = ++_audioOutputStartAttempts;
    const uint64_t startMs = LiGetMillis();
    if (!_audioLeftoverChecked) {
        // Before any backend touches the device: a crashed earlier run may have
        // left it in an encoded format that breaks PCM output.
        _audioLeftoverChecked = YES;
        [MLAudioBitstreamOutput restoreLeftoverDeviceFormatIfNeeded];
    }
    OPUS_MULTISTREAM_CONFIGURATION opusConfig = _audioOutputOpusConfig;
    AudioChannelLayout channelLayout = _audioOutputChannelLayout;
    // Backends overwrite this with the status of the step that failed.
    _audioOutputStartStatus = kAudioHardwareUnspecifiedError;

    BOOL started = NO;
    MLAudioRendererBackend backend = MLAudioRendererBackendLegacyQueue;
    const MLAudioOutputMode mode = (MLAudioOutputMode)_audioOutputMode;

    // Passthrough first. If it cannot start it is given up for the session and
    // this same attempt carries on with the normal backends (local decode), so
    // no "did not start" notice comes from it alone.
    if (!_audioPassthroughGivenUp && ![self audioOutputAttemptCancelled]) {
        NSString *rejection = [self audioPassthroughRejectionReason];
        if (rejection == nil) {
            if ([self startAudioPassthroughOnOutputQueue]) {
                started = YES;
                backend = MLAudioRendererBackendBitstream;
            }
        } else if ([self audioCodecUsesPassthroughPath]) {
            // Not latched: the default device may change before a later attempt.
            Log(LOG_I, @"[audio] Passthrough not used: %@; decoding on this Mac", rejection);
        }
    }

    if (started || MLAudioStatusIsDeviceNotRunning(_audioOutputStartStatus)) {
        // Nothing else to start, or the device clock is not running and every
        // other backend would wait out the same timeout.
    } else if (mode == MLAudioOutputModeDirect) {
        if ([self initializeDirectAudioRendererWithOpusConfig:&opusConfig channelLayout:&channelLayout]) {
            started = YES;
            backend = MLAudioRendererBackendDirect;
        } else if (!MLAudioStatusIsDeviceNotRunning(_audioOutputStartStatus) && ![self audioOutputAttemptCancelled]) {
            Log(LOG_W, @"Direct audio renderer unavailable; falling back to legacy audio queue backend");
        }
    } else if (mode == MLAudioOutputModeEnhanced) {
        if ([self initializeEnhancedAudioRendererWithOpusConfig:&opusConfig]) {
            started = YES;
            backend = MLAudioRendererBackendEnhanced;
        } else if (!MLAudioStatusIsDeviceNotRunning(_audioOutputStartStatus) && ![self audioOutputAttemptCancelled]) {
            Log(LOG_W, @"Enhanced audio renderer unavailable; falling back to legacy audio queue backend");
        }
    }

    if (!started) {
        if ([self audioOutputAttemptCancelled]) {
            // Stream is ending; ArCleanup's teardown follows on this queue.
        } else if (MLAudioStatusIsDeviceNotRunning(_audioOutputStartStatus)) {
            Log(LOG_W, @"[audio] Output device clock is not running; skipping the remaining backends of attempt %d", attempt);
        } else {
            OSStatus status = [self initializeLegacyAudioQueueRendererWithOpusConfig:&opusConfig
                                                                       channelLayout:&channelLayout];
            if (status == noErr) {
                started = YES;
                backend = MLAudioRendererBackendLegacyQueue;
            } else {
                _audioOutputStartStatus = status;
            }
        }
    }

    const uint64_t elapsedMs = LiGetMillis() - startMs;

    if (started) {
        _audioRendererBackend = backend;
        _audioOutputRunning = YES;
        Log(LOG_I, @"[audio] Output started on attempt %d after %llums: backend=%@",
            attempt, (unsigned long long)elapsedMs, MLAudioRendererBackendName(backend));
        if (_audioOutputFailureNoticed && ![self audioOutputAttemptCancelled]) {
            _audioOutputFailureNoticed = NO;
            [self postAudioOutputNoticeWithKey:@"Audio restored." deviceName:nil];
        }
        return;
    }

    if ([self audioOutputAttemptCancelled]) {
        return;
    }

    const int delaySec = kAudioOutputRetryDelaysSec[MIN(attempt, (int)(sizeof(kAudioOutputRetryDelaysSec) / sizeof(kAudioOutputRetryDelaysSec[0]))) - 1];
    NSString *deviceName = MLDefaultOutputDeviceName();
    Log(LOG_W, @"[audio] Output start attempt %d failed: status=%d (%@) device=%@ elapsedMs=%llu; stream continues without sound, retry in %ds",
        attempt,
        (int)_audioOutputStartStatus,
        MLAudioStatusFourCC(_audioOutputStartStatus),
        deviceName,
        (unsigned long long)elapsedMs,
        delaySec);

    if (!_audioOutputFailureNoticed) {
        _audioOutputFailureNoticed = YES;
        // MLDefaultOutputDeviceName reports "Unknown Output" when the name cannot be read.
        BOOL hasName = deviceName.length > 0 && ![deviceName isEqualToString:@"Unknown Output"];
        [self postAudioOutputNoticeWithKey:hasName
            ? @"Audio output \"%@\" did not start. The stream continues without sound and keeps retrying."
            : @"The audio output did not start. The stream continues without sound and keeps retrying."
                                deviceName:hasName ? deviceName : nil];
    }

    [self scheduleAudioOutputRetryAfter:delaySec generation:generation];
}

#pragma mark - Bitstream passthrough (output queue)

- (BOOL)audioCodecUsesPassthroughPath
{
    return _audioCodec == MLAudioCodecAc3 || _audioCodec == MLAudioCodecEac3;
}

// nil when this session can pass the codec through to the current default output
// device, otherwise the reason it cannot. The same rule is used for the plan in the
// stream start log and for the start attempt (which asks again, because the default
// device may have changed since).
- (NSString *)audioPassthroughRejectionReason
{
    if (![self audioCodecUsesPassthroughPath]) {
        return @"codec";
    }
    if (_audioHostKey.length > 0 && ![SettingsClass audioBitstreamPassthroughAllowedFor:_audioHostKey]) {
        return @"user setting";
    }
    if (_channelCount > 6) {
        return @"more than 5.1 channels";
    }
    MLAudioBitstreamSupport *support = [MLAudioBitstreamOutput supportForCodecOnDefaultDevice:_audioCodec];
    if (!support.available) {
        return [NSString stringWithFormat:@"%@ does not accept %@", support.deviceName,
                [MLAudioStreamPlan codecDisplayName:_audioCodec]];
    }
    return nil;
}

// Output queue only. YES when the bitstream output is running; on failure the
// output is torn down by the class itself and passthrough is given up.
- (BOOL)startAudioPassthroughOnOutputQueue
{
    const int32_t generation = _audioAttemptGeneration;
    MLAudioBitstreamOutput *output = [[MLAudioBitstreamOutput alloc] initWithCodec:_audioCodec
                                                                            device:kAudioObjectUnknown];
    __weak Connection *weakSelf = self;
    // Called on the output's own queue. Only hops to ours: stopping from there
    // would wait on the very callback that is running.
    output.eventHandler = ^(MLAudioBitstreamEvent event, NSString *detail) {
        Connection *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf->_audioOutputQueue == nil) {
            return;
        }
        dispatch_async(strongSelf->_audioOutputQueue, ^{
            [strongSelf audioPassthroughLostWithDetail:detail generation:generation];
        });
    };

    NSError *error = nil;
    if (![output start:&error]) {
        NSNumber *status = error.userInfo[MLAudioBitstreamErrorStatusKey];
        if (status != nil && MLAudioStatusIsDeviceNotRunning((OSStatus)status.intValue)) {
            // The device clock is not running: no backend can start right now, and
            // passthrough is as likely to work as any once it recovers. Leave it
            // eligible and let the attempt end here so the retry tries it again.
            _audioOutputStartStatus = (OSStatus)status.intValue;
            Log(LOG_W, @"[audio] Passthrough could not start (%@); the device is not running, it will be tried again",
                error.localizedDescription ?: @"unknown error");
            return NO;
        }
        _audioPassthroughGivenUp = YES;
        Log(LOG_W, @"[audio] Passthrough could not start (%@); decoding %@ on this Mac instead",
            error.localizedDescription ?: @"unknown error", [MLAudioStreamPlan codecDisplayName:_audioCodec]);
        return NO;
    }

    _bitstreamOutput = output;
    const int burstBytes = _audioCodec == MLAudioCodecEac3 ? 24576 : 6144;
    Log(LOG_I, @"[audio] Passthrough started: device=%@ codec=%@ burst=%d bytes (%d ms)",
        output.deviceName, [MLAudioStreamPlan codecDisplayName:_audioCodec], burstBytes, 32);
    __atomic_store_n(&_audioPassthroughEverStarted, 1, __ATOMIC_RELEASE);
    __atomic_store_n(&_audioPassthroughActive, 1, __ATOMIC_RELEASE);
    return YES;
}

// Output queue only. Idempotent. Stops the decode thread from using the output
// first, then lets the class restore the device. The object stays alive.
- (void)stopAudioPassthroughOnOutputQueue
{
    __atomic_store_n(&_audioPassthroughActive, 0, __ATOMIC_SEQ_CST);
    [_bitstreamOutput stop];
}

// Any thread (the decode thread, when the output keeps rejecting frames).
- (void)requestAudioPassthroughFallbackWithDetail:(NSString *)detail
{
    if (__atomic_exchange_n(&_audioPassthroughFallbackRequested, 1, __ATOMIC_SEQ_CST) != 0 || _audioOutputQueue == nil) {
        return;
    }
    const int32_t generation = __atomic_load_n(&_audioOutputGeneration, __ATOMIC_SEQ_CST);
    __weak Connection *weakSelf = self;
    dispatch_async(_audioOutputQueue, ^{
        [weakSelf audioPassthroughLostWithDetail:detail generation:generation];
    });
}

// Output queue only. The device went away, changed, was taken over, or the
// output stopped being usable: carry on decoding on this Mac through the normal
// start/retry machinery. The host's codec is fine, so it is not marked as failed.
- (void)audioPassthroughLostWithDetail:(NSString *)detail generation:(int32_t)generation
{
    if (__atomic_load_n(&_audioOutputGeneration, __ATOMIC_SEQ_CST) != generation ||
        __atomic_load_n(&_audioPassthroughActive, __ATOMIC_SEQ_CST) == 0) {
        return;
    }
    __atomic_store_n(&_audioPassthroughFallbackRequested, 1, __ATOMIC_SEQ_CST);
    MLAudioBitstreamStats stats = [_bitstreamOutput stats];
    Log(LOG_W, @"[audio] Passthrough stopped: %@. Falling back to decoding %@ on this Mac (bursts enqueued=%llu played=%llu pause=%llu dropped=%llu)",
        detail, [MLAudioStreamPlan codecDisplayName:_audioCodec],
        (unsigned long long)stats.burstsEnqueued, (unsigned long long)stats.burstsPlayed,
        (unsigned long long)stats.pauseBursts, (unsigned long long)stats.droppedBursts);
    [self stopAudioPassthroughOnOutputQueue];
    _audioPassthroughGivenUp = YES;
    _audioOutputRunning = NO;
    _audioOutputStartAttempts = 0;
    _audioOutputFailureNoticed = NO;
    [self postAudioOutputNoticeWithKey:@"Dolby passthrough stopped; audio continues decoded on this Mac." deviceName:nil];
    // A short settle time: the device was just handed back (format, hog mode).
    [self scheduleAudioOutputRetryAfter:0.3 generation:generation];
}

// ArCleanup: cancels pending and future starts, stops the output and frees the
// buffers the render callbacks read. Waits for the output queue so an in-flight
// start finishes (and is torn down) before the memory goes away, but never longer
// than kAudioOutputTeardownWaitSec; see the ivar comment for the timeout case.
- (void)shutdownAudioOutput
{
    __atomic_add_fetch(&_audioOutputGeneration, 1, __ATOMIC_SEQ_CST);

    AudioObjectPropertyListenerBlock listener = _audioOutputListener;
    _audioOutputListener = nil;
    if (listener != nil) {
        const AudioObjectPropertySelector selectors[] = {
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDevices,
        };
        for (size_t i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
            AudioObjectPropertyAddress address = {
                selectors[i],
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };
            AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &address, _audioOutputQueue, listener);
        }
    }

    void (^teardown)(void) = ^{
        // Restores the device format, mixing and hog mode before anything else
        // could open the device, and before the ring below is freed.
        [self stopAudioPassthroughOnOutputQueue];
        [self cleanupSelectedAudioRenderer];
        self->_audioOutputRunning = NO;
        // Freed only now that nothing can render from them any more.
        if (self->_audioCircularBuffer != NULL) {
            free(self->_audioCircularBuffer);
            self->_audioCircularBuffer = NULL;
        }
        if (self->_audioRenderScratchBuffer != NULL) {
            free(self->_audioRenderScratchBuffer);
            self->_audioRenderScratchBuffer = NULL;
        }
    };

    if (_audioOutputQueue == nil) {
        teardown();
        return;
    }

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(_audioOutputQueue, ^{
        teardown();
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, kAudioOutputTeardownWaitSec * NSEC_PER_SEC)) != 0) {
        Log(LOG_W, @"[audio] Audio output teardown is still waiting on CoreAudio after %llds; it will finish in the background",
            (long long)kAudioOutputTeardownWaitSec);
    }
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

void ClSetHdrMode(bool enabled, void *hdrMetadata)
{
    // The metadata also arrives with the callback, but it is read from the
    // control context so every update goes through the same accessor.
    (void)hdrMetadata;
    Connection *connection = CurrentConnection();
    if (connection == nil) return;
    SS_HDR_METADATA metadata = {0};
    BOOL hasMetadata = enabled && LiGetHdrMetadataCtx(&connection->_connectionContext.controlContext, &metadata);
    [ConnectionGetRendererSnapshot(connection) updateHostHDRMode:enabled metadata:hasMetadata ? &metadata : NULL];
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

    LogLevel derivedLevel = isDropLog ? LOG_W : (isHighFrequencyDiagnostic ? LOG_D : LOG_I);

    // The logger decides what is kept (level, input diagnostics) and writes the file, stderr and
    // in-app copies on its own queue; this callback only formats the text. Skip even that when the
    // line would be dropped.
    bool wanted = (!isHighFrequencyDiagnostic || LoggerIsInputDiagnosticsEnabled()) && LoggerWouldLog(derivedLevel);
    if (wanted) {
        va_list va;
        va_start(va, format);

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
                LoggerPersistMessage(derivedLevel, trimmedLine);
            }
        }
    }

    if (isDropLog && accumulatedDropCount > 1) {
        LogMessage(LOG_W, [NSString stringWithFormat:@"(and %d more dropped frame messages suppressed)", accumulatedDropCount - 1]);
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

void ClRumbleTriggers(uint16_t controllerNumber, uint16_t leftTriggerMotor, uint16_t rightTriggerMotor)
{
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    if (callbacks != nil && [callbacks respondsToSelector:@selector(rumbleTriggers:leftTriggerMotor:rightTriggerMotor:)]) {
        [callbacks rumbleTriggers:controllerNumber leftTriggerMotor:leftTriggerMotor rightTriggerMotor:rightTriggerMotor];
    }
}

void ClSetControllerLED(uint16_t controllerNumber, uint8_t red, uint8_t green, uint8_t blue)
{
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    if (callbacks != nil && [callbacks respondsToSelector:@selector(setControllerLED:red:green:blue:)]) {
        [callbacks setControllerLED:controllerNumber red:red green:green blue:blue];
    }
}

void ClSetAdaptiveTriggers(uint16_t controllerNumber, uint8_t eventFlags, uint8_t typeLeft, uint8_t typeRight,
                           uint8_t *left, uint8_t *right)
{
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    if (callbacks != nil && [callbacks respondsToSelector:@selector(setAdaptiveTriggers:eventFlags:typeLeft:typeRight:left:right:)]) {
        [callbacks setAdaptiveTriggers:controllerNumber eventFlags:eventFlags typeLeft:typeLeft typeRight:typeRight left:left right:right];
    }
}

void ClDs5HapticsIrV2(const LI_DS5_HAPTICS_IR_FRAME_V2 *frame) {
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    if (frame != NULL && [callbacks respondsToSelector:@selector(ds5HapticsIrV2:)]) {
        [callbacks ds5HapticsIrV2:frame];
    }
}

void ClDs5HapticsPcm(const LI_DS5_HAPTICS_PCM_FRAME *frame)
{
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    if (callbacks != nil && frame != NULL &&
        [callbacks respondsToSelector:@selector(ds5HapticsPcm:)]) {
        [callbacks ds5HapticsPcm:frame];
    }
}

void ClSetMotionEventState(uint16_t controllerNumber, uint8_t motionType, uint16_t reportRateHz)
{
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    if (callbacks != nil && [callbacks respondsToSelector:@selector(setMotionEventState:motionType:reportRateHz:)]) {
        [callbacks setMotionEventState:controllerNumber motionType:motionType reportRateHz:reportRateHz];
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

void ClResolutionChanged(uint32_t width, uint32_t height)
{
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    Log(LOG_I, @"[live] Host resolution changed: %ux%u", width, height);
    if (callbacks != nil &&
        [callbacks respondsToSelector:@selector(streamResolutionChanged:height:)]) {
        [callbacks streamResolutionChanged:width height:height];
    }
}

void ClRemoteTextContext(const LI_REMOTE_TEXT_CONTEXT *context)
{
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    if (callbacks != nil && context != NULL &&
        [callbacks respondsToSelector:@selector(remoteTextContextUpdated:)]) {
        [callbacks remoteTextContextUpdated:context];
    }
}

void ClClipboardDataReceived(const uint8_t *data, uint32_t length)
{
    Connection *conn = CurrentConnection();
    id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(conn);
    if (callbacks != nil &&
        [callbacks respondsToSelector:@selector(clipboardDataReceived:length:)]) {
        [callbacks clipboardDataReceived:data length:length];
    }
}

- (void)dealloc
{
    // Remove notification observer to prevent crashes from stale references
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

-(void) terminate
{
    if (!_connectionLayoutCompatible) {
        UnregisterConnection(&_connectionContext);
        return;
    }
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

    _connectionLayoutCompatible = LiIsConnectionContextLayoutCompatible(
        sizeof(ML_CONNECTION_CONTEXT), offsetof(ML_CONNECTION_CONTEXT, controlContext),
        offsetof(ML_CONNECTION_CONTEXT, inputContext), offsetof(ML_CONNECTION_CONTEXT, stage));
    Log(_connectionLayoutCompatible ? LOG_I : LOG_E,
        @"[diag] Connection ABI: compatible=%d size=%zu control=%zu input=%zu stage=%zu",
        _connectionLayoutCompatible, sizeof(ML_CONNECTION_CONTEXT),
        offsetof(ML_CONNECTION_CONTEXT, controlContext),
        offsetof(ML_CONNECTION_CONTEXT, inputContext), offsetof(ML_CONNECTION_CONTEXT, stage));

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

    // The RTSP session URL only exists once the host answered launch/resume. It is applied by
    // -bindLaunchResultWithSessionUrl:, so this object can be built while that request is
    // still in flight.

    ConnectionSetRenderer(self, myRenderer);
    [myRenderer updateHostHDRMetadata:NULL];
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
    // -2 keeps the host default. Anything else is only sent when the host
    // advertises FEC control; common-c ignores the preference otherwise.
    _streamConfig.videoFecPercentage = (config.videoFecPercentage >= -2 && config.videoFecPercentage <= 100)
        ? config.videoFecPercentage : -2;
    if (_streamConfig.videoFecPercentage != -2) {
        Log(LOG_I, @"[fec] Client FEC preference requested: %d (-1 automatic)", _streamConfig.videoFecPercentage);
    }

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
    _streamConfig.enable10BitSdr = config.enable10BitSdr;

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
    
    // Audio transport. Everything except Opus is a Foundation Sunshine extension and
    // the host never acknowledges the codec, so the effective choice is made here
    // and ArInit cross-checks it against what the library actually requests.
    _audioHostKey = [config.hostUUID copy];
    NSInteger userAudioCodec = _audioHostKey.length > 0 ? [SettingsClass audioCodecFor:_audioHostKey]
                                                        : config.audioCodec;
    BOOL userAudioCodecFailed = _audioHostKey.length > 0 &&
        [SettingsClass audioCodecFailed:userAudioCodec forHost:_audioHostKey];
    _audioPlan = [MLAudioStreamPlan planWithRequestedCodec:userAudioCodec
                                              channelCount:CHANNEL_COUNT_FROM_AUDIO_CONFIGURATION(config.audioConfiguration)
                                          videoBitrateKbps:_streamConfig.bitrate
                                disableHighQualitySurround:config.disableHighQualitySurround
                                            foundationHost:config.foundationHost ? 1 : 0
                                               codecFailed:userAudioCodecFailed];
    _audioRequestedCodec = (int)userAudioCodec;
    _continuousAudio = config.continuousAudio;
    _audioCodec = (int)_audioPlan.effectiveCodec;
#if defined(AUDIO_CODEC_PCM_S16)
    _streamConfig.audioCodec = _audioCodec;
    // AC3 / E-AC3 frames are sent as one datagram each. At the host defaults (640 /
    // 384 kbps) a frame is 2560 / 1536 bytes, which only arrives if every hop
    // fragments and reassembles it; with mismatched MTUs or over a tunnel it is
    // dropped and the stream is silent. Ask for a bitrate whose frame fits in one
    // packet instead: 320 kbps = 1280 bytes, 256 kbps = 1024 bytes on small-MTU paths.
    // 0 keeps the library default (fixed for PCM).
    _streamConfig.audioBitrate = 0;
    if (_audioCodec == MLAudioCodecAc3 || _audioCodec == MLAudioCodecEac3) {
        _streamConfig.audioBitrate = _streamConfig.packetSize >= 1392
            ? (int)[MLAudioStreamPlan compressedBitrateKbps] * 1000
            : (_streamConfig.packetSize >= 1024 ? 224000 : 192000);
        Log(LOG_I, @"[audio] Requesting %@ at %d kbps so each frame (%d bytes) fits in one packet (packetSize=%d)",
            [MLAudioStreamPlan codecName:_audioCodec],
            _streamConfig.audioBitrate / 1000,
            _streamConfig.audioBitrate / 1000 * 32 / 8,
            _streamConfig.packetSize);
    }
#else
    if (_audioCodec != MLAudioCodecOpus) {
        Log(LOG_W, @"[audio] This build of the protocol library has no audio codec selection; using opus");
        _audioCodec = MLAudioCodecOpus;
    }
#endif
    if (_audioPlan.fallbackReason != MLAudioFallbackReasonNone) {
        Log(LOG_W, @"[audio] Requested codec %@ replaced by opus: %@",
            _audioPlan.requestedCodecName, _audioPlan.fallbackLogText);
    }

    // HDR implies HEVC allowed
    if (config.enableHdr || config.enable10BitSdr) {
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
    assert(!(config.enableHdr || config.enable10BitSdr) || hevcSupported || av1Supported);

    // The chroma decision (including dropping 4:4:4 for an explicit Dolby
    // Vision choice) is resolved once by the stream start path; see
    // StreamChromaDecision.
    BOOL enableYuv444 = config.enableYuv444;

    int supportedVideoFormats = VIDEO_FORMAT_H264;
    if (hevcSupported) {
        supportedVideoFormats |= VIDEO_FORMAT_H265;
        if (config.enableHdr || config.enable10BitSdr) {
            supportedVideoFormats |= VIDEO_FORMAT_H265_MAIN10;
        }
    }

    if (enableYuv444) {
        supportedVideoFormats |= VIDEO_FORMAT_H264_HIGH8_444;
        if (hevcSupported) {
            supportedVideoFormats |= VIDEO_FORMAT_H265_REXT8_444;
            if (config.enableHdr || config.enable10BitSdr) {
                supportedVideoFormats |= VIDEO_FORMAT_H265_REXT10_444;
            }
        }
    }

    if (av1Supported) {
        if (config.enableHdr || config.enable10BitSdr) {
            supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN10;
        } else {
            supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN8;
        }

        if (enableYuv444) {
            supportedVideoFormats |= VIDEO_FORMAT_AV1_HIGH8_444;
            if (config.enableHdr || config.enable10BitSdr) {
                supportedVideoFormats |= VIDEO_FORMAT_AV1_HIGH10_444;
            }
        }
    }

    _streamConfig.supportedVideoFormats = supportedVideoFormats;
    Log(LOG_I, @"[diag] Codec preference resolved: pref=%d av1=%d hevc=%d hdr=%d yuv444=%d formats=0x%X",
        codecPreference,
        av1Supported ? 1 : 0,
        hevcSupported ? 1 : 0,
        (config.enableHdr || config.enable10BitSdr) ? 1 : 0,
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
    _streamConfig.dynamicHdrCaps = 0;
    _streamConfig.dolbyVisionDirectSurface = 0;
    // 0 automatic, 1 Dolby Vision, 2 HDR10+, 3 HDR10 only (host's dynamic_hdr_preference_e).
    _streamConfig.dynamicHdrPreference =
        (config.dynamicHdrPreference >= 0 && config.dynamicHdrPreference <= 3) ? config.dynamicHdrPreference : 0;
    if (config.enableHdr &&
        _streamConfig.dynamicRangeMode == DYNAMIC_RANGE_MODE_HDR10_PQ) {
        if (@available(macOS 13.0, *)) {
            // Core Media exposes the public HDR10+ per-frame metadata
            // attachment from macOS 13.
            _streamConfig.dynamicHdrCaps = DYNAMIC_HDR_CAPS_HDR10_PLUS;
        }
    }
    // Auto resolves to PQ above, so Dolby Vision follows the resolved mode
    // rather than requiring an explicit PQ/HLG choice. The host picks DV only
    // when its encoder can attach an RPU and falls back to HDR10/HDR10+.
    // Automatic with 4:4:4 keeps 4:4:4 and withholds Dolby Vision, which is
    // defined only for 4:2:0 (config.suppressDolbyVision).
    if (config.enableHdr && !config.suppressDolbyVision &&
        MLAppleDolbyVisionDirectSurfaceAvailable(config.hdrTargetDisplayID)) {
        if (_streamConfig.dynamicRangeMode == DYNAMIC_RANGE_MODE_HDR10_PQ) {
            _streamConfig.dynamicHdrCaps |= DYNAMIC_HDR_CAPS_DOLBY_VISION_81;
        } else if (_streamConfig.dynamicRangeMode == DYNAMIC_RANGE_MODE_HLG) {
            _streamConfig.dynamicHdrCaps |= DYNAMIC_HDR_CAPS_DOLBY_VISION_84;
        }
        _streamConfig.dolbyVisionDirectSurface = 1;
        Log(LOG_I, @"[hdr] Apple Dolby Vision direct-surface candidate enabled: dynamicRangeMode=%d caps=0x%x",
            _streamConfig.dynamicRangeMode,
            _streamConfig.dynamicHdrCaps);
    }
    {
        BOOL dolbyVisionOffered = (_streamConfig.dynamicHdrCaps &
            (DYNAMIC_HDR_CAPS_DOLBY_VISION_81 | DYNAMIC_HDR_CAPS_DOLBY_VISION_84)) != 0;
        Log(LOG_I, @"[hdr] Chroma/dynamic HDR decision: dynamicHdrPreference=%d hdr=%d codecPref=%d yuv444Requested=%d yuv444Effective=%d dolbyVisionOffered=%d dolbyVisionSuppressedForYuv444=%d yuv444DroppedForDolbyVision=%d dynamicHdrCaps=0x%x",
            _streamConfig.dynamicHdrPreference,
            config.enableHdr ? 1 : 0,
            config.videoCodecPreference,
            config.requestedYuv444 ? 1 : 0,
            config.enableYuv444 ? 1 : 0,
            dolbyVisionOffered ? 1 : 0,
            config.suppressDolbyVision ? 1 : 0,
            (config.requestedYuv444 && !config.enableYuv444) ? 1 : 0,
            _streamConfig.dynamicHdrCaps);
    }
    Log(LOG_I, @"[diag] Dynamic range resolved: hdr=%d tenBitSdr=%d tf=%d dynamicRangeMode=%d",
        config.enableHdr ? 1 : 0,
        config.enable10BitSdr ? 1 : 0,
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
    _drCallbacks.submitDecodeUnit = config.videoRendererMode == 2 ? DrSubmitDecodeUnit : NULL;

//#if TARGET_OS_IPHONE
    // RFI doesn't work properly with HEVC on iOS 11 with an iPhone SE (at least)
    // It doesnt work on macOS either, tested with Network Link Conditioner.
    _drCallbacks.capabilities = (config.videoRendererMode == 2 ? CAPABILITY_DIRECT_SUBMIT : CAPABILITY_PULL_RENDERER) |
                                CAPABILITY_REFERENCE_FRAME_INVALIDATION_HEVC |
                                CAPABILITY_REFERENCE_FRAME_INVALIDATION_AV1;
//#endif
    if ((_streamConfig.dynamicHdrCaps & DYNAMIC_HDR_CAPS_HDR10_PLUS) != 0) {
        // HDR10+ travels as a T.35 prefix SEI NAL unit. Without this flag the
        // depacketizer strips every prefix SEI, so VideoToolbox never sees the
        // per-frame metadata. The flag only affects HEVC; H.264 and AV1 are
        // unchanged, and the RPU NAL unit used by Dolby Vision is not an SEI.
        _drCallbacks.capabilities |= CAPABILITY_PRESERVE_HEVC_SEI;
        Log(LOG_I, @"[hdr] HEVC prefix SEI preservation enabled for HDR10+ dynamic metadata");
    }

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
    _clCallbacks.setHdrMode = ClSetHdrMode;
    _clCallbacks.connectionTerminated = ClConnectionTerminated;
    _clCallbacks.logMessage = ClLogMessage;
    _clCallbacks.rumble = ClRumble;
    _clCallbacks.rumbleTriggers = ClRumbleTriggers;
    _clCallbacks.setControllerLED = ClSetControllerLED;
    _clCallbacks.setAdaptiveTriggers = ClSetAdaptiveTriggers;
    _clCallbacks.setMotionEventState = ClSetMotionEventState;
    _clCallbacks.connectionStatusUpdate = ClConnectionStatusUpdate;
    _clCallbacks.clipboardItemReceived = ClClipboardItemReceived;
    _clCallbacks.clipboardDataReceived = ClClipboardDataReceived;
    _clCallbacks.resolutionChanged = ClResolutionChanged;
    _foundationHost = config.foundationHost;
    _wantsRemoteTextContext = config.wantsRemoteTextContext;
    // Foundation prioritizes PCM if both feature flags are set. Bluetooth
    // must request IR alone or it will never receive the analyzed frames.
    BOOL physicalDs5Audio = config.controllerHapticsMode == 0 &&
        [Ds5HapticsAudioRenderer hasPhysicalEndpoint];
    _clCallbacks.ds5HapticsPcm = physicalDs5Audio ? ClDs5HapticsPcm : NULL;
    _clCallbacks.ds5HapticsIrV2 = physicalDs5Audio ? NULL : ClDs5HapticsIrV2;
    Log(LOG_I, @"[controller-haptics] Negotiation mode=%@", physicalDs5Audio ? @"USB-PCM" : @"Bluetooth-IR-v2");

    return self;
}

- (void)bindLaunchResultWithSessionUrl:(NSString *)sessionUrl {
    // Only a host whose launch/resume succeeded leaves a trace in the settings; building the
    // connection ahead of the reply must not record anything for a launch that then fails.
    if (_audioHostKey.length > 0) {
        [SettingsClass recordFoundationHost:_foundationHost forHost:_audioHostKey];
    }

    if (sessionUrl != nil) {
        strncpy(_rtspSessionUrl, [sessionUrl UTF8String], sizeof(_rtspSessionUrl) - 1);
        _rtspSessionUrl[sizeof(_rtspSessionUrl) - 1] = '\0';
        _serverInfo.rtspSessionUrl = _rtspSessionUrl;
    }
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

- (BOOL)supportsLiveStreamChanges {
    return _foundationHost;
}

- (int)sendLiveStreamBitrateKbps:(int)kbps {
    [self ensureControlContextBacklink];
    int err = LiSendStreamBitrateCtx(&_connectionContext.controlContext, kbps);
    Log(LOG_I, @"[live] bitrate %d kbps -> result=%d", kbps, err);
    return err;
}

- (int)sendLiveStreamFramerate:(int)fps {
    [self ensureControlContextBacklink];
    int err = LiSendStreamFramerateCtx(&_connectionContext.controlContext, (float)fps);
    Log(LOG_I, @"[live] framerate %d fps -> result=%d", fps, err);
    return err;
}

- (int)sendLiveStreamResolutionWidth:(int)width height:(int)height {
    [self ensureControlContextBacklink];
    int err = LiSendStreamResolutionCtx(&_connectionContext.controlContext, width, height);
    Log(LOG_I, @"[live] resolution %dx%d -> result=%d", width, height, err);
    return err;
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

- (int)sendClipboardRawData:(NSData *)data {
    // The control stream packs payload lengths into a signed 16-bit field;
    // a longer frame wraps negative and aborts inside enet_malloc.
    if (data == nil || data.length == 0 || data.length > INT16_MAX - 64) {
        Log(LOG_W, @"[clipboard] Refusing raw agent frame length=%lu", (unsigned long)data.length);
        return -1;
    }

    Log(LOG_I, @"[clipboard] send raw agent frame length=%lu", (unsigned long)data.length);
    return [self performClipboardControlOperationNamed:@"send-raw"
                                                 block:^int {
        return LiSendClipboardData(data.bytes, (int)data.length);
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

- (BOOL)getNetworkStatsSnapshot:(MLNetworkStatsSnapshot *)snapshot {
    if (snapshot == NULL) {
        return NO;
    }

    memset(snapshot, 0, sizeof(*snapshot));
    [self ensureControlContextBacklink];

    // These are the per-context equivalents of LiGetRTPVideoStats(),
    // LiGetRTPVideoBytesReceived() and LiGetEstimatedVideoFrameLossPercentage();
    // the process-wide accessors would follow whichever connection is current.
    const RTP_VIDEO_STATS *rtp = &_connectionContext.videoContext.rtpQueue.stats;
    snapshot->videoPackets = rtp->packetCountVideo;
    snapshot->fecPackets = rtp->packetCountFec;
    snapshot->fecRecovered = rtp->packetCountFecRecovered;
    snapshot->fecFailed = rtp->packetCountFecFailed;
    snapshot->outOfSequence = rtp->packetCountOOS;
    snapshot->invalidPackets = rtp->packetCountInvalid + rtp->packetCountFecInvalid;
    snapshot->videoBytesReceived = atomic_load_explicit(&_connectionContext.videoContext.rtpVideoBytesReceived,
                                                        memory_order_relaxed);
    snapshot->networkFrameLossPercent = atomic_load_explicit(&_connectionContext.controlContext.lastIntervalLossBasisPoints,
                                                             memory_order_relaxed) / 100.0;

    uint32_t dataPackets = _connectionContext.videoContext.rtpQueue.bufferDataPackets;
    uint32_t parityPackets = _connectionContext.videoContext.rtpQueue.bufferParityPackets;
    if (dataPackets > 0) {
        snapshot->blockParityPercent = (parityPackets * 100 + dataPackets / 2) / dataPackets;
    }

    snapshot->fecFeedbackActive = LiGetFecFeedbackStatsCtx(&_connectionContext.controlContext,
                                                           &snapshot->fecFeedbackSequence,
                                                           &snapshot->fecFeedbackDataPackets,
                                                           &snapshot->fecFeedbackMissingPackets);
    return YES;
}

- (uint32_t)hostFeatureFlags {
    [self ensureControlContextBacklink];
    return LiGetHostFeatureFlagsCtx(&_connectionContext);
}

- (int)sendClientSdrWhiteNits:(float)nits {
    [self ensureControlContextBacklink];
    return LiSendClientSdrWhiteNitsCtx(&_connectionContext.controlContext, nits);
}

#if defined(LI_MIC_CONTROL_START)
- (void)startMicrophoneIfNeeded
{
    if (!_streamConfig.enableMic) {
        Log(LOG_I, @"Microphone disabled in settings, skipping mic start");
        return;
    }
    Log(LOG_I, @"Starting microphone capture...");

    _micSendFailures = 0;
    _micStopping = NO;
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
        return;
    }
}

- (void)drainMicPcmAndSend
{
    if (_micEncoder == NULL || _micStopping || !_streamConfig.enableMic) {
        return;
    }

    LiSetThreadConnectionContext(&_connectionContext);

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
    if (!_connectionLayoutCompatible) {
        id<ConnectionCallbacks> callbacks = ConnectionGetCallbacksSnapshot(self);
        [callbacks launchFailed:NSLocalizedString(@"Streaming components are incompatible. Please reinstall the app.", @"Connection component layout mismatch")];
        return;
    }
    os_unfair_lock_lock(&gConnectionLifecycleLock);
    LiSetThreadConnectionContext(&_connectionContext);
    // Advertising the remote text context makes the host stream caret updates,
    // so it is only requested when the local input method wants them.
    LiSetRemoteTextContextCallbackCtx(&_connectionContext, _wantsRemoteTextContext ? ClRemoteTextContext : NULL);
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
