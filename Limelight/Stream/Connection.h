//
//  Connection.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "StreamConfiguration.h"
#import "VideoDecoderRenderer.h"
#import "Limelight.h"

@protocol ConnectionCallbacks <NSObject>

- (void)connectionStarted;
- (void)connectionTerminated:(int)errorCode;
- (void)stageStarting:(const char *)stageName;
- (void)stageComplete:(const char *)stageName;
- (void)stageFailed:(const char *)stageName withError:(int)errorCode;
- (void)launchFailed:(NSString *)message;
- (void)rumble:(unsigned short)controllerNumber
     lowFreqMotor:(unsigned short)lowFreqMotor
    highFreqMotor:(unsigned short)highFreqMotor;
- (void)connectionStatusUpdate:(int)status;

@optional
- (void)rumbleTriggers:(unsigned short)controllerNumber
      leftTriggerMotor:(unsigned short)leftTriggerMotor
     rightTriggerMotor:(unsigned short)rightTriggerMotor;
- (void)setControllerLED:(unsigned short)controllerNumber
                       red:(unsigned char)red
                     green:(unsigned char)green
                      blue:(unsigned char)blue;
- (void)setAdaptiveTriggers:(unsigned short)controllerNumber
                 eventFlags:(unsigned char)eventFlags
                   typeLeft:(unsigned char)typeLeft
                  typeRight:(unsigned char)typeRight
                       left:(const unsigned char *)left
                      right:(const unsigned char *)right;
- (void)setMotionEventState:(unsigned short)controllerNumber
                  motionType:(unsigned char)motionType
                reportRateHz:(unsigned short)reportRateHz;
- (void)clipboardItemReceived:(const LI_CLIPBOARD_ITEM *)item;
- (void)clipboardDataReceived:(const uint8_t *)data length:(uint32_t)length;
- (void)ds5HapticsPcm:(const LI_DS5_HAPTICS_PCM_FRAME *)frame;
- (void)ds5HapticsIrV2:(const LI_DS5_HAPTICS_IR_FRAME_V2 *)frame;
// The host reconfigured the stream resolution (display rotation or a runtime resolution change).
- (void)streamResolutionChanged:(uint32_t)width height:(uint32_t)height;
// Host text focus / caret updates, only delivered when wantsRemoteTextContext is set.
- (void)remoteTextContextUpdated:(const LI_REMOTE_TEXT_CONTEXT *)context;

@end

typedef struct {
    int appVersionMajor;
    int appVersionMinor;
    int appVersionPatch;
    BOOL videoReceivedDataFromPeer;
    BOOL videoReceivedFullFrame;
    int videoRtpSocketValid;
    uint32_t videoCurrentFrameNumber;
    uint32_t videoMissingPackets;
    uint32_t videoPendingFecBlocks;
    uint32_t videoCompletedFecBlocks;
    uint32_t videoBufferDataPackets;
    uint32_t videoBufferParityPackets;
    uint32_t videoReceivedDataPackets;
    uint32_t videoReceivedParityPackets;
    uint32_t videoReceivedHighestSequenceNumber;
    uint32_t videoNextContiguousSequenceNumber;
} MLVideoDiagnosticSnapshot;

// Cumulative RTP video counters plus the network frame loss rate common-c
// derives over its 3 second sampling window. Counters reset with the stream.
typedef struct {
    uint32_t videoPackets;
    uint32_t fecPackets;
    uint32_t fecRecovered;
    uint32_t fecFailed;
    uint32_t outOfSequence;
    uint32_t invalidPackets;
    uint64_t videoBytesReceived;
    double networkFrameLossPercent;
    // Parity share of the RS block currently being assembled (0 when idle).
    uint32_t blockParityPercent;
    // 0x5510 aggregate feedback; valid only when the host accepted FEC control.
    BOOL fecFeedbackActive;
    uint32_t fecFeedbackSequence;
    uint32_t fecFeedbackDataPackets;
    uint32_t fecFeedbackMissingPackets;
} MLNetworkStatsSnapshot;

// YES when Dolby Vision can be decoded and shown directly on the given display
// (0 = the main screen). Used both to decide whether to offer Dolby Vision to
// the host and, together with the chroma policy, whether 4:4:4 must be dropped.
BOOL MLAppleDolbyVisionDirectSurfaceAvailable(unsigned int targetDisplayID);

@interface Connection : NSOperation <NSStreamDelegate>

// Returns the connection bound to the current thread context, if any.
+ (Connection *)currentConnection;

@property(nonatomic, readonly) VideoDecoderRenderer *renderer;

- (id)initWithConfig:(StreamConfiguration *)config
               renderer:(VideoDecoderRenderer *)myRenderer
    connectionCallbacks:(id<ConnectionCallbacks>)callbacks;
- (void *)inputStreamContext;
- (void *)controlStreamContext;
- (BOOL)isClipboardControlReady;
- (NSString *)clipboardControlReadinessReason;
- (uint32_t)clipboardHostFeatureFlags;
// YES when the running session can take bitrate / frame rate / resolution changes without a reconnect.
- (BOOL)supportsLiveStreamChanges;
// These return LI_DYNAMIC_SDR_WHITE_OK (0) when the host was sent the change.
- (int)sendLiveStreamBitrateKbps:(int)kbps;
- (int)sendLiveStreamFramerate:(int)fps;
- (int)sendLiveStreamResolutionWidth:(int)width height:(int)height;
- (NSString *)clipboardControlDebugSummary;
- (int)bindClipboardSession;
- (int)unbindClipboardSession;
- (int)requestClipboardSnapshot;
- (int)sendClipboardItemData:(NSData *)data
                        type:(uint8_t)type
                    mimeType:(NSString *)mimeType
                        name:(NSString *)name
                      itemId:(uint64_t)itemId
                 contentHash:(uint64_t)contentHash;
- (int)sendClipboardRawData:(NSData *)data;
- (BOOL)getVideoDiagnosticSnapshot:(MLVideoDiagnosticSnapshot *)snapshot;
- (BOOL)getNetworkStatsSnapshot:(MLNetworkStatsSnapshot *)snapshot;
// Host extended feature flags (LI_FF_*); 0 until the control stream is up.
- (uint32_t)hostFeatureFlags;
// Sends the client SDR reference white. Returns an LI_DYNAMIC_SDR_WHITE_* code.
- (int)sendClientSdrWhiteNits:(float)nits;
- (uint64_t)audioUnderrunCount;
- (void)terminate;
- (void)main;

@end
