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

/// Opens a decoder set up for the lowest delay: every frame comes out before the next goes in.
/// nil when the library refuses.
- (nullable instancetype)init NS_DESIGNATED_INITIALIZER;

/// Decodes one frame as the stream delivers it and returns the picture as a pixel buffer the
/// renderer can show (IOSurface backed, bi-planar 4:2:0 or 4:4:4, 8 or 10 bit, with its
/// colour description attached). NULL with *errorOut 0 when the data held no picture to show;
/// NULL with a negative *errorOut when decoding failed and a key frame is needed.
- (nullable CVPixelBufferRef)copyDecodedFrame:(const uint8_t *)data
                                        length:(size_t)length
                                         error:(int *)errorOut CF_RETURNS_RETAINED;

/// Drops what the decoder holds; the next frame must be a key frame.
- (void)flush;

@end

NS_ASSUME_NONNULL_END
