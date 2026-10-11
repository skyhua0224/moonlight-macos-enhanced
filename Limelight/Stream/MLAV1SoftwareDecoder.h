//
//  MLAV1SoftwareDecoder.h
//  Moonlight for macOS
//
//  AV1 decoding in software, for Macs whose chip has no AV1 hardware decoder (everything
//  before Apple M3). The system offers no software AV1 decoder to apps, so this uses dav1d.
//

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// YES when AV1 has to be decoded in software on this Mac.
FOUNDATION_EXPORT BOOL MLAV1SoftwareDecodeNeeded(void);

@interface MLAV1SoftwareDecoder : NSObject

/// The version of the dav1d library in the app.
@property (class, nonatomic, readonly) NSString *libraryVersion;

/// Threads the decoder works with.
@property (nonatomic, readonly) int threadCount;

/// Frames the decoder works on at a time; a picture comes out this many frames, less one,
/// after its data went in. 0 until the first frame was seen.
@property (nonatomic, readonly) int frameDelay;

/// frameRate is what the stream was asked to deliver. Together with the size found in the
/// first frame it decides how many frames are decoded at a time: one where that keeps up
/// (no added delay), several for large, fast streams, which one frame at a time cannot follow.
- (instancetype)initWithFrameRate:(int)frameRate NS_DESIGNATED_INITIALIZER;
- (instancetype)init;

/// Takes one frame as the stream delivers it and returns the next finished picture as a pixel
/// buffer the renderer can show (IOSurface backed, bi-planar 4:2:0 or 4:4:4, 8 or 10 bit, with
/// its colour description attached). With a frame delay above one that is the picture of an
/// earlier frame: *tagOut is the tag that frame was handed in with. NULL with *errorOut 0 when
/// no picture is ready yet; NULL with a negative *errorOut when decoding failed and a key
/// frame is needed.
- (nullable CVPixelBufferRef)copyDecodedFrame:(const uint8_t *)data
                                        length:(size_t)length
                                           tag:(int64_t)tag
                                        tagOut:(nullable int64_t *)tagOut
                                         error:(int *)errorOut CF_RETURNS_RETAINED;

/// Drops what the decoder holds; the next frame must be a key frame.
- (void)flush;

@end

NS_ASSUME_NONNULL_END
