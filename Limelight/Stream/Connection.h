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

@interface Connection : NSOperation <NSStreamDelegate>

// Returns the connection bound to the current thread context, if any.
+ (Connection *)currentConnection;

@property(nonatomic, readonly) VideoDecoderRenderer *renderer;

- (id)initWithConfig:(StreamConfiguration *)config
               renderer:(VideoDecoderRenderer *)myRenderer
    connectionCallbacks:(id<ConnectionCallbacks>)callbacks;
- (void *)inputStreamContext;
- (void *)controlStreamContext;
- (void)terminate;
- (void)main;

@end
