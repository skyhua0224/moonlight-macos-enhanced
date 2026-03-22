//
//  Connection.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "StreamConfiguration.h"
#import "VideoDecoderRenderer.h"

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
- (BOOL)getVideoDiagnosticSnapshot:(MLVideoDiagnosticSnapshot *)snapshot;
- (void)terminate;
- (void)main;

@end
