//
//  VideoDecoderRenderer.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import <Foundation/Foundation.h>

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
} VideoStats;

@interface VideoDecoderRenderer : NSObject

@property(nonatomic, readonly) VideoStats videoStats;
@property(nonatomic, readonly) int videoFormat;

- (id)initWithView:(OSView *)view;

- (void)setupWithVideoFormat:(int)videoFormat frameRate:(int)frameRate;
- (void)start;
- (void)stop;

- (int)submitDecodeBuffer:(unsigned char *)data
                   length:(int)length
               bufferType:(int)bufferType
                frameType:(int)frameType
                      pts:(unsigned int)pts;

- (int)submitDecodeUnit:(void *)du;

@end
