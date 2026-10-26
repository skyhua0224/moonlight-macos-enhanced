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

  // Rolling 1% low FPS over frames that arrived on cadence (~30 s window);
  // frames already late on arrival are counted in renderSourceGapCount.
  float renderedFpsOnePercentLow;

  // Standard deviation (ms) of render interval minus arrival interval: the
  // pacing jitter the client adds. Separate from network jitterMs above.
  float renderFramePacingJitterMs;

  // Raw rendered intervals over the same window, as the viewer saw them.
  float renderIntervalP99Ms;
  float renderIntervalMaxMs;
  uint32_t renderStallCount;      // intervals over 100 ms
  uint32_t renderSourceGapCount;  // frames that arrived late (host idle / network)
} VideoStats;

// Client SDR reference white as seen by the HDR presenter, plus the display
// state it was derived from so callers can tell when to re-evaluate it.
typedef struct {
  float nits;
  uint32_t displayId;
  float currentEDR;
  float potentialEDR;
  BOOL edrCapable;
} MLClientSdrWhite;

@interface VideoDecoderRenderer : NSObject

@property(nonatomic, assign) void *depacketizerContext;
@property(nonatomic) BOOL directSubmission;
@property(nonatomic) BOOL presentationSuspended;
/// Fill the view without keeping the picture's aspect ratio (Picture Aspect: Stretch to Fill).
@property(atomic) BOOL stretchToFill;

@property(nonatomic, readonly) VideoStats videoStats;
@property(nonatomic, readonly) BOOL hasPresentedVideo;
// LiGetMillis() when the first video data reached the decoder / when the first frame counted
// as rendered (the moment hasPresentedVideo turns true); 0 until then.
@property(nonatomic, readonly) uint64_t firstDecodeInputMs;
@property(nonatomic, readonly) uint64_t firstFramePresentedMs;
// Called once, on an arbitrary thread, when the first frame counts as rendered. Not called
// when that already happened before it was set; check hasPresentedVideo after setting it.
@property(copy) void (^firstFramePresentedHandler)(void);
// Called on the main queue when a decoded frame has a different size than the one before
// (the first frame included), with that size in pixels.
@property(copy) void (^decodedSizeChangedHandler)(CGSize size);
// The last decoded frame as an image no wider than maxWidth, or NULL before the first one.
// Safe on any thread; the caller releases the image.
- (CGImageRef)copyLastFrameImageWithMaxWidth:(CGFloat)maxWidth CF_RETURNS_RETAINED;
@property(nonatomic, readonly) int videoFormat;

- (id)initWithView:(OSView *)view;
- (void)updateHostHDRMetadata:(const SS_HDR_METADATA *)metadata;
- (void)updateHostHDRMode:(BOOL)enabled metadata:(const SS_HDR_METADATA *)metadata;
// Main thread only. Returns NO while the stream is not presenting HDR.
- (BOOL)copyClientSdrWhite:(MLClientSdrWhite *)sdrWhite;

- (void)prewarmPresentationForStreamConfig:(StreamConfiguration *)streamConfig;
- (void)setupWithVideoFormat:(int)videoFormat
                   frameRate:(int)frameRate
               upscalingMode:(int)upscalingMode
                streamConfig:(StreamConfiguration *)streamConfig;
// The host accepted a runtime frame rate / bitrate change; keep pacing and stats in step.
- (void)updateLiveStreamFrameRate:(int)frameRate bitrateKbps:(int)bitrateKbps;
- (void)start;
- (void)stop;

- (int)submitDecodeBuffer:(unsigned char *)data
                   length:(int)length
               bufferType:(int)bufferType
                frameType:(int)frameType
                      pts:(unsigned int)pts;

- (int)submitDecodeUnit:(void *)du;

@end
