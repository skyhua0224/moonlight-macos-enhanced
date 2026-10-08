//
//  VideoDecoderRenderer.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import <Foundation/Foundation.h>
#include "Limelight.h"

#import "StreamConfiguration.h"

@import AVFoundation;

typedef struct {
  uint32_t receivedFrames;
  uint32_t decodedFrames;
  uint32_t renderedFrames;
  uint32_t totalFrames;
  uint32_t networkDroppedFrames;
  uint32_t pacerDroppedFrames;
  uint64_t totalReassemblyTime;
  uint64_t totalDecodeTime;
  uint64_t totalPacerTime;
  uint64_t totalRenderTime;
  uint64_t totalHostProcessingLatency;
  uint32_t framesWithHostProcessingLatency;

  float totalFps;
  float receivedFps;
  float decodedFps;
  float renderedFps;

  uint64_t measurementStartTimestamp;
  uint64_t lastUpdatedTimestamp;

  // Bytes of video payload received during this measurement window.
  // Can be used to estimate current bitrate.
  uint64_t receivedBytes;

  // RFC3550-style inter-arrival jitter estimate (ms) derived from frame
  // receiveTimeMs and presentationTimeMs deltas.
  float jitterMs;

  // Rolling 1% low FPS derived from recent rendered frame intervals.
  float renderedFpsOnePercentLow;

  // Population standard deviation of recent rendered frame intervals (ms).
  // This is a display-side frame pacing metric and is separate from the
  // RFC3550-style network inter-arrival jitter above.
  float renderFramePacingJitterMs;
} VideoStats;

@interface VideoDecoderRenderer : NSObject

@property(nonatomic, assign) void *depacketizerContext;
@property(nonatomic) BOOL directSubmission;

@property(nonatomic, readonly) VideoStats videoStats;
@property(nonatomic, readonly) BOOL hasPresentedVideo;
@property(nonatomic, readonly) int videoFormat;

- (id)initWithView:(OSView *)view;
- (void)updateHostHDRMetadata:(const SS_HDR_METADATA *)metadata;

- (void)prewarmPresentationForStreamConfig:(StreamConfiguration *)streamConfig;
- (void)setupWithVideoFormat:(int)videoFormat
                   frameRate:(int)frameRate
               upscalingMode:(int)upscalingMode
                streamConfig:(StreamConfiguration *)streamConfig;
- (void)start;
- (void)stop;

- (int)submitDecodeBuffer:(unsigned char *)data
                   length:(int)length
               bufferType:(int)bufferType
                frameType:(int)frameType
                      pts:(unsigned int)pts;

- (int)submitDecodeUnit:(void *)du;

@end
