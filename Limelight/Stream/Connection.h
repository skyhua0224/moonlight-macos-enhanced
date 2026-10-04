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
- (uint64_t)audioUnderrunCount;
- (void)notifyInputStreamReadyForMicrophoneControlIfNeeded;
- (void)terminate;
- (void)main;

@end
