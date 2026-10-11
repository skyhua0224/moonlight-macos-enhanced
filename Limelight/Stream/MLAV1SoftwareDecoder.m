//
//  MLAV1SoftwareDecoder.m
//  Moonlight for macOS
//

#import "MLAV1SoftwareDecoder.h"

#import <VideoToolbox/VideoToolbox.h>
#include <dav1d/dav1d.h>
#include <errno.h>

BOOL MLAV1SoftwareDecodeNeeded(void)
{
    static BOOL needed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        needed = !VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1);
    });
    return needed;
}

// dav1d writes to stderr unless given a logger; the app has its own log and reports failures
// through the return values.
static void MLDav1dLogNothing(void *cookie, const char *format, va_list arguments)
{
    (void)cookie;
    (void)format;
    (void)arguments;
}

@implementation MLAV1SoftwareDecoder {
    Dav1dContext *_context;
    int _frameRate;
    BOOL _openFailed;
    CVPixelBufferPoolRef _pool;
    OSType _poolFormat;
    int _poolWidth;
    int _poolHeight;
}

+ (NSString *)libraryVersion
{
    return [NSString stringWithUTF8String:dav1d_version()];
}

- (instancetype)init
{
    return [self initWithFrameRate:60];
}

- (instancetype)initWithFrameRate:(int)frameRate
{
    self = [super init];
    if (self != nil) {
        _frameRate = frameRate > 0 ? frameRate : 60;
        // All cores: a stream has to be decoded as fast as it arrives.
        _threadCount = (int)MAX(1, MIN(NSProcessInfo.processInfo.activeProcessorCount, 16));
    }
    return self;
}

// How many frames to work on at a time, from how much picture arrives per second. One frame at
// a time adds no delay but only spreads a single frame over the cores; several at a time decode
// two to three times as much (measured on an M1 with a 4K stream: 148 pictures a second with
// one, 282 with two, 363 with four) and show each picture that many frames, less one, later.
// So: no delay where one frame at a time is enough, and throughput where it is not.
static int MLFrameDelayForStream(int width, int height, int frameRate)
{
    const double pixelsPerSecond = (double)width * (double)height * (double)MAX(frameRate, 1);
    if (pixelsPerSecond <= 1920.0 * 1080.0 * 62.0) {
        return 1;
    }
    if (pixelsPerSecond <= 2560.0 * 1440.0 * 62.0) {
        return 2;
    }
    return 4;
}

// Opens the decoder for the stream this first frame belongs to. NO: no decoder (the data has no
// sequence header yet, or the library refuses).
- (BOOL)openForFirstFrame:(const uint8_t *)bytes length:(size_t)length
{
    Dav1dSequenceHeader sequence;
    if (dav1d_parse_sequence_header(&sequence, bytes, length) < 0) {
        return NO;
    }

    Dav1dSettings settings;
    dav1d_default_settings(&settings);
    settings.n_threads = _threadCount;
    settings.max_frame_delay = MIN(MLFrameDelayForStream(sequence.max_width, sequence.max_height, _frameRate), _threadCount);
    // A stream has one layer; without this the decoder would output each layer of one that had more.
    settings.all_layers = 0;
    settings.logger.callback = MLDav1dLogNothing;

    if (dav1d_open(&_context, &settings) < 0) {
        _context = NULL;
        _openFailed = YES;
        return NO;
    }
    _frameDelay = settings.max_frame_delay;
    return YES;
}

- (void)dealloc
{
    if (_context != NULL) {
        dav1d_close(&_context);
    }
    if (_pool != NULL) {
        CVPixelBufferPoolRelease(_pool);
    }
}

- (void)flush
{
    if (_context != NULL) {
        dav1d_flush(_context);
    }
}

#pragma mark - Pixel buffers

static OSType MLPixelFormatForPicture(const Dav1dPicture *picture)
{
    const BOOL fullRange = picture->seq_hdr != NULL && picture->seq_hdr->color_range != 0;
    const BOOL chroma444 = picture->p.layout == DAV1D_PIXEL_LAYOUT_I444;
    if (picture->p.layout == DAV1D_PIXEL_LAYOUT_I422) {
        return 0;
    }
    switch (picture->p.bpc) {
        case 8:
            if (chroma444) {
                return fullRange ? kCVPixelFormatType_444YpCbCr8BiPlanarFullRange : kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange;
            }
            return fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        case 10:
            if (chroma444) {
                return fullRange ? kCVPixelFormatType_444YpCbCr10BiPlanarFullRange : kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange;
            }
            return fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
        default:
            return 0;
    }
}

- (CVPixelBufferRef)newPixelBufferWithFormat:(OSType)format width:(int)width height:(int)height CF_RETURNS_RETAINED
{
    if (_pool == NULL || _poolFormat != format || _poolWidth != width || _poolHeight != height) {
        if (_pool != NULL) {
            CVPixelBufferPoolRelease(_pool);
            _pool = NULL;
        }
        NSDictionary *attributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(format),
            (id)kCVPixelBufferWidthKey: @(width),
            (id)kCVPixelBufferHeightKey: @(height),
            // What the display layer and the Metal renderer take without a copy.
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        };
        if (CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attributes, &_pool) != kCVReturnSuccess) {
            _pool = NULL;
            return NULL;
        }
        _poolFormat = format;
        _poolWidth = width;
        _poolHeight = height;
    }
    CVPixelBufferRef buffer = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &buffer) != kCVReturnSuccess) {
        return NULL;
    }
    return buffer;
}

// The decoder's planes are separate (Y, U, V); the pixel buffer wants Y and one plane of U and V
// in turns. Ten bit samples sit in the low bits of 16 on the decoder's side and in the high
// bits on the pixel buffer's. These loops are plain on purpose: the compiler turns each into
// vector code on both architectures.
static void MLCopyLuma8(uint8_t *restrict dst, ptrdiff_t dstStride, const uint8_t *restrict src, ptrdiff_t srcStride, int width, int height)
{
    for (int y = 0; y < height; y++) {
        memcpy(dst, src, (size_t)width);
        dst += dstStride;
        src += srcStride;
    }
}

static void MLInterleaveChroma8(uint8_t *restrict dst, ptrdiff_t dstStride, const uint8_t *restrict u, const uint8_t *restrict v, ptrdiff_t srcStride, int width, int height)
{
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            dst[2 * x] = u[x];
            dst[2 * x + 1] = v[x];
        }
        dst += dstStride;
        u += srcStride;
        v += srcStride;
    }
}

static void MLCopyLuma10(uint16_t *restrict dst, ptrdiff_t dstStride, const uint16_t *restrict src, ptrdiff_t srcStride, int width, int height)
{
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            dst[x] = (uint16_t)(src[x] << 6);
        }
        dst = (uint16_t *)((uint8_t *)dst + dstStride);
        src = (const uint16_t *)((const uint8_t *)src + srcStride);
    }
}

static void MLInterleaveChroma10(uint16_t *restrict dst, ptrdiff_t dstStride, const uint16_t *restrict u, const uint16_t *restrict v, ptrdiff_t srcStride, int width, int height)
{
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            dst[2 * x] = (uint16_t)(u[x] << 6);
            dst[2 * x + 1] = (uint16_t)(v[x] << 6);
        }
        dst = (uint16_t *)((uint8_t *)dst + dstStride);
        u = (const uint16_t *)((const uint8_t *)u + srcStride);
        v = (const uint16_t *)((const uint8_t *)v + srcStride);
    }
}

static void MLFillChroma(uint8_t *dst, ptrdiff_t dstStride, int widthBytes, int height, int bpc)
{
    // A picture without colour planes: the middle value is no colour.
    for (int y = 0; y < height; y++) {
        if (bpc == 8) {
            memset(dst, 0x80, (size_t)widthBytes);
        } else {
            uint16_t *row = (uint16_t *)dst;
            for (int x = 0; x < widthBytes / 2; x++) {
                row[x] = 0x8000;
            }
        }
        dst += dstStride;
    }
}

// Tells the renderer what the samples mean, as the hardware decoder does for its pictures.
static void MLAttachColorDescription(CVPixelBufferRef buffer, const Dav1dPicture *picture)
{
    const Dav1dSequenceHeader *sequence = picture->seq_hdr;
    int primaries = sequence != NULL ? (int)sequence->pri : 2;
    int transfer = sequence != NULL ? (int)sequence->trc : 2;
    int matrix = sequence != NULL ? (int)sequence->mtrx : 2;
    // 2 is "unspecified": a stream that does not say is BT.709, the SDR default.
    if (primaries == 2) primaries = 1;
    if (transfer == 2) transfer = 1;
    if (matrix == 2) matrix = 1;

    CFStringRef primariesName = CVColorPrimariesGetStringForIntegerCodePoint(primaries);
    CFStringRef transferName = CVTransferFunctionGetStringForIntegerCodePoint(transfer);
    CFStringRef matrixName = CVYCbCrMatrixGetStringForIntegerCodePoint(matrix);
    if (primariesName != NULL) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primariesName, kCVAttachmentMode_ShouldPropagate);
    }
    if (transferName != NULL) {
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transferName, kCVAttachmentMode_ShouldPropagate);
    }
    if (matrixName != NULL) {
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrixName, kCVAttachmentMode_ShouldPropagate);
    }
    CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left, kCVAttachmentMode_ShouldPropagate);

    // HDR10 static metadata, in the byte layout of the HEVC messages the keys are defined by.
    if (picture->mastering_display != NULL) {
        const Dav1dMasteringDisplay *display = picture->mastering_display;
        uint8_t bytes[24];
        size_t offset = 0;
        // Chromaticities are 0.16 fixed point here and steps of 0.00002 there; the order there is G, B, R.
        static const int order[3] = { 1, 2, 0 };
        for (int i = 0; i < 3; i++) {
            for (int axis = 0; axis < 2; axis++) {
                const uint16_t value = (uint16_t)lrint(display->primaries[order[i]][axis] / 65536.0 * 50000.0);
                bytes[offset++] = (uint8_t)(value >> 8);
                bytes[offset++] = (uint8_t)value;
            }
        }
        for (int axis = 0; axis < 2; axis++) {
            const uint16_t value = (uint16_t)lrint(display->white_point[axis] / 65536.0 * 50000.0);
            bytes[offset++] = (uint8_t)(value >> 8);
            bytes[offset++] = (uint8_t)value;
        }
        // Luminance is 24.8 and 18.14 fixed point here and steps of 0.0001 cd/m2 there.
        const uint32_t maxLuminance = (uint32_t)llrint(display->max_luminance / 256.0 * 10000.0);
        const uint32_t minLuminance = (uint32_t)llrint(display->min_luminance / 16384.0 * 10000.0);
        const uint32_t luminance[2] = { maxLuminance, minLuminance };
        for (int i = 0; i < 2; i++) {
            bytes[offset++] = (uint8_t)(luminance[i] >> 24);
            bytes[offset++] = (uint8_t)(luminance[i] >> 16);
            bytes[offset++] = (uint8_t)(luminance[i] >> 8);
            bytes[offset++] = (uint8_t)luminance[i];
        }
        CFDataRef data = CFDataCreate(kCFAllocatorDefault, bytes, sizeof(bytes));
        if (data != NULL) {
            CVBufferSetAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, data, kCVAttachmentMode_ShouldPropagate);
            CFRelease(data);
        }
    }
    if (picture->content_light != NULL) {
        const Dav1dContentLightLevel *light = picture->content_light;
        const uint8_t bytes[4] = {
            (uint8_t)(light->max_content_light_level >> 8), (uint8_t)light->max_content_light_level,
            (uint8_t)(light->max_frame_average_light_level >> 8), (uint8_t)light->max_frame_average_light_level,
        };
        CFDataRef data = CFDataCreate(kCFAllocatorDefault, bytes, sizeof(bytes));
        if (data != NULL) {
            CVBufferSetAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, data, kCVAttachmentMode_ShouldPropagate);
            CFRelease(data);
        }
    }
}

- (CVPixelBufferRef)newPixelBufferFromPicture:(const Dav1dPicture *)picture CF_RETURNS_RETAINED
{
    const OSType format = MLPixelFormatForPicture(picture);
    if (format == 0) {
        return NULL;
    }
    const int width = picture->p.w;
    const int height = picture->p.h;
    CVPixelBufferRef buffer = [self newPixelBufferWithFormat:format width:width height:height];
    if (buffer == NULL) {
        return NULL;
    }
    if (CVPixelBufferLockBaseAddress(buffer, 0) != kCVReturnSuccess) {
        CVPixelBufferRelease(buffer);
        return NULL;
    }

    const BOOL wide = picture->p.bpc > 8;
    const BOOL chroma444 = picture->p.layout == DAV1D_PIXEL_LAYOUT_I444;
    const int chromaWidth = chroma444 ? width : (width + 1) / 2;
    const int chromaHeight = chroma444 ? height : (height + 1) / 2;

    uint8_t *lumaDst = CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
    const ptrdiff_t lumaDstStride = (ptrdiff_t)CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
    uint8_t *chromaDst = CVPixelBufferGetBaseAddressOfPlane(buffer, 1);
    const ptrdiff_t chromaDstStride = (ptrdiff_t)CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
    // The pixel buffer rounds an odd chroma size its own way; never write past what it holds.
    const int chromaRows = (int)MIN((size_t)chromaHeight, CVPixelBufferGetHeightOfPlane(buffer, 1));
    const int chromaColumns = (int)MIN((size_t)chromaWidth, CVPixelBufferGetWidthOfPlane(buffer, 1));

    // A 4K picture is 12 MB to move; in stripes on several cores it takes a fraction of the
    // time, which counts at 120 pictures a second. Small pictures go in one piece.
    const int stripes = height >= 1440 ? 4 : 1;
    const uint8_t *lumaSrc = picture->data[0];
    const uint8_t *uSrc = picture->data[1];
    const uint8_t *vSrc = picture->data[2];
    const ptrdiff_t lumaSrcStride = picture->stride[0];
    const ptrdiff_t chromaSrcStride = picture->stride[1];
    const BOOL monochrome = picture->p.layout == DAV1D_PIXEL_LAYOUT_I400;
    const int bpc = picture->p.bpc;
    dispatch_apply((size_t)stripes, DISPATCH_APPLY_AUTO, ^(size_t stripe) {
        const int lumaFrom = (int)((int64_t)height * (int64_t)stripe / stripes);
        const int lumaTo = (int)((int64_t)height * (int64_t)(stripe + 1) / stripes);
        const int chromaFrom = (int)((int64_t)chromaRows * (int64_t)stripe / stripes);
        const int chromaTo = (int)((int64_t)chromaRows * (int64_t)(stripe + 1) / stripes);
        uint8_t *lumaTarget = lumaDst + lumaDstStride * lumaFrom;
        uint8_t *chromaTarget = chromaDst + chromaDstStride * chromaFrom;
        if (wide) {
            MLCopyLuma10((uint16_t *)lumaTarget, lumaDstStride, (const uint16_t *)(lumaSrc + lumaSrcStride * lumaFrom), lumaSrcStride, width, lumaTo - lumaFrom);
        } else {
            MLCopyLuma8(lumaTarget, lumaDstStride, lumaSrc + lumaSrcStride * lumaFrom, lumaSrcStride, width, lumaTo - lumaFrom);
        }
        if (monochrome) {
            MLFillChroma(chromaTarget, chromaDstStride, chromaColumns * 2 * (wide ? 2 : 1), chromaTo - chromaFrom, bpc);
        } else if (wide) {
            MLInterleaveChroma10((uint16_t *)chromaTarget, chromaDstStride,
                                 (const uint16_t *)(uSrc + chromaSrcStride * chromaFrom), (const uint16_t *)(vSrc + chromaSrcStride * chromaFrom),
                                 chromaSrcStride, chromaColumns, chromaTo - chromaFrom);
        } else {
            MLInterleaveChroma8(chromaTarget, chromaDstStride, uSrc + chromaSrcStride * chromaFrom, vSrc + chromaSrcStride * chromaFrom,
                                chromaSrcStride, chromaColumns, chromaTo - chromaFrom);
        }
    });

    CVPixelBufferUnlockBaseAddress(buffer, 0);
    MLAttachColorDescription(buffer, picture);
    return buffer;
}

#pragma mark - Decoding

- (CVPixelBufferRef)copyDecodedFrame:(const uint8_t *)bytes
                              length:(size_t)length
                                 tag:(int64_t)tag
                              tagOut:(int64_t *)tagOut
                               error:(int *)errorOut
{
    if (errorOut != NULL) {
        *errorOut = 0;
    }
    if (bytes == NULL || length == 0 || _openFailed) {
        if (errorOut != NULL) *errorOut = -EINVAL;
        return NULL;
    }
    if (_context == NULL && ![self openForFirstFrame:bytes length:length]) {
        // Not a key frame (no sequence header to size the decoder by): ask for one.
        if (errorOut != NULL) *errorOut = -EINVAL;
        return NULL;
    }

    // The decoder keeps the data while it works on it, so it gets a buffer of its own.
    Dav1dData data = { 0 };
    uint8_t *copy = dav1d_data_create(&data, length);
    if (copy == NULL) {
        if (errorOut != NULL) *errorOut = -ENOMEM;
        return NULL;
    }
    memcpy(copy, bytes, length);
    // Comes back with the picture this frame becomes.
    data.m.timestamp = tag;

    Dav1dPicture shown = { 0 };
    BOOL haveShown = NO;
    int failure = 0;

    // Hand the data over and take what comes out, until all of it is consumed. With a frame
    // delay of one the picture of this frame is out by then.
    while (data.sz > 0 && failure == 0) {
        const int sent = dav1d_send_data(_context, &data);
        if (sent < 0 && sent != DAV1D_ERR(EAGAIN)) {
            failure = sent;
            break;
        }
        Dav1dPicture picture = { 0 };
        const int got = dav1d_get_picture(_context, &picture);
        if (got == 0) {
            if (haveShown) {
                dav1d_picture_unref(&shown);
            }
            shown = picture;
            haveShown = YES;
        } else if (got != DAV1D_ERR(EAGAIN)) {
            failure = got;
        } else if (sent == DAV1D_ERR(EAGAIN)) {
            // Nothing went in and nothing came out: do not spin.
            failure = sent;
        }
    }
    if (data.sz > 0) {
        dav1d_data_unref(&data);
    }
    if (failure == 0 && !haveShown) {
        Dav1dPicture picture = { 0 };
        const int got = dav1d_get_picture(_context, &picture);
        if (got == 0) {
            shown = picture;
            haveShown = YES;
        } else if (got != DAV1D_ERR(EAGAIN)) {
            failure = got;
        }
    }

    if (failure != 0) {
        if (haveShown) {
            dav1d_picture_unref(&shown);
        }
        if (errorOut != NULL) *errorOut = failure;
        return NULL;
    }
    if (!haveShown) {
        return NULL;
    }

    if (tagOut != NULL) {
        *tagOut = shown.m.timestamp;
    }
    CVPixelBufferRef buffer = [self newPixelBufferFromPicture:&shown];
    dav1d_picture_unref(&shown);
    if (buffer == NULL && errorOut != NULL) {
        *errorOut = -ENOTSUP;
    }
    return buffer;
}

@end
