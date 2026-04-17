//
//  VideoDecoderRenderer.m
//  Moonlight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "VideoDecoderRenderer.h"
#include "Limelight-internal.h"
#import "RendererLayerContainer.h"

#include "Limelight.h"
#include <math.h>
#include <pthread.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include <libavcodec/avcodec.h>
#include <libavcodec/cbs.h>
#include <libavcodec/cbs_av1.h>
#include <libavformat/avio.h>
#include <libavutil/mem.h>
#pragma clang diagnostic pop
#import "Moonlight-Swift.h"

@import VideoToolbox;
@import MetalKit;

#if __has_include(<MetalFX/MetalFX.h>)
#import <MetalFX/MetalFX.h>
#define ML_HAS_METALFX 1
#else
#define ML_HAS_METALFX 0
@protocol MTLFXSpatialScaler;
@end
#endif

extern int ff_isom_write_av1c(AVIOContext *pb, const uint8_t *buf, int size,
                              int write_seq_header);

typedef struct MLDecodeFrameContext MLDecodeFrameContext;

@interface VideoDecoderRenderer () <MTKViewDelegate>
@property (nonatomic) int frameRate;
- (void)resetVideoParameterSetState;
- (BOOL)loadSharedMetalPipelineForPixelFormat:(MTLPixelFormat)pixelFormat
                                        error:(NSError **)errorOut;
- (BOOL)currentDisplayHasActiveEDRHeadroom;
- (BOOL)currentDisplaySupportsEDRPresentation;
- (void)prewarmEnhancedDrawableIfNeeded;
- (void)refreshEnhancedHDRPresentationIfNeeded;
- (void)handleDecompressionOutput:(CVImageBufferRef)imageBuffer
            presentationTimeStamp:(CMTime)presentationTimeStamp
                         duration:(CMTime)duration
                     frameContext:(const MLDecodeFrameContext *)frameContext;
- (void)recordRenderedFrameSampleAtTimeMs:(uint64_t)renderSampleNowMs
                            enqueueTimeMs:(uint64_t)enqueueTimeMs;
- (NSUInteger)desiredEnhancedDrawableDepth;
- (void)teardownFrameInterpolationProcessor;
- (BOOL)ensureFrameInterpolationOutputPoolForConfiguration:(VTLowLatencyFrameInterpolationConfiguration *)configuration
                                         sourcePixelFormat:(OSType)sourcePixelFormat API_AVAILABLE(macos(26.0));
- (void)requestFrameInterpolationWarmupForStreamWidth:(NSInteger)streamWidth
                                         streamHeight:(NSInteger)streamHeight;
- (void)resolveHDRLuminanceFromHostMetadata:(const SS_HDR_METADATA *)hostHdrMetadata
                             hasHostMetadata:(BOOL)hasHostHdrMetadata
                                minLuminance:(float *)minOut
                                maxLuminance:(float *)maxOut
                      maxAverageLuminance:(float *)maxAverageOut;
- (void)copyResolvedHDRStaticMetadataWithHostMetadata:(const SS_HDR_METADATA *)hostHdrMetadata
                                      hasHostMetadata:(BOOL)hasHostHdrMetadata
                                       displayInfoOut:(CFDataRef *)displayInfoOut
                                       contentInfoOut:(CFDataRef *)contentInfoOut
                                         minLuminance:(float *)minOut
                                         maxLuminance:(float *)maxOut
                               maxAverageLuminance:(float *)maxAverageOut;
- (int)submitDecodeBuffer:(unsigned char *)data
                   length:(int)length
               bufferType:(int)bufferType
                frameType:(int)frameType
                      pts:(unsigned int)pts
              frameNumber:(uint32_t)frameNumber
            enqueueTimeMs:(uint64_t)enqueueTimeMs;
- (int)submitDecodeBuffer:(unsigned char *)data
                   length:(int)length
               bufferType:(int)bufferType
                frameType:(int)frameType
                      pts:(unsigned int)pts
              frameNumber:(uint32_t)frameNumber
            enqueueTimeMs:(uint64_t)enqueueTimeMs
              blockSource:(CMBlockBufferCustomBlockSource *)blockSource;

@end

typedef struct {
    vector_float4 offset;
    vector_float4 scale;
    matrix_float3x3 matrix;
    vector_float4 hdrMetadata;
    vector_float4 hdrControls;
    vector_float4 hdrLuminance;
} MLYCbCrConversionParameters;

struct MLDecodeFrameContext {
    uint64_t enqueueTimeMs;
    uint32_t frameNumber;
};

enum {
    kMLRenderIntervalSampleCapacity = 900,
    kMLEnhancedStartupPacingWindowMs = 350,
    kMLEnhancedStartupPacingPresentThreshold = 8,
};

typedef NS_ENUM(NSInteger, MLRequestedVideoRendererMode) {
    MLRequestedVideoRendererModeAuto = 0,
    MLRequestedVideoRendererModeEnhanced = 1,
    MLRequestedVideoRendererModeNative = 2,
    MLRequestedVideoRendererModeCompatibility = 3,
};

typedef NS_ENUM(NSInteger, MLActiveVideoRendererMode) {
    MLActiveVideoRendererModeUnknown = 0,
    MLActiveVideoRendererModeEnhanced = 1,
    MLActiveVideoRendererModeNative = 2,
    MLActiveVideoRendererModeCompatibility = 3,
};

typedef NS_ENUM(NSInteger, MLRequestedVideoEnhancementMode) {
    MLRequestedVideoEnhancementModeOff = 0,
    MLRequestedVideoEnhancementModeMetalFXQuality = 1,
    MLRequestedVideoEnhancementModeMetalFXPerformance = 2,
    MLRequestedVideoEnhancementModeVTLowLatencySuperResolution = 3,
    MLRequestedVideoEnhancementModeVTQualitySuperResolution = 4,
    MLRequestedVideoEnhancementModeBasicScaling = 5,
    MLRequestedVideoEnhancementModeAuto = 6,
};

typedef NS_ENUM(NSInteger, MLActiveVideoEnhancementEngine) {
    MLActiveVideoEnhancementEngineNone = 0,
    MLActiveVideoEnhancementEngineBasicScaling = 1,
    MLActiveVideoEnhancementEngineMetalFXQuality = 2,
    MLActiveVideoEnhancementEngineMetalFXPerformance = 3,
    MLActiveVideoEnhancementEngineVTLowLatencySuperResolution = 4,
    MLActiveVideoEnhancementEngineVTQualitySuperResolution = 5,
};

typedef NS_ENUM(NSInteger, MLRequestedVideoFrameInterpolationMode) {
    MLRequestedVideoFrameInterpolationModeOff = 0,
    MLRequestedVideoFrameInterpolationModeVTLowLatency = 1,
};

typedef NS_ENUM(NSInteger, MLActiveVideoFrameInterpolationEngine) {
    MLActiveVideoFrameInterpolationEngineNone = 0,
    MLActiveVideoFrameInterpolationEngineVTLowLatency = 1,
};

typedef NS_ENUM(NSUInteger, MLHDRTransferMode) {
    MLHDRTransferModeSDR = 0,
    MLHDRTransferModePQ = 1,
    MLHDRTransferModeHLG = 2,
};

typedef NS_ENUM(NSInteger, MLHDRMetadataSourceMode) {
    MLHDRMetadataSourceModeHost = 0,
    MLHDRMetadataSourceModeClientOverride = 1,
    MLHDRMetadataSourceModeHybrid = 2,
};

typedef NS_ENUM(NSInteger, MLHDRClientDisplayProfileMode) {
    MLHDRClientDisplayProfileModeAuto = 0,
    MLHDRClientDisplayProfileModeManual = 1,
};

typedef NS_ENUM(NSInteger, MLHDRHLGViewingEnvironment) {
    MLHDRHLGViewingEnvironmentAuto = 0,
    MLHDRHLGViewingEnvironmentReference = 1,
    MLHDRHLGViewingEnvironmentDimRoom = 2,
    MLHDRHLGViewingEnvironmentOffice = 3,
    MLHDRHLGViewingEnvironmentBrightRoom = 4,
};

typedef NS_ENUM(NSInteger, MLHDREDRStrategy) {
    MLHDREDRStrategyAuto = 0,
    MLHDREDRStrategyConservative = 1,
    MLHDREDRStrategyBalanced = 2,
    MLHDREDRStrategyPeak = 3,
};

typedef NS_ENUM(NSInteger, MLHDRToneMappingPolicy) {
    MLHDRToneMappingPolicyAuto = 0,
    MLHDRToneMappingPolicyPreserveHighlights = 1,
    MLHDRToneMappingPolicyPreserveMidtones = 2,
    MLHDRToneMappingPolicyPreserveShadows = 3,
    MLHDRToneMappingPolicyReference = 4,
};

typedef NS_ENUM(NSInteger, MLDisplaySyncMode) {
    MLDisplaySyncModeAuto = 0,
    MLDisplaySyncModeOn = 1,
    MLDisplaySyncModeOff = 2,
};

typedef NS_ENUM(NSInteger, MLAllowDrawableTimeoutMode) {
    MLAllowDrawableTimeoutModeAuto = 0,
    MLAllowDrawableTimeoutModeOn = 1,
    MLAllowDrawableTimeoutModeOff = 2,
};

static id<MTLDevice> MLSharedMetalDevice(void);
static void MLPrewarmSharedMetalPipelines(void);
static BOOL MLGetSharedMetalPipelines(MTLPixelFormat pixelFormat,
                                      id<MTLDevice> *deviceOut,
                                      id<MTLComputePipelineState> *computePipelineOut,
                                      id<MTLRenderPipelineState> *blitPipelineOut,
                                      NSError **errorOut);
static BOOL MLHDRTransferColorSpaceSupported(MLHDRTransferMode mode);

static NSString *MLVideoRuntimeSummaryKey(MLActiveVideoRendererMode mode)
{
    switch (mode) {
        case MLActiveVideoRendererModeEnhanced:
            return @"Video Runtime Path Enhanced Active";
        case MLActiveVideoRendererModeNative:
            return @"Video Runtime Path Native Active";
        case MLActiveVideoRendererModeCompatibility:
            return @"Video Runtime Path Compatibility Active";
        default:
            return @"Video Runtime Path Idle";
    }
}

static NSString *MLVideoEnhancementEngineName(MLActiveVideoEnhancementEngine engine)
{
    switch (engine) {
        case MLActiveVideoEnhancementEngineBasicScaling:
            return @"Basic Scaling";
        case MLActiveVideoEnhancementEngineMetalFXQuality:
            return @"MetalFX Spatial (Quality)";
        case MLActiveVideoEnhancementEngineMetalFXPerformance:
            return @"MetalFX Spatial (Performance)";
        case MLActiveVideoEnhancementEngineVTLowLatencySuperResolution:
            return @"VT Low-Latency Super Resolution";
        case MLActiveVideoEnhancementEngineVTQualitySuperResolution:
            return @"VT Quality Super Resolution";
        case MLActiveVideoEnhancementEngineNone:
        default:
            return @"Off";
    }
}

static NSString *MLVideoFrameInterpolationEngineName(MLActiveVideoFrameInterpolationEngine engine)
{
    switch (engine) {
        case MLActiveVideoFrameInterpolationEngineVTLowLatency:
            return @"VT Low-Latency Frame Interpolation";
        case MLActiveVideoFrameInterpolationEngineNone:
        default:
            return @"Off";
    }
}

static int MLCompareUInt16Ascending(const void *lhs, const void *rhs)
{
    uint16_t a = *(const uint16_t *)lhs;
    uint16_t b = *(const uint16_t *)rhs;
    if (a < b) {
        return -1;
    }
    if (a > b) {
        return 1;
    }
    return 0;
}

static float MLComputeRenderedOnePercentLowFps(const uint16_t *samples, NSUInteger count)
{
    if (samples == NULL || count < 30 || count > kMLRenderIntervalSampleCapacity) {
        return 0.0f;
    }

    uint16_t sorted[kMLRenderIntervalSampleCapacity];
    memcpy(sorted, samples, count * sizeof(uint16_t));
    qsort(sorted, count, sizeof(uint16_t), MLCompareUInt16Ascending);

    NSUInteger worstSampleCount = MAX((NSUInteger)1, (NSUInteger)ceil((double)count * 0.01));
    if (worstSampleCount > count) {
        worstSampleCount = count;
    }

    NSUInteger startIndex = count - worstSampleCount;
    uint64_t worstFrameTimeTotalMs = 0;
    for (NSUInteger idx = startIndex; idx < count; idx++) {
        worstFrameTimeTotalMs += sorted[idx];
    }

    if (worstFrameTimeTotalMs == 0) {
        return 0.0f;
    }

    double averageWorstFrameTimeMs = (double)worstFrameTimeTotalMs / (double)worstSampleCount;
    if (averageWorstFrameTimeMs <= 0.0) {
        return 0.0f;
    }

    return 1000.0f / (float)averageWorstFrameTimeMs;
}

static BOOL MLMetalFXIsSupported(void)
{
#if ML_HAS_METALFX
    if (@available(macOS 13.0, *)) {
        // If MetalFX is weak-linked on older systems, class lookup will be nil.
        return NSClassFromString(@"MTLFXSpatialScalerDescriptor") != nil;
    }
#endif
    return NO;
}

static MLHDRTransferMode MLResolveHDRTransferMode(BOOL hdrEnabled, NSInteger hdrTransferFunction)
{
    if (!hdrEnabled) {
        return MLHDRTransferModeSDR;
    }

    switch (hdrTransferFunction) {
        case 1:
            return MLHDRTransferModePQ;
        case 2:
            return MLHDRTransferModeHLG;
        case 0:
        default:
            return MLHDRTransferColorSpaceSupported(MLHDRTransferModeHLG)
                ? MLHDRTransferModeHLG
                : MLHDRTransferModePQ;
    }
}

static NSString *MLHDRTransferModeName(MLHDRTransferMode mode)
{
    switch (mode) {
        case MLHDRTransferModeHLG:
            return @"HLG";
        case MLHDRTransferModePQ:
            return @"PQ";
        case MLHDRTransferModeSDR:
        default:
            return @"SDR";
    }
}

static BOOL MLHDRTransferColorSpaceSupported(MLHDRTransferMode mode)
{
    CGColorSpaceRef colorSpace = nil;
    switch (mode) {
        case MLHDRTransferModeHLG:
            colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_HLG);
            break;
        case MLHDRTransferModePQ:
            colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ);
            break;
        case MLHDRTransferModeSDR:
        default:
            return YES;
    }

    if (colorSpace != nil) {
        CGColorSpaceRelease(colorSpace);
        return YES;
    }

    return NO;
}

static float MLResolvedOpticalOutputScaleForTransfer(MLHDRTransferMode transferMode,
                                                     MLHDRHLGViewingEnvironment viewingEnvironment,
                                                     float baseScale)
{
    float resolved = fmaxf(baseScale, 1.0f);
    if (transferMode != MLHDRTransferModeHLG) {
        return resolved;
    }

    switch (viewingEnvironment) {
        case MLHDRHLGViewingEnvironmentReference:
            resolved *= 0.95f;
            break;
        case MLHDRHLGViewingEnvironmentDimRoom:
            resolved *= 1.00f;
            break;
        case MLHDRHLGViewingEnvironmentOffice:
            resolved *= 1.08f;
            break;
        case MLHDRHLGViewingEnvironmentBrightRoom:
            resolved *= 1.16f;
            break;
        case MLHDRHLGViewingEnvironmentAuto:
        default:
            resolved *= 1.04f;
            break;
    }

    return resolved;
}

static float MLResolvedEDRHeadroomForStrategy(MLHDREDRStrategy strategy,
                                              float currentEDR,
                                              float potentialEDR)
{
    float safeCurrent = fmaxf(currentEDR, 1.0f);
    float safePotential = fmaxf(potentialEDR, safeCurrent);

    switch (strategy) {
        case MLHDREDRStrategyConservative:
            return MIN(safePotential, 1.25f);
        case MLHDREDRStrategyBalanced:
            return MIN(safePotential, 1.75f);
        case MLHDREDRStrategyPeak:
            return safePotential;
        case MLHDREDRStrategyAuto:
        default:
            return MIN(safePotential, 1.55f);
    }
}

static BOOL MLBoolForDisplaySyncMode(MLDisplaySyncMode mode, BOOL legacyVsync)
{
    switch (mode) {
        case MLDisplaySyncModeOn:
            return YES;
        case MLDisplaySyncModeOff:
            return NO;
        case MLDisplaySyncModeAuto:
        default:
            return legacyVsync;
    }
}

static BOOL MLBoolForDrawableTimeoutMode(MLAllowDrawableTimeoutMode mode,
                                         BOOL hdrEnabled,
                                         MLActiveVideoRendererMode activeMode)
{
    switch (mode) {
        case MLAllowDrawableTimeoutModeOn:
            return YES;
        case MLAllowDrawableTimeoutModeOff:
            return NO;
        case MLAllowDrawableTimeoutModeAuto:
        default:
            return hdrEnabled && activeMode == MLActiveVideoRendererModeEnhanced;
    }
}

static BOOL MLEnhancedHDRPresentationIsSupported(void)
{
    return MLSharedMetalDevice() != nil;
}

static BOOL MLGetHostHdrMetadataSnapshot(PSS_HDR_METADATA metadata)
{
    if (metadata == NULL) {
        return NO;
    }

    memset(metadata, 0, sizeof(*metadata));
    return LiGetHdrMetadata(metadata);
}

static CFDataRef MLCreateMasteringDisplayColorVolumeData(const SS_HDR_METADATA *hdrMetadata)
{
    if (hdrMetadata == NULL ||
        hdrMetadata->displayPrimaries[0].x == 0 ||
        hdrMetadata->displayPrimaries[1].x == 0 ||
        hdrMetadata->displayPrimaries[2].x == 0 ||
        hdrMetadata->maxDisplayLuminance == 0) {
        return NULL;
    }

    struct {
        vector_ushort2 primaries[3];
        vector_ushort2 whitePoint;
        uint32_t luminanceMax;
        uint32_t luminanceMin;
    } __attribute__((packed, aligned(4))) mdcv;

    mdcv.primaries[0].x = __builtin_bswap16(hdrMetadata->displayPrimaries[1].x);
    mdcv.primaries[0].y = __builtin_bswap16(hdrMetadata->displayPrimaries[1].y);
    mdcv.primaries[1].x = __builtin_bswap16(hdrMetadata->displayPrimaries[2].x);
    mdcv.primaries[1].y = __builtin_bswap16(hdrMetadata->displayPrimaries[2].y);
    mdcv.primaries[2].x = __builtin_bswap16(hdrMetadata->displayPrimaries[0].x);
    mdcv.primaries[2].y = __builtin_bswap16(hdrMetadata->displayPrimaries[0].y);
    mdcv.whitePoint.x = __builtin_bswap16(hdrMetadata->whitePoint.x);
    mdcv.whitePoint.y = __builtin_bswap16(hdrMetadata->whitePoint.y);
    mdcv.luminanceMax = __builtin_bswap32((uint32_t)hdrMetadata->maxDisplayLuminance * 10000U);
    mdcv.luminanceMin = __builtin_bswap32((uint32_t)hdrMetadata->minDisplayLuminance);

    return CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&mdcv, sizeof(mdcv));
}

static CFDataRef MLCreateContentLightLevelInfoData(const SS_HDR_METADATA *hdrMetadata)
{
    if (hdrMetadata == NULL ||
        hdrMetadata->maxContentLightLevel == 0 ||
        hdrMetadata->maxFrameAverageLightLevel == 0) {
        return NULL;
    }

    struct {
        uint16_t maxContentLightLevel;
        uint16_t maxFrameAverageLightLevel;
    } __attribute__((packed, aligned(2))) cll;

    cll.maxContentLightLevel = __builtin_bswap16(hdrMetadata->maxContentLightLevel);
    cll.maxFrameAverageLightLevel = __builtin_bswap16(hdrMetadata->maxFrameAverageLightLevel);

    return CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&cll, sizeof(cll));
}

static CFDataRef MLCreateMasteringDisplayColorVolumeDataFromLuminance(float minLuminanceNits,
                                                                      float maxLuminanceNits)
{
    const uint16_t redX = 35400;
    const uint16_t redY = 14600;
    const uint16_t greenX = 8500;
    const uint16_t greenY = 39850;
    const uint16_t blueX = 6550;
    const uint16_t blueY = 2300;
    const uint16_t whiteX = 15635;
    const uint16_t whiteY = 16450;

    struct {
        vector_ushort2 primaries[3];
        vector_ushort2 whitePoint;
        uint32_t luminanceMax;
        uint32_t luminanceMin;
    } __attribute__((packed, aligned(4))) mdcv;

    mdcv.primaries[0].x = __builtin_bswap16(greenX);
    mdcv.primaries[0].y = __builtin_bswap16(greenY);
    mdcv.primaries[1].x = __builtin_bswap16(blueX);
    mdcv.primaries[1].y = __builtin_bswap16(blueY);
    mdcv.primaries[2].x = __builtin_bswap16(redX);
    mdcv.primaries[2].y = __builtin_bswap16(redY);
    mdcv.whitePoint.x = __builtin_bswap16(whiteX);
    mdcv.whitePoint.y = __builtin_bswap16(whiteY);
    mdcv.luminanceMax = __builtin_bswap32((uint32_t)llroundf(fmaxf(maxLuminanceNits, 100.0f) * 10000.0f));
    mdcv.luminanceMin = __builtin_bswap32((uint32_t)llroundf(fmaxf(minLuminanceNits, 0.0001f) * 10000.0f));

    return CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&mdcv, sizeof(mdcv));
}

static CFDataRef MLCreateContentLightLevelInfoDataFromLuminance(float maxContentLightLevel,
                                                                float maxFrameAverageLightLevel)
{
    struct {
        uint16_t maxContentLightLevel;
        uint16_t maxFrameAverageLightLevel;
    } __attribute__((packed, aligned(2))) cll;

    cll.maxContentLightLevel = __builtin_bswap16((uint16_t)llroundf(fmaxf(maxContentLightLevel, 1.0f)));
    cll.maxFrameAverageLightLevel = __builtin_bswap16((uint16_t)llroundf(fmaxf(maxFrameAverageLightLevel, 1.0f)));

    return CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&cll, sizeof(cll));
}

static CGColorSpaceRef MLCreateTransferColorSpace(MLHDRTransferMode mode)
{
    switch (mode) {
        case MLHDRTransferModeHLG:
            return CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_HLG);
        case MLHDRTransferModePQ:
            return CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ);
        case MLHDRTransferModeSDR:
        default:
            return CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
    }
}

static CFDataRef MLCreateHLGAmbientViewingEnvironmentData(MLHDRHLGViewingEnvironment viewingEnvironment)
{
    uint32_t ambientIlluminanceScaled = 3140000;
    switch (viewingEnvironment) {
        case MLHDRHLGViewingEnvironmentReference:
            ambientIlluminanceScaled = 50000;
            break;
        case MLHDRHLGViewingEnvironmentDimRoom:
            ambientIlluminanceScaled = 200000;
            break;
        case MLHDRHLGViewingEnvironmentOffice:
            ambientIlluminanceScaled = 1000000;
            break;
        case MLHDRHLGViewingEnvironmentBrightRoom:
            ambientIlluminanceScaled = 3000000;
            break;
        case MLHDRHLGViewingEnvironmentAuto:
        default:
            ambientIlluminanceScaled = 3140000;
            break;
    }

    struct {
        uint32_t ambientIlluminance;
        uint16_t ambientLightX;
        uint16_t ambientLightY;
    } __attribute__((packed, aligned(4))) ambient;

    ambient.ambientIlluminance = __builtin_bswap32(ambientIlluminanceScaled);
    ambient.ambientLightX = __builtin_bswap16(15635);
    ambient.ambientLightY = __builtin_bswap16(16450);

    return CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&ambient, sizeof(ambient));
}

static int MLClampInt(int value, int minValue, int maxValue)
{
    if (value < minValue) {
        return minValue;
    }
    if (value > maxValue) {
        return maxValue;
    }
    return value;
}

static BOOL MLPixelFormatIsVideoRange(OSType pixelFormat)
{
    switch (pixelFormat) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange:
        case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
        case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
        case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
        case kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange:
            return YES;
        default:
            return NO;
    }
}

static MLYCbCrConversionParameters MLYCbCrConversionParametersForPixelFormat(OSType pixelFormat,
                                                                             MLHDRTransferMode hdrTransferMode,
                                                                             float opticalOutputScale,
                                                                             BOOL useEDR,
                                                                             BOOL toneMapToSDR,
                                                                             MLHDRToneMappingPolicy toneMappingPolicy,
                                                                             float minLuminance,
                                                                             float maxLuminance,
                                                                             float maxAverageLuminance)
{
    const BOOL videoRange = MLPixelFormatIsVideoRange(pixelFormat);
    vector_float4 offset = { 0.0f, 0.5f, 0.5f, 0.0f };
    vector_float4 scale = { 1.0f, 1.0f, 1.0f, 1.0f };

    switch (pixelFormat) {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
        case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
        case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
            if (videoRange) {
                offset = (vector_float4){ 64.0f / 1023.0f, 512.0f / 1023.0f, 512.0f / 1023.0f, 0.0f };
                scale = (vector_float4){ 1023.0f / 876.0f, 1023.0f / 896.0f, 1023.0f / 896.0f, 1.0f };
            }
            break;
        case kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange:
            offset = (vector_float4){ 4096.0f / 65535.0f, 32768.0f / 65535.0f, 32768.0f / 65535.0f, 0.0f };
            scale = (vector_float4){ 65535.0f / 56064.0f, 65535.0f / 57344.0f, 65535.0f / 57344.0f, 1.0f };
            break;
        default:
            if (videoRange) {
                offset = (vector_float4){ 16.0f / 255.0f, 128.0f / 255.0f, 128.0f / 255.0f, 0.0f };
                scale = (vector_float4){ 255.0f / 219.0f, 255.0f / 224.0f, 255.0f / 224.0f, 1.0f };
            }
            break;
    }

    matrix_float3x3 matrix;
    if (hdrTransferMode != MLHDRTransferModeSDR) {
        matrix.columns[0] = (vector_float3){ 1.0f, 1.0f, 1.0f };
        matrix.columns[1] = (vector_float3){ 0.0f, -0.164553f, 1.8814f };
        matrix.columns[2] = (vector_float3){ 1.4746f, -0.571353f, 0.0f };
    } else {
        matrix.columns[0] = (vector_float3){ 1.0f, 1.0f, 1.0f };
        matrix.columns[1] = (vector_float3){ 0.0f, -0.187324f, 1.8556f };
        matrix.columns[2] = (vector_float3){ 1.5748f, -0.468124f, 0.0f };
    }

    MLYCbCrConversionParameters params;
    params.offset = offset;
    params.scale = scale;
    params.matrix = matrix;
    params.hdrMetadata = (vector_float4){
        (float)hdrTransferMode,
        toneMapToSDR ? -fmaxf(fabsf(opticalOutputScale), 1.0f) : fmaxf(opticalOutputScale, 1.0f),
        useEDR ? 1.0f : 0.0f,
        toneMapToSDR ? 1.0f : 0.0f,
    };
    params.hdrControls = (vector_float4){
        (float)toneMappingPolicy,
        0.0f,
        0.0f,
        0.0f,
    };
    params.hdrLuminance = (vector_float4){
        fmaxf(minLuminance, 0.0001f),
        fmaxf(maxLuminance, 100.0f),
        fmaxf(maxAverageLuminance, 1.0f),
        0.0f,
    };
    return params;
}

static NSString *const kMetalShaderSource = @"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct RasterizerData {\n"
"    float4 position [[position]];\n"
"    float2 texCoord;\n"
"};\n"
"vertex RasterizerData fullscreenVertex(uint vertexID [[vertex_id]]) {\n"
"    float2 positions[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };\n"
"    float2 texCoords[4] = { float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0), float2(1.0, 0.0) };\n"
"    RasterizerData out;\n"
"    out.position = float4(positions[vertexID], 0.0, 1.0);\n"
"    out.texCoord = texCoords[vertexID];\n"
"    return out;\n"
"}\n"
"fragment float4 textureBlitFragment(RasterizerData in [[stage_in]], texture2d<float> colorTexture [[texture(0)]]) {\n"
"    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);\n"
"    return colorTexture.sample(textureSampler, in.texCoord);\n"
"}\n"
"struct YCbCrConversionParameters {\n"
"    float4 offset;\n"
"    float4 scale;\n"
"    float3x3 matrix;\n"
"    float4 hdrMetadata;\n"
"    float4 hdrControls;\n"
"    float4 hdrLuminance;\n"
"};\n"
"float hlgInverseOETF(float value) {\n"
"    constexpr float a = 0.17883277;\n"
"    constexpr float b = 0.28466892;\n"
"    constexpr float c = 0.55991073;\n"
"    value = clamp(value, 0.0, 1.0);\n"
"    if (value <= 0.5) {\n"
"        return (value * value) / 3.0;\n"
"    }\n"
"    return (exp((value - c) / a) + b) / 12.0;\n"
"}\n"
"float pqInverseEOTF(float value) {\n"
"    constexpr float m1 = 0.1593017578125;\n"
"    constexpr float m2 = 78.84375;\n"
"    constexpr float c1 = 0.8359375;\n"
"    constexpr float c2 = 18.8515625;\n"
"    constexpr float c3 = 18.6875;\n"
"    value = clamp(value, 0.0, 1.0);\n"
"    float p = pow(value, 1.0 / m2);\n"
"    float numerator = max(p - c1, 0.0);\n"
"    float denominator = max(c2 - c3 * p, 1e-6);\n"
"    return pow(numerator / denominator, 1.0 / m1);\n"
"}\n"
"float3 hdrLinearize(float3 rgb, uint hdrMode, float opticalOutputScale) {\n"
"    rgb = clamp(rgb, 0.0, 1.0);\n"
"    if (hdrMode == 1) {\n"
"        float3 pqLinear = float3(pqInverseEOTF(rgb.r), pqInverseEOTF(rgb.g), pqInverseEOTF(rgb.b));\n"
"        return pqLinear * (10000.0 / max(opticalOutputScale, 0.001));\n"
"    }\n"
"    if (hdrMode == 2) {\n"
"        return float3(hlgInverseOETF(rgb.r), hlgInverseOETF(rgb.g), hlgInverseOETF(rgb.b)) * 12.0;\n"
"    }\n"
"    return saturate(rgb);\n"
"}\n"
"float3 gammaEncodeSDR(float3 linear) {\n"
"    return pow(clamp(linear, 0.0, 1.0), float3(1.0 / 2.2));\n"
"}\n"
"float rec709EncodeChannel(float value) {\n"
"    value = clamp(value, 0.0, 1.0);\n"
"    if (value < 0.018) {\n"
"        return 4.5 * value;\n"
"    }\n"
"    return 1.099 * pow(value, 0.45) - 0.099;\n"
"}\n"
"float3 rec709Encode(float3 linear) {\n"
"    return float3(rec709EncodeChannel(linear.r), rec709EncodeChannel(linear.g), rec709EncodeChannel(linear.b));\n"
"}\n"
"float3 bt2020ToRec709(float3 color) {\n"
"    const float3x3 transform = float3x3(\n"
"        float3(1.6605, -0.1246, -0.0182),\n"
"        float3(-0.5876, 1.1329, -0.1006),\n"
"        float3(-0.0728, -0.0083, 1.1187)\n"
"    );\n"
"    return max(transform * color, float3(0.0));\n"
"}\n"
"float3 acesToneMap(float3 color) {\n"
"    const float a = 2.51;\n"
"    const float b = 0.03;\n"
"    const float c = 2.43;\n"
"    const float d = 0.59;\n"
"    const float e = 0.14;\n"
"    return saturate((color * (a * color + b)) / (color * (c * color + d) + e));\n"
"}\n"
"float3 toneMapHdrToSdr(float3 rgb, uint hdrMode, float opticalOutputScale, uint tonePolicy, float4 hdrLuminance) {\n"
"    float3 linear = hdrLinearize(rgb, hdrMode, opticalOutputScale);\n"
"    linear = bt2020ToRec709(linear);\n"
"    float exposure = hdrMode == 1 ? 0.82 : 1.08;\n"
"    float minLuminance = max(hdrLuminance.x, 0.0001);\n"
"    float maxLuminance = max(hdrLuminance.y, 100.0);\n"
"    float maxAverageLuminance = clamp(hdrLuminance.z, minLuminance, maxLuminance);\n"
"    float peakNormalization = clamp(1000.0 / maxLuminance, 0.28, 2.8);\n"
"    float averageNormalization = clamp(203.0 / max(maxAverageLuminance, 40.0), 0.40, 3.0);\n"
"    float contentNormalization = mix(peakNormalization, averageNormalization, 0.45);\n"
"    if (tonePolicy == 1) {\n"
"        exposure *= 0.72;\n"
"    } else if (tonePolicy == 2) {\n"
"        exposure *= 0.92;\n"
"    } else if (tonePolicy == 3) {\n"
"        exposure *= 1.16;\n"
"    } else if (tonePolicy == 4) {\n"
"        exposure *= 0.88;\n"
"    }\n"
"    float blackCompensation = clamp(log2(1.0 + minLuminance * 10000.0) * 0.0025, 0.0, 0.06);\n"
"    float3 mapped = acesToneMap(linear * exposure * contentNormalization);\n"
"    if (tonePolicy == 1) {\n"
"        mapped = pow(mapped, float3(1.06));\n"
"    } else if (tonePolicy == 2) {\n"
"        mapped = pow(mapped, float3(0.98));\n"
"    } else if (tonePolicy == 3) {\n"
"        mapped = min(pow(mapped, float3(0.90)) * 1.02, float3(1.0));\n"
"    }\n"
"    if (blackCompensation > 0.0) {\n"
"        mapped = clamp((mapped - blackCompensation) / max(1.0 - blackCompensation, 0.001), 0.0, 1.0);\n"
"    }\n"
"    return rec709Encode(mapped);\n"
"}\n"
"float3 processHdr(float3 rgb, uint hdrMode, float opticalOutputScale, bool useEDR, uint tonePolicy, float4 hdrLuminance) {\n"
"    rgb = clamp(rgb, 0.0, 1.0);\n"
"    if (hdrMode == 0) {\n"
"        return rgb;\n"
"    }\n"
"    if (!useEDR && opticalOutputScale < 0.0) {\n"
"        return toneMapHdrToSdr(rgb, hdrMode, -opticalOutputScale, tonePolicy, hdrLuminance);\n"
"    }\n"
"    if (useEDR) {\n"
"        return hdrLinearize(rgb, hdrMode, opticalOutputScale);\n"
"    }\n"
"    return rgb;\n"
"}\n"
"kernel void ycbcrToRgb(texture2d<float, access::read> textureY [[texture(0)]],\n"
"                       texture2d<float, access::read> textureCbCr [[texture(1)]],\n"
"                       texture2d<float, access::write> textureRGB [[texture(2)]],\n"
"                       constant YCbCrConversionParameters& params [[buffer(0)]],\n"
"                       uint2 gid [[thread_position_in_grid]]) {\n"
"    if (gid.x >= textureRGB.get_width() || gid.y >= textureRGB.get_height()) return;\n"
"    float y = textureY.read(gid).r;\n"
"    uint chromaWidth = max((uint)1, textureCbCr.get_width());\n"
"    uint chromaHeight = max((uint)1, textureCbCr.get_height());\n"
"    uint2 chromaCoord = uint2(\n"
"        min((gid.x * chromaWidth) / max((uint)1, textureRGB.get_width()), chromaWidth - 1),\n"
"        min((gid.y * chromaHeight) / max((uint)1, textureRGB.get_height()), chromaHeight - 1)\n"
"    );\n"
"    float2 cbcr = textureCbCr.read(chromaCoord).rg;\n"
"    float3 ycbcr = (float3(y, cbcr.x, cbcr.y) - params.offset.xyz) * params.scale.xyz;\n"
"    float3 rgb = params.matrix * ycbcr;\n"
"    rgb = processHdr(rgb,\n"
"                     (uint)(params.hdrMetadata.x + 0.5),\n"
"                     params.hdrMetadata.y,\n"
"                     params.hdrMetadata.z > 0.5,\n"
"                     (uint)(params.hdrControls.x + 0.5),\n"
"                     params.hdrLuminance);\n"
"    textureRGB.write(float4(rgb, 1.0), gid);\n"
"}\n";

static id<MTLDevice> MLSharedMetalDevice(void)
{
    static id<MTLDevice> sharedDevice = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedDevice = MTLCreateSystemDefaultDevice();
    });
    return sharedDevice;
}

static dispatch_queue_t MLSharedMetalPipelineQueue(void)
{
    static dispatch_queue_t queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("std.skyhua.moonlight.video.metal-pipeline", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static dispatch_group_t MLSharedMetalPipelineWarmupGroup(void)
{
    static dispatch_group_t group = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        group = dispatch_group_create();
    });
    return group;
}

static id<MTLLibrary> sSharedMetalLibrary = nil;
static id<MTLComputePipelineState> sSharedComputePipelineState = nil;
static NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *sSharedBlitPipelineStates = nil;
static NSError *sSharedMetalPipelineError = nil;

static id<MTLRenderPipelineState> MLCreateBlitPipelineState(id<MTLDevice> device,
                                                            id<MTLLibrary> library,
                                                            MTLPixelFormat pixelFormat,
                                                            NSError **errorOut)
{
    if (device == nil || library == nil) {
        return nil;
    }

    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"fullscreenVertex"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"textureBlitFragment"];
    if (vertexFunction == nil || fragmentFunction == nil) {
        return nil;
    }

    MTLRenderPipelineDescriptor *renderDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    renderDescriptor.vertexFunction = vertexFunction;
    renderDescriptor.fragmentFunction = fragmentFunction;
    renderDescriptor.colorAttachments[0].pixelFormat = pixelFormat;
    return [device newRenderPipelineStateWithDescriptor:renderDescriptor error:errorOut];
}

static void MLPrewarmSharedMetalPipelines(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_group_enter(MLSharedMetalPipelineWarmupGroup());
        dispatch_async(MLSharedMetalPipelineQueue(), ^{
            @autoreleasepool {
                id<MTLDevice> device = MLSharedMetalDevice();
                if (device == nil) {
                    sSharedMetalPipelineError = [NSError errorWithDomain:@"Moonlight.VideoRenderer"
                                                                    code:-1
                                                                userInfo:@{NSLocalizedDescriptionKey: @"Metal device unavailable"}];
                    dispatch_group_leave(MLSharedMetalPipelineWarmupGroup());
                    return;
                }

                NSError *error = nil;
                id<MTLLibrary> library = [device newLibraryWithSource:kMetalShaderSource options:nil error:&error];
                if (library == nil) {
                    sSharedMetalPipelineError = error;
                    dispatch_group_leave(MLSharedMetalPipelineWarmupGroup());
                    return;
                }

                id<MTLFunction> computeFunction = [library newFunctionWithName:@"ycbcrToRgb"];
                id<MTLComputePipelineState> computePipeline = [device newComputePipelineStateWithFunction:computeFunction error:&error];
                if (computePipeline == nil) {
                    sSharedMetalPipelineError = error;
                    dispatch_group_leave(MLSharedMetalPipelineWarmupGroup());
                    return;
                }

                NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *blitPipelines = [NSMutableDictionary dictionary];
                NSArray<NSNumber *> *pixelFormats = @[
                    @(MTLPixelFormatBGRA8Unorm),
                    @(MTLPixelFormatBGR10A2Unorm),
                    @(MTLPixelFormatRGBA16Float),
                ];
                for (NSNumber *pixelFormatNumber in pixelFormats) {
                    MTLPixelFormat pixelFormat = (MTLPixelFormat)pixelFormatNumber.unsignedIntegerValue;
                    id<MTLRenderPipelineState> pipeline = MLCreateBlitPipelineState(device, library, pixelFormat, &error);
                    if (pipeline == nil) {
                        sSharedMetalPipelineError = error;
                        dispatch_group_leave(MLSharedMetalPipelineWarmupGroup());
                        return;
                    }
                    blitPipelines[pixelFormatNumber] = pipeline;
                }

                sSharedMetalLibrary = library;
                sSharedComputePipelineState = computePipeline;
                sSharedBlitPipelineStates = blitPipelines;
            }

            dispatch_group_leave(MLSharedMetalPipelineWarmupGroup());
        });
    });
}

static BOOL MLGetSharedMetalPipelines(MTLPixelFormat pixelFormat,
                                      id<MTLDevice> *deviceOut,
                                      id<MTLComputePipelineState> *computePipelineOut,
                                      id<MTLRenderPipelineState> *blitPipelineOut,
                                      NSError **errorOut)
{
    MLPrewarmSharedMetalPipelines();
    dispatch_group_wait(MLSharedMetalPipelineWarmupGroup(), DISPATCH_TIME_FOREVER);

    id<MTLRenderPipelineState> blitPipeline = sSharedBlitPipelineStates[@(pixelFormat)];
    BOOL success = (sSharedComputePipelineState != nil && blitPipeline != nil);
    if (deviceOut != NULL) {
        *deviceOut = MLSharedMetalDevice();
    }
    if (computePipelineOut != NULL) {
        *computePipelineOut = sSharedComputePipelineState;
    }
    if (blitPipelineOut != NULL) {
        *blitPipelineOut = blitPipeline;
    }
    if (!success && errorOut != NULL) {
        *errorOut = sSharedMetalPipelineError;
    }

    return success;
}

@implementation VideoDecoderRenderer {
    OSView *_view;

    // AVSampleBufferDisplayLayer (Legacy)
    AVSampleBufferDisplayLayer* displayLayer;
    RendererLayerContainer *layerContainer;

    // Metal (Modern)
    MTKView *_metalView;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    CVMetalTextureCacheRef _textureCache;
    id _spatialScaler;
    id<MTLTexture> _upscaledTexture;
    id<MTLTexture> _intermediateTexture;
    id<MTLComputePipelineState> _computePipelineState;
    id<MTLRenderPipelineState> _blitRenderPipelineState;
    MTLPixelFormat _blitRenderPipelinePixelFormat;
    CAEDRMetadata *_hdrEDRMetadata;
    CGColorSpaceRef _hdrLinearColorSpace;
    CGColorSpaceRef _hdrTransferColorSpace;
    CGColorSpaceRef _hdrSDROutputColorSpace;
    CGColorSpaceRef _nativeDisplayColorSpace;
    CFDataRef _nativeMasteringDisplayColorVolume;
    CFDataRef _nativeContentLightLevelInfo;

    // Common
    Boolean waitingForSps, waitingForPps, waitingForVps;

    int videoFormat;

    NSData *spsData, *ppsData, *vpsData;
    CMVideoFormatDescriptionRef _imageFormatDesc;
    CMVideoFormatDescriptionRef formatDesc;
    CMVideoFormatDescriptionRef _nativeImageFormatDesc;

    CVDisplayLinkRef _displayLink;

    VideoStats _activeWndVideoStats;
    int _lastFrameNumber;

    NSString *_runtimeHostKey;
    MLRequestedVideoRendererMode _requestedRendererMode;
    MLActiveVideoRendererMode _activeRendererMode;
    int _upscalingMode;
    MLRequestedVideoEnhancementMode _requestedEnhancementMode;
    MLActiveVideoEnhancementEngine _activeEnhancementEngine;
    MLActiveVideoEnhancementEngine _lastLoggedEnhancementEngine;
    MLRequestedVideoFrameInterpolationMode _requestedFrameInterpolationMode;
    MLActiveVideoFrameInterpolationEngine _activeFrameInterpolationEngine;
    MLActiveVideoFrameInterpolationEngine _lastLoggedFrameInterpolationEngine;
    VTDecompressionSessionRef _decompressionSession;
    CVImageBufferRef _currentFrame;
    CMTime _currentFramePresentationTimeStamp;
    uint64_t _currentFrameEnqueueTimeMs;
    uint32_t _currentFrameNumber;
    uint64_t _currentFrameSequence;
    uint64_t _lastPresentedFrameSequence;
    id _frameProcessor;
    id _frameProcessorConfiguration;
    CVPixelBufferPoolRef _frameProcessorOutputPool;
    MLActiveVideoEnhancementEngine _frameProcessorEngine;
    NSInteger _frameProcessorInputWidth;
    NSInteger _frameProcessorInputHeight;
    float _frameProcessorScaleFactor;
    BOOL _enhancementWarmupInFlight;
    NSUInteger _enhancementWarmupGeneration;
    NSInteger _enhancementWarmupWidth;
    NSInteger _enhancementWarmupHeight;
    float _enhancementWarmupScaleFactor;
    MLActiveVideoEnhancementEngine _enhancementWarmupEngine;
    CVImageBufferRef _previousEnhancedSourceFrame;
    CVImageBufferRef _previousEnhancedOutputFrame;
    id _frameInterpolationProcessor;
    id _frameInterpolationConfiguration;
    CVPixelBufferPoolRef _frameInterpolationOutputPool;
    NSInteger _frameInterpolationInputWidth;
    NSInteger _frameInterpolationInputHeight;
    OSType _frameInterpolationSourcePixelFormat;
    dispatch_queue_t _vtWarmupQueue;
    BOOL _frameInterpolationWarmupInFlight;
    NSUInteger _frameInterpolationWarmupGeneration;
    NSInteger _frameInterpolationWarmupWidth;
    NSInteger _frameInterpolationWarmupHeight;
    CVImageBufferRef _previousInterpolationSourceFrame;
    CVImageBufferRef _pendingInterpolatedFrame;
    uint64_t _pendingInterpolatedEnqueueTimeMs;
    uint32_t _pendingInterpolatedFrameNumber;
    uint64_t _pendingInterpolatedForSourceSequence;
    BOOL _pendingInterpolatedPresented;
    uint64_t _deferredCurrentSourceSequence;
    double _lastDisplayRefreshRate;

    // Stats helpers
    uint64_t _lastFrameReceiveTimeMs;
    unsigned int _lastFramePresentationTimeMs;
    float _jitterMsEstimate;
    uint16_t _renderIntervalSamples[kMLRenderIntervalSampleCapacity];
    NSUInteger _renderIntervalSampleCount;
    NSUInteger _renderIntervalSampleIndex;
    uint64_t _lastRenderedSampleTimeMs;
    uint64_t _lastDequeuedFrameMs;
    uint64_t _lastIdleLogMs;
    NSUInteger _remainingDequeuedFrameLogCount;
    NSInteger _framePacingMode;
    NSInteger _smoothnessLatencyMode;
    NSInteger _timingBufferLevel;
    BOOL _timingEnableVsync;
    BOOL _timingPrioritizeResponsiveness;
    BOOL _timingCompatibilityMode;
    BOOL _timingSdrCompatibilityWorkaround;
    NSInteger _lastLoggedPendingTarget;
    MLDisplaySyncMode _displaySyncMode;
    NSInteger _frameQueueTargetOverride;
    NSInteger _timingResponsivenessBias;
    MLAllowDrawableTimeoutMode _allowDrawableTimeoutMode;
    BOOL _enableHdr;
    NSInteger _hdrTransferFunctionPreference;
    MLHDRMetadataSourceMode _hdrMetadataSourceMode;
    MLHDRClientDisplayProfileMode _hdrClientDisplayProfileMode;
    MLHDRHLGViewingEnvironment _hdrHlgViewingEnvironment;
    MLHDREDRStrategy _hdrEdrStrategy;
    MLHDRToneMappingPolicy _hdrToneMappingPolicy;
    BOOL _hdrBrightnessOverrideEnabled;
    MLHDRTransferMode _hdrTransferMode;
    float _hdrOpticalOutputScale;
    float _hdrMinLuminance;
    float _hdrMaxLuminance;
    float _hdrMaxAverageLuminance;
    BOOL _hdrOutputUsesEDR;
    BOOL _hdrToneMapToSDR;
    BOOL _hdrUsesTransferMetadataPresentation;
    float _hdrDisplayHeadroom;
    BOOL _preparedHDRDisplayStateValid;
    BOOL _preparedHDRDisplayHasEDRHeadroom;
    BOOL _preparedHDRDisplaySupportsEDRPresentation;
    CGDirectDisplayID _preparedHDRDisplayID;
    BOOL _metalDrawScheduled;
    NSUInteger _lastLoggedDrawableWidth;
    NSUInteger _lastLoggedDrawableHeight;
    OSType _lastLoggedDecodedPixelFormat;
    size_t _lastLoggedDecodedPlaneCount;
    uint64_t _lastNativeDisplayBackpressureLogMs;
    NSUInteger _nativeDisplayBackpressureCount;
    uint64_t _nativeDisplayBackpressureWindowStartMs;
    NSUInteger _nativeDisplayBackpressureBurstCount;
    BOOL _nativeFallbackScheduled;
    uint64_t _rendererStartTimeMs;
    uint64_t _enhancedStartupPacingUntilMs;
    NSUInteger _enhancedStartupPresentedFrameCount;
    BOOL _didLogEnhancedStartupPacing;
    NSUInteger _metalInflightLimit;
    uint64_t _lastDrawableUnavailableLogMs;
    NSUInteger _drawableUnavailableCount;
    uint64_t _lastInflightBackpressureLogMs;
    NSUInteger _inflightBackpressureCount;
    dispatch_semaphore_t _metalInflightSemaphore;
}

@synthesize videoFormat;

- (void)reinitializeDisplayLayer
{
    if (displayLayer != nil) {
        [displayLayer flushAndRemoveImage];
    }

    if (_nativeImageFormatDesc != NULL) {
        CFRelease(_nativeImageFormatDesc);
        _nativeImageFormatDesc = NULL;
    }

    if (_metalView) {
        [_metalView removeFromSuperview];
        _metalView = nil;
    }

    [layerContainer removeFromSuperview];
    layerContainer = [[RendererLayerContainer alloc] init];
    layerContainer.frame = _view.bounds;
    layerContainer.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    [_view addSubview:layerContainer];

    displayLayer = (AVSampleBufferDisplayLayer *)layerContainer.layer;
    displayLayer.backgroundColor = [OSColor blackColor].CGColor;
    displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    displayLayer.opaque = YES;
    [self prepareNativePresentationResources];

    [self resetVideoParameterSetState];

    if (formatDesc != nil) {
        CFRelease(formatDesc);
        formatDesc = nil;
    }
}

static CGDirectDisplayID getDisplayID(NSScreen* screen)
{
    NSNumber *screenNumber = [screen deviceDescription][@"NSScreenNumber"];
    return [screenNumber unsignedIntValue];
}

- (id)initWithView:(OSView *)view
{
    self = [super init];

    _view = view;
    [self resetVideoParameterSetState];
    _device = MLSharedMetalDevice();
    if (_device != nil) {
        MLPrewarmSharedMetalPipelines();
    }
    _vtWarmupQueue = dispatch_queue_create("std.skyhua.moonlight.video.vt-warmup", DISPATCH_QUEUE_SERIAL);

    return self;
}

- (void)prewarmPresentationForStreamConfig:(StreamConfiguration *)streamConfig
{
    if (streamConfig == nil) {
        return;
    }

    void (^warmBlock)(void) = ^{
        uint64_t warmStartMs = LiGetMillis();
        [self setupWithVideoFormat:self->videoFormat
                         frameRate:streamConfig.frameRate
                     upscalingMode:streamConfig.upscalingMode
                      streamConfig:streamConfig];
        Log(LOG_I, @"[video] Presentation prewarm finished in %llums requested=%@ active=%@ hdr=%d",
            (unsigned long long)(LiGetMillis() - warmStartMs),
            [self requestedRendererModeName:self->_requestedRendererMode],
            [self activeRendererModeName:self->_activeRendererMode],
            streamConfig.enableHdr ? 1 : 0);

        if (self->_activeRendererMode == MLActiveVideoRendererModeEnhanced &&
            !self->_enableHdr &&
            streamConfig.width > 0 &&
            streamConfig.height > 0 &&
            self->_metalView != nil &&
            self->_metalView.drawableSize.width > 0.0 &&
            self->_metalView.drawableSize.height > 0.0) {
            float prewarmScaleFactor = 1.0f;
            NSString *prewarmReason = nil;
            MLActiveVideoEnhancementEngine prewarmEngine =
                [self resolveEnhancementEngineForSourceWidth:streamConfig.width
                                                sourceHeight:streamConfig.height
                                                 targetWidth:(NSUInteger)llround(self->_metalView.drawableSize.width)
                                                targetHeight:(NSUInteger)llround(self->_metalView.drawableSize.height)
                                                 scaleFactor:&prewarmScaleFactor
                                                      reason:&prewarmReason];
            if (prewarmEngine == MLActiveVideoEnhancementEngineVTLowLatencySuperResolution ||
                prewarmEngine == MLActiveVideoEnhancementEngineVTQualitySuperResolution) {
                [self requestEnhancementWarmupForEngine:prewarmEngine
                                            sourceWidth:streamConfig.width
                                           sourceHeight:streamConfig.height
                                            scaleFactor:prewarmScaleFactor];
            }
        }

        if (self->_requestedFrameInterpolationMode == MLRequestedVideoFrameInterpolationModeVTLowLatency &&
            self->_activeRendererMode == MLActiveVideoRendererModeEnhanced &&
            !self->_enableHdr) {
            [self requestFrameInterpolationWarmupForStreamWidth:streamConfig.width
                                                   streamHeight:streamConfig.height];
        }
    };

    if ([NSThread isMainThread]) {
        warmBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), warmBlock);
    }
}

- (void)resetVideoParameterSetState
{
    waitingForSps = true;
    spsData = nil;
    waitingForPps = true;
    ppsData = nil;
    waitingForVps = true;
    vpsData = nil;
}

- (BOOL)usesDecompressionSession
{
    return _activeRendererMode == MLActiveVideoRendererModeEnhanced ||
           _activeRendererMode == MLActiveVideoRendererModeNative;
}

- (NSString *)requestedRendererModeName:(MLRequestedVideoRendererMode)mode
{
    switch (mode) {
        case MLRequestedVideoRendererModeAuto:
            return @"Auto";
        case MLRequestedVideoRendererModeEnhanced:
            return @"Enhanced";
        case MLRequestedVideoRendererModeNative:
            return @"Native";
        case MLRequestedVideoRendererModeCompatibility:
            return @"Compatibility";
    }
}

- (NSString *)activeRendererModeName:(MLActiveVideoRendererMode)mode
{
    switch (mode) {
        case MLActiveVideoRendererModeEnhanced:
            return @"Enhanced";
        case MLActiveVideoRendererModeNative:
            return @"Native";
        case MLActiveVideoRendererModeCompatibility:
            return @"Compatibility";
        case MLActiveVideoRendererModeUnknown:
        default:
            return @"Unknown";
    }
}

- (void)teardownDecompressionSession
{
    if (_decompressionSession) {
        VTDecompressionSessionInvalidate(_decompressionSession);
        CFRelease(_decompressionSession);
        _decompressionSession = NULL;
    }
}

- (void)clearCurrentFrame
{
    @synchronized(self) {
        if (_currentFrame) {
            CVBufferRelease(_currentFrame);
            _currentFrame = NULL;
        }
        _currentFramePresentationTimeStamp = kCMTimeInvalid;
        _currentFrameEnqueueTimeMs = 0;
        _currentFrameNumber = 0;
        _currentFrameSequence = 0;
        _lastPresentedFrameSequence = 0;
        _deferredCurrentSourceSequence = 0;
        _pendingInterpolatedPresented = NO;
        _pendingInterpolatedForSourceSequence = 0;
        _pendingInterpolatedEnqueueTimeMs = 0;
        _pendingInterpolatedFrameNumber = 0;
        if (_pendingInterpolatedFrame) {
            CVBufferRelease(_pendingInterpolatedFrame);
            _pendingInterpolatedFrame = NULL;
        }
        if (_previousInterpolationSourceFrame) {
            CVBufferRelease(_previousInterpolationSourceFrame);
            _previousInterpolationSourceFrame = NULL;
        }
    }
}

- (void)recordRenderedFrameSampleAtTimeMs:(uint64_t)renderSampleNowMs
                            enqueueTimeMs:(uint64_t)enqueueTimeMs
{
    if (_lastRenderedSampleTimeMs != 0 && renderSampleNowMs > _lastRenderedSampleTimeMs) {
        uint64_t frameIntervalMs = renderSampleNowMs - _lastRenderedSampleTimeMs;
        if (frameIntervalMs > UINT16_MAX) {
            frameIntervalMs = UINT16_MAX;
        }
        _renderIntervalSamples[_renderIntervalSampleIndex] = (uint16_t)frameIntervalMs;
        _renderIntervalSampleIndex = (_renderIntervalSampleIndex + 1) % kMLRenderIntervalSampleCapacity;
        if (_renderIntervalSampleCount < kMLRenderIntervalSampleCapacity) {
            _renderIntervalSampleCount++;
        }
    }
    _lastRenderedSampleTimeMs = renderSampleNowMs;

    _activeWndVideoStats.renderedFrames++;
    if (enqueueTimeMs != 0 && renderSampleNowMs >= enqueueTimeMs) {
        _activeWndVideoStats.totalRenderTime += renderSampleNowMs - enqueueTimeMs;
    }

    VideoStats snapshotStats = _activeWndVideoStats;
    snapshotStats.jitterMs = _jitterMsEstimate;
    snapshotStats.renderedFpsOnePercentLow = MLComputeRenderedOnePercentLowFps(_renderIntervalSamples,
                                                                               _renderIntervalSampleCount);
    snapshotStats.lastUpdatedTimestamp = renderSampleNowMs;
    _videoStats = snapshotStats;
}

- (void)releasePreviousEnhancedFrames
{
    if (_previousEnhancedSourceFrame) {
        CVBufferRelease(_previousEnhancedSourceFrame);
        _previousEnhancedSourceFrame = NULL;
    }
    if (_previousEnhancedOutputFrame) {
        CVBufferRelease(_previousEnhancedOutputFrame);
        _previousEnhancedOutputFrame = NULL;
    }
}

- (void)releaseFrameInterpolationFrames
{
    @synchronized(self) {
        if (_previousInterpolationSourceFrame) {
            CVBufferRelease(_previousInterpolationSourceFrame);
            _previousInterpolationSourceFrame = NULL;
        }
        if (_pendingInterpolatedFrame) {
            CVBufferRelease(_pendingInterpolatedFrame);
            _pendingInterpolatedFrame = NULL;
        }
        _pendingInterpolatedPresented = NO;
        _pendingInterpolatedForSourceSequence = 0;
        _pendingInterpolatedEnqueueTimeMs = 0;
        _pendingInterpolatedFrameNumber = 0;
        _deferredCurrentSourceSequence = 0;
    }
}

- (void)teardownEnhancementProcessor
{
    _enhancementWarmupGeneration += 1;
    _enhancementWarmupInFlight = NO;
    _enhancementWarmupWidth = 0;
    _enhancementWarmupHeight = 0;
    _enhancementWarmupScaleFactor = 0.0f;
    _enhancementWarmupEngine = MLActiveVideoEnhancementEngineNone;
    if (_frameProcessor != nil && [_frameProcessor respondsToSelector:@selector(endSession)]) {
        [_frameProcessor endSession];
    }
    _frameProcessor = nil;
    _frameProcessorConfiguration = nil;
    _frameProcessorEngine = MLActiveVideoEnhancementEngineNone;
    _frameProcessorInputWidth = 0;
    _frameProcessorInputHeight = 0;
    _frameProcessorScaleFactor = 0.0f;

    if (_frameProcessorOutputPool != NULL) {
        CFRelease(_frameProcessorOutputPool);
        _frameProcessorOutputPool = NULL;
    }

    [self releasePreviousEnhancedFrames];
    _activeEnhancementEngine = MLActiveVideoEnhancementEngineNone;
    _lastLoggedEnhancementEngine = MLActiveVideoEnhancementEngineNone;
    [self publishVideoEnhancementRuntimeStatusSummary:MLVideoEnhancementEngineName(MLActiveVideoEnhancementEngineNone)
                                               detail:@"Video Enhancement Runtime Detail Off"];
}

- (void)teardownFrameInterpolationProcessor
{
    _frameInterpolationWarmupGeneration += 1;
    _frameInterpolationWarmupInFlight = NO;
    _frameInterpolationWarmupWidth = 0;
    _frameInterpolationWarmupHeight = 0;
    if (_frameInterpolationProcessor != nil &&
        [_frameInterpolationProcessor respondsToSelector:@selector(endSession)]) {
        [_frameInterpolationProcessor endSession];
    }
    _frameInterpolationProcessor = nil;
    _frameInterpolationConfiguration = nil;
    _frameInterpolationInputWidth = 0;
    _frameInterpolationInputHeight = 0;
    _frameInterpolationSourcePixelFormat = 0;
    _activeFrameInterpolationEngine = MLActiveVideoFrameInterpolationEngineNone;
    _lastLoggedFrameInterpolationEngine = MLActiveVideoFrameInterpolationEngineNone;
    [self publishVideoFrameInterpolationRuntimeStatusSummary:MLVideoFrameInterpolationEngineName(MLActiveVideoFrameInterpolationEngineNone)
                                                      detail:@"Video Frame Interpolation Runtime Detail Off"];

    if (_frameInterpolationOutputPool != NULL) {
        CFRelease(_frameInterpolationOutputPool);
        _frameInterpolationOutputPool = NULL;
    }

    [self releaseFrameInterpolationFrames];
}

- (void)teardownHDRPresentationResources
{
    _hdrEDRMetadata = nil;
    _hdrOutputUsesEDR = NO;
    _hdrToneMapToSDR = NO;
    _hdrUsesTransferMetadataPresentation = NO;
    _hdrDisplayHeadroom = 1.0f;
    _preparedHDRDisplayStateValid = NO;
    _preparedHDRDisplayHasEDRHeadroom = NO;
    _preparedHDRDisplaySupportsEDRPresentation = NO;
    _preparedHDRDisplayID = 0;
    if (_hdrLinearColorSpace != NULL) {
        CGColorSpaceRelease(_hdrLinearColorSpace);
        _hdrLinearColorSpace = NULL;
    }
    if (_hdrTransferColorSpace != NULL) {
        CGColorSpaceRelease(_hdrTransferColorSpace);
        _hdrTransferColorSpace = NULL;
    }
    if (_hdrSDROutputColorSpace != NULL) {
        CGColorSpaceRelease(_hdrSDROutputColorSpace);
        _hdrSDROutputColorSpace = NULL;
    }
}

- (void)teardownNativePresentationResources
{
    if (_nativeDisplayColorSpace != NULL) {
        CGColorSpaceRelease(_nativeDisplayColorSpace);
        _nativeDisplayColorSpace = NULL;
    }
    if (_nativeMasteringDisplayColorVolume != NULL) {
        CFRelease(_nativeMasteringDisplayColorVolume);
        _nativeMasteringDisplayColorVolume = NULL;
    }
    if (_nativeContentLightLevelInfo != NULL) {
        CFRelease(_nativeContentLightLevelInfo);
        _nativeContentLightLevelInfo = NULL;
    }
    if (_nativeImageFormatDesc != NULL) {
        CFRelease(_nativeImageFormatDesc);
        _nativeImageFormatDesc = NULL;
    }
}

- (void)prepareNativePresentationResources
{
    [self teardownNativePresentationResources];

    _nativeDisplayColorSpace = MLCreateTransferColorSpace(_enableHdr ? _hdrTransferMode : MLHDRTransferModeSDR);
    if (_nativeDisplayColorSpace == NULL && _enableHdr) {
        _nativeDisplayColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2020);
    }
    if (_nativeDisplayColorSpace == NULL) {
        _nativeDisplayColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    }

    if (!_enableHdr) {
        return;
    }

    SS_HDR_METADATA hostHdrMetadata;
    BOOL hasHostHdrMetadata = MLGetHostHdrMetadataSnapshot(&hostHdrMetadata);
    float resolvedMinLuminance = _hdrMinLuminance;
    float resolvedMaxLuminance = _hdrMaxLuminance;
    float resolvedMaxAverageLuminance = _hdrMaxAverageLuminance;
    [self copyResolvedHDRStaticMetadataWithHostMetadata:&hostHdrMetadata
                                        hasHostMetadata:hasHostHdrMetadata
                                         displayInfoOut:&_nativeMasteringDisplayColorVolume
                                         contentInfoOut:&_nativeContentLightLevelInfo
                                           minLuminance:&resolvedMinLuminance
                                           maxLuminance:&resolvedMaxLuminance
                                 maxAverageLuminance:&resolvedMaxAverageLuminance];
}

- (void)applyNativePresentationAttachmentsToImageBuffer:(CVImageBufferRef)imageBuffer
{
    if (imageBuffer == NULL) {
        return;
    }

    if (_nativeDisplayColorSpace == NULL) {
        [self prepareNativePresentationResources];
    }

    if (_nativeDisplayColorSpace != NULL) {
        CVBufferSetAttachment(imageBuffer,
                              kCVImageBufferCGColorSpaceKey,
                              _nativeDisplayColorSpace,
                              kCVAttachmentMode_ShouldPropagate);
    }

    if (!_enableHdr) {
        return;
    }

    CVBufferSetAttachment(imageBuffer,
                          kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_2020,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(imageBuffer,
                          kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_2020,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(imageBuffer,
                          kCVImageBufferTransferFunctionKey,
                          _hdrTransferMode == MLHDRTransferModeHLG
                            ? kCVImageBufferTransferFunction_ITU_R_2100_HLG
                            : kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                          kCVAttachmentMode_ShouldPropagate);

    if (_nativeMasteringDisplayColorVolume != NULL) {
        CVBufferSetAttachment(imageBuffer,
                              kCVImageBufferMasteringDisplayColorVolumeKey,
                              _nativeMasteringDisplayColorVolume,
                              kCVAttachmentMode_ShouldPropagate);
    }
    if (_nativeContentLightLevelInfo != NULL) {
        CVBufferSetAttachment(imageBuffer,
                              kCVImageBufferContentLightLevelInfoKey,
                              _nativeContentLightLevelInfo,
                              kCVAttachmentMode_ShouldPropagate);
    }
}

- (BOOL)prepareHDRPresentationResources
{
    [self teardownHDRPresentationResources];

    if (!_enableHdr) {
        return YES;
    }

    SS_HDR_METADATA hostHdrMetadata;
    BOOL hasHostHdrMetadata = MLGetHostHdrMetadataSnapshot(&hostHdrMetadata);
    CFDataRef resolvedDisplayInfo = NULL;
    CFDataRef resolvedContentInfo = NULL;
    [self copyResolvedHDRStaticMetadataWithHostMetadata:&hostHdrMetadata
                                        hasHostMetadata:hasHostHdrMetadata
                                         displayInfoOut:&resolvedDisplayInfo
                                         contentInfoOut:&resolvedContentInfo
                                           minLuminance:&_hdrMinLuminance
                                           maxLuminance:&_hdrMaxLuminance
                                 maxAverageLuminance:&_hdrMaxAverageLuminance];

    _hdrTransferColorSpace = MLCreateTransferColorSpace(_hdrTransferMode);
    if (_hdrTransferColorSpace == NULL && _enableHdr) {
        _hdrTransferColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2020);
    }
    if (_hdrTransferColorSpace == NULL) {
        Log(LOG_E, @"[video] Failed to create HDR transfer output colorspace for transfer=%@",
            MLHDRTransferModeName(_hdrTransferMode));
        if (resolvedDisplayInfo != NULL) {
            CFRelease(resolvedDisplayInfo);
        }
        if (resolvedContentInfo != NULL) {
            CFRelease(resolvedContentInfo);
        }
        return NO;
    }

    NSScreen *screen = _view.window.screen ?: NSScreen.mainScreen;
    CGFloat potentialEDR = 1.0;
    CGFloat currentEDR = 1.0;
    CGFloat referenceEDR = 0.0;
    CGDirectDisplayID displayId = screen != nil ? getDisplayID(screen) : 0;
    if (screen != nil) {
        if (@available(macOS 10.15, *)) {
            potentialEDR = screen.maximumPotentialExtendedDynamicRangeColorComponentValue;
            currentEDR = screen.maximumExtendedDynamicRangeColorComponentValue;
            referenceEDR = screen.maximumReferenceExtendedDynamicRangeColorComponentValue;
        } else if (@available(macOS 10.11, *)) {
            currentEDR = screen.maximumExtendedDynamicRangeColorComponentValue;
            potentialEDR = currentEDR;
        }
    }

    const BOOL screenHasActiveEDRHeadroom = (currentEDR > 1.05f);
    const BOOL screenSupportsEDRPresentation = (potentialEDR > 1.05f) || (referenceEDR > 0.0f);
    const float targetEDRHeadroom = screenSupportsEDRPresentation
        ? MLResolvedEDRHeadroomForStrategy(_hdrEdrStrategy, (float)currentEDR, (float)potentialEDR)
        : fmaxf((float)currentEDR, 1.0f);
    _hdrDisplayHeadroom = targetEDRHeadroom;
    _preparedHDRDisplayStateValid = YES;
    _preparedHDRDisplayHasEDRHeadroom = screenSupportsEDRPresentation;
    _preparedHDRDisplaySupportsEDRPresentation = screenSupportsEDRPresentation;
    _preparedHDRDisplayID = displayId;

    // Use the display capability, not the currently-active headroom, to decide whether
    // we should build the true EDR presentation path. `currentEDR` only rises after a
    // layer already requests HDR/EDR, so treating it as a capability check traps us in
    // the transfer-only path on HDR displays.
    _hdrOutputUsesEDR = screenSupportsEDRPresentation;
    _hdrUsesTransferMetadataPresentation = NO;
    _hdrToneMapToSDR = !screenSupportsEDRPresentation;

    if (_hdrToneMapToSDR) {
        _hdrSDROutputColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
        if (_hdrSDROutputColorSpace == NULL) {
            _hdrSDROutputColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        }
        if (_hdrSDROutputColorSpace == NULL) {
            Log(LOG_E, @"[video] Failed to create SDR output colorspace for HDR tone mapping");
            return NO;
        }

        Log(LOG_I, @"[video] Enhanced HDR output is using explicit SDR tone mapping: screen=%@ potentialEDR=%.2f currentEDR=%.2f referenceEDR=%.2f transfer=%@ metadataSource=%ld tonePolicy=%ld",
            screen.localizedName ?: @"Unknown",
            potentialEDR,
            currentEDR,
            referenceEDR,
            MLHDRTransferModeName(_hdrTransferMode),
            (long)_hdrMetadataSourceMode,
            (long)_hdrToneMappingPolicy);
        return YES;
    }

    if (_hdrUsesTransferMetadataPresentation) {
        Log(LOG_I, @"[video] Enhanced HDR output is using transfer-colorspace + metadata presentation: screen=%@ potentialEDR=%.2f currentEDR=%.2f referenceEDR=%.2f transfer=%@",
            screen.localizedName ?: @"Unknown",
            potentialEDR,
            currentEDR,
            referenceEDR,
            MLHDRTransferModeName(_hdrTransferMode));
        return YES;
    }

    if (!_hdrOutputUsesEDR) {
        Log(LOG_I, @"[video] Enhanced HDR output is using transfer-colorspace presentation: screen=%@ potentialEDR=%.2f currentEDR=%.2f referenceEDR=%.2f transfer=%@",
            screen.localizedName ?: @"Unknown",
            potentialEDR,
            currentEDR,
            referenceEDR,
            MLHDRTransferModeName(_hdrTransferMode));
        return YES;
    }

    if (!MLEnhancedHDRPresentationIsSupported()) {
        return NO;
    }

    _hdrLinearColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearITUR_2020);
    if (_hdrLinearColorSpace == NULL) {
        _hdrLinearColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3);
    }
    if (_hdrLinearColorSpace == NULL) {
        Log(LOG_E, @"[video] Failed to create an HDR-capable linear output colorspace");
        return NO;
    }

    if (_hdrTransferMode == MLHDRTransferModeHLG) {
        if (@available(macOS 10.15, *)) {
            if (@available(macOS 14.0, *)) {
                CFDataRef ambientViewingEnvironment = MLCreateHLGAmbientViewingEnvironmentData(_hdrHlgViewingEnvironment);
                if (ambientViewingEnvironment != NULL) {
                    _hdrEDRMetadata = [CAEDRMetadata HLGMetadataWithAmbientViewingEnvironment:(__bridge NSData *)ambientViewingEnvironment];
                    CFRelease(ambientViewingEnvironment);
                }
            }
            if (_hdrEDRMetadata == nil) {
                _hdrEDRMetadata = CAEDRMetadata.HLGMetadata;
            }
        }
    } else {
        if (@available(macOS 10.15, *)) {
            if (resolvedDisplayInfo != NULL || resolvedContentInfo != NULL) {
                _hdrEDRMetadata = [CAEDRMetadata HDR10MetadataWithDisplayInfo:(__bridge NSData *)resolvedDisplayInfo
                                                                  contentInfo:(__bridge NSData *)resolvedContentInfo
                                                           opticalOutputScale:fmaxf(_hdrOpticalOutputScale, 1.0f)];
            }
            if (_hdrEDRMetadata == nil) {
                _hdrEDRMetadata = [CAEDRMetadata HDR10MetadataWithMinLuminance:fmaxf(_hdrMinLuminance, 0.0f)
                                                                  maxLuminance:fmaxf(_hdrMaxLuminance, 100.0f)
                                                            opticalOutputScale:fmaxf(_hdrOpticalOutputScale, 1.0f)];
            }
        }
    }

    if (resolvedDisplayInfo != NULL) {
        CFRelease(resolvedDisplayInfo);
    }
    if (resolvedContentInfo != NULL) {
        CFRelease(resolvedContentInfo);
    }

    if (_hdrEDRMetadata == nil) {
        Log(LOG_E, @"[video] Failed to create HDR EDR metadata for transfer=%@",
            MLHDRTransferModeName(_hdrTransferMode));
        return NO;
    }

    Log(LOG_I, @"[video] Enhanced HDR EDR presentation armed: transfer=%@ scale=%.2f min=%.4f max=%.2f maxAvg=%.2f targetHeadroom=%.2f currentEDR=%.2f potentialEDR=%.2f referenceEDR=%.2f activeBeforeArm=%d metadataSource=%ld edrStrategy=%ld tonePolicy=%ld",
        MLHDRTransferModeName(_hdrTransferMode),
        _hdrOpticalOutputScale,
        _hdrMinLuminance,
        _hdrMaxLuminance,
        _hdrMaxAverageLuminance,
        _hdrDisplayHeadroom,
        currentEDR,
        potentialEDR,
        referenceEDR,
        screenHasActiveEDRHeadroom ? 1 : 0,
        (long)_hdrMetadataSourceMode,
        (long)_hdrEdrStrategy,
        (long)_hdrToneMappingPolicy);
    return YES;
}

- (BOOL)currentDisplayHasActiveEDRHeadroom
{
    NSScreen *screen = _view.window.screen ?: NSScreen.mainScreen;
    CGFloat currentEDR = 1.0;
    if (screen != nil) {
        if (@available(macOS 10.15, *)) {
            currentEDR = screen.maximumExtendedDynamicRangeColorComponentValue;
        } else if (@available(macOS 10.11, *)) {
            currentEDR = screen.maximumExtendedDynamicRangeColorComponentValue;
        }
    }

    return currentEDR > 1.05;
}

- (BOOL)currentDisplaySupportsEDRPresentation
{
    NSScreen *screen = _view.window.screen ?: NSScreen.mainScreen;
    CGFloat potentialEDR = 1.0;
    CGFloat referenceEDR = 0.0;
    if (screen != nil) {
        if (@available(macOS 10.15, *)) {
            potentialEDR = screen.maximumPotentialExtendedDynamicRangeColorComponentValue;
            referenceEDR = screen.maximumReferenceExtendedDynamicRangeColorComponentValue;
        } else if (@available(macOS 10.11, *)) {
            potentialEDR = screen.maximumExtendedDynamicRangeColorComponentValue;
        }
    }

    return potentialEDR > 1.05 || referenceEDR > 0.0;
}

- (void)applyHDRPresentationStateToMetalLayer:(CAMetalLayer *)metalLayer
{
    if (metalLayer == nil) {
        return;
    }

    if (@available(macOS 26.0, *)) {
        if (_enableHdr && _hdrOutputUsesEDR) {
            metalLayer.preferredDynamicRange = CADynamicRangeHigh;
            metalLayer.contentsHeadroom = MAX(_hdrDisplayHeadroom, 1.0f);
        } else if (_enableHdr && _hdrUsesTransferMetadataPresentation) {
            metalLayer.preferredDynamicRange = CADynamicRangeAutomatic;
            metalLayer.contentsHeadroom = 0.0f;
        } else {
            metalLayer.preferredDynamicRange = CADynamicRangeStandard;
            metalLayer.contentsHeadroom = 0.0f;
        }
    }

    if (@available(macOS 15.0, *)) {
        metalLayer.toneMapMode = (_enableHdr && (_hdrUsesTransferMetadataPresentation || _hdrOutputUsesEDR))
            ? CAToneMapModeIfSupported
            : CAToneMapModeAutomatic;
    }

    if (_enableHdr && _hdrToneMapToSDR) {
        metalLayer.wantsExtendedDynamicRangeContent = NO;
        metalLayer.colorspace = _hdrSDROutputColorSpace;
        if (@available(macOS 10.15, *)) {
            metalLayer.EDRMetadata = nil;
        }
    } else if (_enableHdr && _hdrUsesTransferMetadataPresentation) {
        metalLayer.wantsExtendedDynamicRangeContent = NO;
        metalLayer.colorspace = _hdrTransferColorSpace;
        if (@available(macOS 10.15, *)) {
            metalLayer.EDRMetadata = _hdrEDRMetadata;
        }
    } else if (_enableHdr && _hdrOutputUsesEDR) {
        metalLayer.wantsExtendedDynamicRangeContent = YES;
        metalLayer.colorspace = _hdrLinearColorSpace;
        if (@available(macOS 10.15, *)) {
            metalLayer.EDRMetadata = _hdrEDRMetadata;
        }
    } else if (_enableHdr) {
        const BOOL nonEDRHLGPresentation = (_hdrTransferMode == MLHDRTransferModeHLG &&
                                            !_preparedHDRDisplayHasEDRHeadroom);
        metalLayer.wantsExtendedDynamicRangeContent = nonEDRHLGPresentation ? NO : YES;
        metalLayer.colorspace = _hdrTransferColorSpace;
        if (@available(macOS 10.15, *)) {
            metalLayer.EDRMetadata = nil;
        }
    } else {
        metalLayer.wantsExtendedDynamicRangeContent = NO;
        metalLayer.colorspace = nil;
        if (@available(macOS 10.15, *)) {
            metalLayer.EDRMetadata = nil;
        }
    }
}

- (CGSize)updatePreferredEnhancedDrawableSizeForView:(MTKView *)view
                                         sourceWidth:(NSUInteger)sourceWidth
                                        sourceHeight:(NSUInteger)sourceHeight
{
    CGSize currentSize = view.drawableSize;
    CGFloat maxWidth = MAX(currentSize.width, 1.0);
    CGFloat maxHeight = MAX(currentSize.height, 1.0);
    if (!_enableHdr || sourceWidth == 0 || sourceHeight == 0) {
        return CGSizeMake(maxWidth, maxHeight);
    }

    CGFloat scale = MIN(maxWidth / (CGFloat)sourceWidth, maxHeight / (CGFloat)sourceHeight);
    if (!isfinite(scale) || scale <= 0.0) {
        scale = 1.0;
    }
    scale = MIN(scale, 1.0);

    NSUInteger desiredWidth = MAX((NSUInteger)1, (NSUInteger)floor((CGFloat)sourceWidth * scale));
    NSUInteger desiredHeight = MAX((NSUInteger)1, (NSUInteger)floor((CGFloat)sourceHeight * scale));
    CGSize desiredSize = CGSizeMake((CGFloat)desiredWidth, (CGFloat)desiredHeight);

    if (fabs(currentSize.width - desiredSize.width) > 0.5 ||
        fabs(currentSize.height - desiredSize.height) > 0.5) {
        view.drawableSize = desiredSize;
        currentSize = view.drawableSize;
    }

    NSUInteger actualWidth = MAX((NSUInteger)1, (NSUInteger)llround(currentSize.width));
    NSUInteger actualHeight = MAX((NSUInteger)1, (NSUInteger)llround(currentSize.height));
    if (actualWidth != _lastLoggedDrawableWidth || actualHeight != _lastLoggedDrawableHeight) {
        Log(LOG_I, @"[video] Enhanced drawable size=%zux%zu source=%zux%zu view=%0.fx%0.f hdr=%d",
            actualWidth,
            actualHeight,
            sourceWidth,
            sourceHeight,
            maxWidth,
            maxHeight,
            _enableHdr ? 1 : 0);
        _lastLoggedDrawableWidth = actualWidth;
        _lastLoggedDrawableHeight = actualHeight;
    }

    return CGSizeMake((CGFloat)actualWidth, (CGFloat)actualHeight);
}

- (id<MTLTexture>)intermediateTextureForWidth:(NSUInteger)width
                                       height:(NSUInteger)height
                                  pixelFormat:(MTLPixelFormat)pixelFormat
{
    if (_intermediateTexture != nil &&
        _intermediateTexture.width == width &&
        _intermediateTexture.height == height &&
        _intermediateTexture.pixelFormat == pixelFormat) {
        return _intermediateTexture;
    }

    MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixelFormat
                                                          width:width
                                                         height:height
                                                      mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
    desc.storageMode = MTLStorageModePrivate;
    _intermediateTexture = [_device newTextureWithDescriptor:desc];
    return _intermediateTexture;
}

- (NSString *)requestedEnhancementModeName:(MLRequestedVideoEnhancementMode)mode
{
    switch (mode) {
        case MLRequestedVideoEnhancementModeAuto:
            return @"Auto";
        case MLRequestedVideoEnhancementModeVTLowLatencySuperResolution:
            return @"VT Low-Latency Super Resolution";
        case MLRequestedVideoEnhancementModeVTQualitySuperResolution:
            return @"VT Quality Super Resolution";
        case MLRequestedVideoEnhancementModeMetalFXQuality:
            return @"MetalFX Spatial (Quality)";
        case MLRequestedVideoEnhancementModeMetalFXPerformance:
            return @"MetalFX Spatial (Performance)";
        case MLRequestedVideoEnhancementModeBasicScaling:
            return @"Basic Scaling";
        case MLRequestedVideoEnhancementModeOff:
        default:
            return @"Off";
    }
}

- (void)logActiveEnhancementEngine:(MLActiveVideoEnhancementEngine)engine
                            reason:(NSString *)reason
{
    [self publishVideoEnhancementRuntimeStatusSummary:MLVideoEnhancementEngineName(engine)
                                               detail:[self runtimeDetailKeyForEnhancementEngine:engine
                                                                                       reason:reason]];

    if (_lastLoggedEnhancementEngine == engine) {
        return;
    }

    _lastLoggedEnhancementEngine = engine;
    Log(LOG_I, @"[video] enhancement requested=%@ active=%@ reason=%@",
        [self requestedEnhancementModeName:_requestedEnhancementMode],
        MLVideoEnhancementEngineName(engine),
        reason ?: @"");
}

- (NSString *)requestedFrameInterpolationModeName:(MLRequestedVideoFrameInterpolationMode)mode
{
    switch (mode) {
        case MLRequestedVideoFrameInterpolationModeVTLowLatency:
            return @"VT Low-Latency Frame Interpolation";
        case MLRequestedVideoFrameInterpolationModeOff:
        default:
            return @"Off";
    }
}

- (void)logActiveFrameInterpolationEngine:(MLActiveVideoFrameInterpolationEngine)engine
                                   reason:(NSString *)reason
{
    [self publishVideoFrameInterpolationRuntimeStatusSummary:MLVideoFrameInterpolationEngineName(engine)
                                                      detail:[self runtimeDetailKeyForFrameInterpolationEngine:engine
                                                                                                       reason:reason]];

    if (_lastLoggedFrameInterpolationEngine == engine) {
        return;
    }

    _lastLoggedFrameInterpolationEngine = engine;
    Log(LOG_I, @"[video] frame interpolation requested=%@ active=%@ reason=%@",
        [self requestedFrameInterpolationModeName:_requestedFrameInterpolationMode],
        MLVideoFrameInterpolationEngineName(engine),
        reason ?: @"");
}

- (void)requestEnhancedDraw
{
    if (_activeRendererMode != MLActiveVideoRendererModeEnhanced || _metalView == nil) {
        return;
    }

    if (!_metalView.isPaused) {
        return;
    }

    @synchronized(self) {
        if (_metalDrawScheduled) {
            return;
        }
        _metalDrawScheduled = YES;
    }

    void (^drawBlock)(void) = ^{
        @synchronized(self) {
            self->_metalDrawScheduled = NO;
        }

        if (self->_activeRendererMode == MLActiveVideoRendererModeEnhanced && self->_metalView != nil) {
            [self->_metalView draw];
        }
    };

    if ([NSThread isMainThread]) {
        drawBlock();
        return;
    }

    CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
    if (mainRunLoop != NULL) {
        CFRunLoopPerformBlock(mainRunLoop, kCFRunLoopCommonModes, drawBlock);
        CFRunLoopWakeUp(mainRunLoop);
    } else {
        dispatch_async(dispatch_get_main_queue(), drawBlock);
    }
}

- (void)publishVideoRuntimeStatusSummary:(NSString *)summaryKey
                                  detail:(NSString *)detailKey
{
    NSString *hostKey = _runtimeHostKey ?: @"__global__";
    [SettingsClass updateVideoRuntimeStatusFor:hostKey summaryKey:summaryKey detailKey:detailKey];
}

- (void)publishVideoEnhancementRuntimeStatusSummary:(NSString *)summaryKey
                                             detail:(NSString *)detailKey
{
    NSString *hostKey = _runtimeHostKey ?: @"__global__";
    [SettingsClass updateVideoEnhancementRuntimeStatusFor:hostKey summaryKey:summaryKey detailKey:detailKey];
}

- (void)publishVideoFrameInterpolationRuntimeStatusSummary:(NSString *)summaryKey
                                                    detail:(NSString *)detailKey
{
    NSString *hostKey = _runtimeHostKey ?: @"__global__";
    [SettingsClass updateVideoFrameInterpolationRuntimeStatusFor:hostKey summaryKey:summaryKey detailKey:detailKey];
}

- (NSString *)runtimeDetailKeyForEnhancementEngine:(MLActiveVideoEnhancementEngine)engine
                                            reason:(NSString *)reason
{
    NSString *normalizedReason = reason.lowercaseString ?: @"";
    if ([normalizedReason containsString:@"warmup in progress"]) {
        return @"Video Enhancement Runtime Detail Warmup";
    }
    if (engine == MLActiveVideoEnhancementEngineNone) {
        return @"Video Enhancement Runtime Detail Off";
    }
    if ([normalizedReason containsString:@"fell back"] ||
        [normalizedReason containsString:@"fallback"] ||
        [normalizedReason containsString:@"temporarily using"]) {
        return @"Video Enhancement Runtime Detail Fallback";
    }
    return @"Video Enhancement Runtime Detail Active";
}

- (NSString *)runtimeDetailKeyForFrameInterpolationEngine:(MLActiveVideoFrameInterpolationEngine)engine
                                                    reason:(NSString *)reason
{
    NSString *normalizedReason = reason.lowercaseString ?: @"";
    if ([normalizedReason containsString:@"warmup in progress"]) {
        return @"Video Frame Interpolation Runtime Detail Warmup";
    }
    if (engine == MLActiveVideoFrameInterpolationEngineNone) {
        return @"Video Frame Interpolation Runtime Detail Off";
    }
    if ([normalizedReason containsString:@"fell back"] ||
        [normalizedReason containsString:@"unavailable"]) {
        return @"Video Frame Interpolation Runtime Detail Fallback";
    }
    return @"Video Frame Interpolation Runtime Detail Active";
}

- (NSString *)runtimeDetailKeyForActiveMode:(MLActiveVideoRendererMode)mode
                              requestedMode:(MLRequestedVideoRendererMode)requestedMode
{
    switch (requestedMode) {
        case MLRequestedVideoRendererModeAuto:
            switch (mode) {
                case MLActiveVideoRendererModeEnhanced:
                    return @"Video Runtime Detail Auto Enhanced";
                case MLActiveVideoRendererModeNative:
                    return @"Video Runtime Detail Auto Native Fallback";
                case MLActiveVideoRendererModeCompatibility:
                    return @"Video Runtime Detail Auto Compatibility Fallback";
                default:
                    return @"Video Runtime Path Idle";
            }
        case MLRequestedVideoRendererModeEnhanced:
            switch (mode) {
                case MLActiveVideoRendererModeEnhanced:
                    return @"Video Runtime Detail Enhanced Forced";
                case MLActiveVideoRendererModeNative:
                    return @"Video Runtime Detail Enhanced Native Fallback";
                case MLActiveVideoRendererModeCompatibility:
                    return @"Video Runtime Detail Enhanced Compatibility Fallback";
                default:
                    return @"Video Runtime Path Idle";
            }
        case MLRequestedVideoRendererModeNative:
            switch (mode) {
                case MLActiveVideoRendererModeNative:
                    return @"Video Runtime Detail Native Forced";
                case MLActiveVideoRendererModeCompatibility:
                    return @"Video Runtime Detail Native Compatibility Fallback";
                default:
                    return @"Video Runtime Path Idle";
            }
        case MLRequestedVideoRendererModeCompatibility:
            return @"Video Runtime Detail Compatibility Forced";
    }
}

- (BOOL)activatePresentationPathForMode:(MLActiveVideoRendererMode)mode
{
    __block BOOL success = YES;
    void (^activateBlock)(void) = ^{
        switch (mode) {
            case MLActiveVideoRendererModeEnhanced:
                success = [self setupMetalRenderer];
                break;
            case MLActiveVideoRendererModeNative:
            case MLActiveVideoRendererModeCompatibility:
                if (self->_metalView) {
                    [self->_metalView removeFromSuperview];
                    self->_metalView.delegate = nil;
                    self->_metalView = nil;
                }
                [self reinitializeDisplayLayer];
                success = (self->displayLayer != nil);
                break;
            default:
                success = NO;
                break;
        }
    };

    if ([NSThread isMainThread]) {
        activateBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), activateBlock);
    }

    return success;
}

- (void)resolveActiveRendererModeForStreamConfig:(StreamConfiguration *)streamConfig
{
    _runtimeHostKey = streamConfig.hostUUID.length > 0 ? streamConfig.hostUUID : @"__global__";
    _requestedRendererMode = (MLRequestedVideoRendererMode)MAX(0, MIN(streamConfig.videoRendererMode, MLRequestedVideoRendererModeCompatibility));

    const BOOL metalAvailable = (MLSharedMetalDevice() != nil);
    const BOOL enhancedSupported = metalAvailable && (!_enableHdr || MLEnhancedHDRPresentationIsSupported());
    MLActiveVideoRendererMode resolvedMode = MLActiveVideoRendererModeCompatibility;
    NSString *resolutionReason = @"compatibility requested";
    MLActiveVideoRendererMode candidateModes[3] = {
        MLActiveVideoRendererModeCompatibility,
        MLActiveVideoRendererModeCompatibility,
        MLActiveVideoRendererModeCompatibility,
    };
    NSUInteger candidateCount = 0;

    switch (_requestedRendererMode) {
        case MLRequestedVideoRendererModeEnhanced:
            candidateModes[candidateCount++] = MLActiveVideoRendererModeEnhanced;
            candidateModes[candidateCount++] = MLActiveVideoRendererModeCompatibility;
            break;
        case MLRequestedVideoRendererModeNative:
            candidateModes[candidateCount++] = MLActiveVideoRendererModeNative;
            candidateModes[candidateCount++] = MLActiveVideoRendererModeCompatibility;
            break;
        case MLRequestedVideoRendererModeCompatibility:
            candidateModes[candidateCount++] = MLActiveVideoRendererModeCompatibility;
            break;
        case MLRequestedVideoRendererModeAuto:
        default:
            candidateModes[candidateCount++] = MLActiveVideoRendererModeNative;
            candidateModes[candidateCount++] = MLActiveVideoRendererModeCompatibility;
            break;
    }

    for (NSUInteger index = 0; index < candidateCount; index++) {
        MLActiveVideoRendererMode candidate = candidateModes[index];
        if (candidate == MLActiveVideoRendererModeEnhanced && !enhancedSupported) {
            continue;
        }
        if ([self activatePresentationPathForMode:candidate]) {
            resolvedMode = candidate;
            break;
        }
    }

    switch (_requestedRendererMode) {
        case MLRequestedVideoRendererModeAuto:
            if (resolvedMode == MLActiveVideoRendererModeNative) {
                resolutionReason = @"Auto selected Native";
            } else {
                resolutionReason = @"Auto fell back to Compatibility";
            }
            break;
        case MLRequestedVideoRendererModeEnhanced:
            if (resolvedMode == MLActiveVideoRendererModeEnhanced) {
                resolutionReason = @"Metal renderer requested";
            } else {
                resolutionReason = @"Metal renderer unavailable; using Compatibility";
            }
            break;
        case MLRequestedVideoRendererModeNative:
            if (resolvedMode == MLActiveVideoRendererModeNative) {
                resolutionReason = @"Native renderer requested";
            } else {
                resolutionReason = @"Native renderer unavailable; using Compatibility";
            }
            break;
        case MLRequestedVideoRendererModeCompatibility:
        default:
            resolutionReason = @"compatibility requested";
            break;
    }

    _activeRendererMode = resolvedMode;
    Log(LOG_I, @"[video] renderer requested=%@ active=%@ reason=%@",
        [self requestedRendererModeName:_requestedRendererMode],
        [self activeRendererModeName:_activeRendererMode],
        resolutionReason);
    [self publishVideoRuntimeStatusSummary:MLVideoRuntimeSummaryKey(_activeRendererMode)
                                    detail:[self runtimeDetailKeyForActiveMode:_activeRendererMode requestedMode:_requestedRendererMode]];
}

- (void)fallbackToCompatibilityRendererWithReason:(NSString *)reason
{
    if (_activeRendererMode == MLActiveVideoRendererModeCompatibility) {
        return;
    }

    if (![self activatePresentationPathForMode:MLActiveVideoRendererModeCompatibility]) {
        return;
    }

    [self teardownDecompressionSession];
    [self clearCurrentFrame];
    [self teardownEnhancementProcessor];
    [self teardownFrameInterpolationProcessor];
    _activeRendererMode = MLActiveVideoRendererModeCompatibility;
    _nativeDisplayBackpressureWindowStartMs = 0;
    _nativeDisplayBackpressureBurstCount = 0;
    _nativeFallbackScheduled = NO;
    Log(LOG_W, @"[video] Falling back to Compatibility renderer%@", reason.length > 0 ? [NSString stringWithFormat:@": %@", reason] : @"");
    [self publishVideoRuntimeStatusSummary:MLVideoRuntimeSummaryKey(_activeRendererMode)
                                    detail:[self runtimeDetailKeyForActiveMode:_activeRendererMode requestedMode:_requestedRendererMode]];
}

- (void)fallbackToCompatibilityRenderer
{
    [self fallbackToCompatibilityRendererWithReason:nil];
}

- (void)setupWithVideoFormat:(int)videoFormat
                   frameRate:(int)frameRate
               upscalingMode:(int)upscalingMode
                streamConfig:(StreamConfiguration *)streamConfig
{
    self->videoFormat = videoFormat;
    self.frameRate = frameRate;
    _framePacingMode = streamConfig ? streamConfig.framePacingMode : 1;
    _smoothnessLatencyMode = streamConfig ? streamConfig.smoothnessLatencyMode : 1;
    _timingBufferLevel = streamConfig ? streamConfig.timingBufferLevel : 1;
    _timingEnableVsync = streamConfig ? streamConfig.enableVsync : NO;
    _timingPrioritizeResponsiveness = streamConfig ? streamConfig.timingPrioritizeResponsiveness : NO;
    _timingCompatibilityMode = streamConfig ? streamConfig.timingCompatibilityMode : NO;
    _timingSdrCompatibilityWorkaround = streamConfig ? streamConfig.timingSdrCompatibilityWorkaround : NO;
    _displaySyncMode = streamConfig ? (MLDisplaySyncMode)streamConfig.displaySyncMode : MLDisplaySyncModeAuto;
    _frameQueueTargetOverride = streamConfig ? streamConfig.frameQueueTarget : -1;
    _timingResponsivenessBias = streamConfig ? streamConfig.timingResponsivenessBias : (_timingPrioritizeResponsiveness ? 1 : 0);
    _allowDrawableTimeoutMode = streamConfig ? (MLAllowDrawableTimeoutMode)streamConfig.allowDrawableTimeoutMode : MLAllowDrawableTimeoutModeAuto;
    _enableHdr = streamConfig ? streamConfig.enableHdr : NO;
    _hdrTransferFunctionPreference = streamConfig ? streamConfig.hdrTransferFunction : 0;
    _hdrMetadataSourceMode = streamConfig ? (MLHDRMetadataSourceMode)streamConfig.hdrMetadataSource : MLHDRMetadataSourceModeHybrid;
    _hdrClientDisplayProfileMode = streamConfig ? (MLHDRClientDisplayProfileMode)streamConfig.hdrClientDisplayProfile : MLHDRClientDisplayProfileModeAuto;
    _hdrHlgViewingEnvironment = streamConfig ? (MLHDRHLGViewingEnvironment)streamConfig.hdrHlgViewingEnvironment : MLHDRHLGViewingEnvironmentAuto;
    _hdrEdrStrategy = streamConfig ? (MLHDREDRStrategy)streamConfig.hdrEdrStrategy : MLHDREDRStrategyAuto;
    _hdrToneMappingPolicy = streamConfig ? (MLHDRToneMappingPolicy)streamConfig.hdrToneMappingPolicy : MLHDRToneMappingPolicyAuto;
    _hdrBrightnessOverrideEnabled = streamConfig
        ? streamConfig.hdrClientDisplayProfile == MLHDRClientDisplayProfileModeManual
        : NO;
    _hdrTransferMode = MLResolveHDRTransferMode(_enableHdr, _hdrTransferFunctionPreference);
    _hdrOpticalOutputScale = streamConfig ? fmaxf((float)streamConfig.hdrOpticalOutputScale, 1.0f) : 100.0f;
    _hdrMinLuminance = streamConfig ? fmaxf((float)streamConfig.hdrManualMinBrightness, 0.0001f) : 0.001f;
    _hdrMaxLuminance = streamConfig ? fmaxf((float)streamConfig.hdrManualMaxBrightness, 100.0f) : 1000.0f;
    _hdrMaxAverageLuminance = streamConfig ? fmaxf((float)streamConfig.hdrManualMaxAverageBrightness, 1.0f) : 1000.0f;
    _hdrOpticalOutputScale = MLResolvedOpticalOutputScaleForTransfer(_hdrTransferMode,
                                                                     _hdrHlgViewingEnvironment,
                                                                     _hdrOpticalOutputScale);
    _lastLoggedPendingTarget = NSIntegerMin;
    _metalDrawScheduled = NO;
    _lastLoggedDrawableWidth = 0;
    _lastLoggedDrawableHeight = 0;
    _requestedEnhancementMode = (MLRequestedVideoEnhancementMode)MAX(0, MIN(upscalingMode, MLRequestedVideoEnhancementModeAuto));
    _activeEnhancementEngine = MLActiveVideoEnhancementEngineNone;
    _lastLoggedEnhancementEngine = MLActiveVideoEnhancementEngineNone;
    _requestedFrameInterpolationMode = streamConfig
        ? (MLRequestedVideoFrameInterpolationMode)MAX(0, MIN(streamConfig.frameInterpolationMode, MLRequestedVideoFrameInterpolationModeVTLowLatency))
        : MLRequestedVideoFrameInterpolationModeOff;
    _activeFrameInterpolationEngine = MLActiveVideoFrameInterpolationEngineNone;
    _lastLoggedFrameInterpolationEngine = MLActiveVideoFrameInterpolationEngineNone;
    _lastDisplayRefreshRate = 0.0;
    [self teardownFrameInterpolationProcessor];

    // MetalFX is macOS 13+. If user selected it on a newer OS but runs on an older
    self->_upscalingMode = upscalingMode;
    memset(&_activeWndVideoStats, 0, sizeof(_activeWndVideoStats));
    _lastFrameNumber = 0;
    _videoStats = (VideoStats){0};

    _lastFrameReceiveTimeMs = 0;
    _lastFramePresentationTimeMs = 0;
    _jitterMsEstimate = 0;
    _renderIntervalSampleCount = 0;
    _renderIntervalSampleIndex = 0;
    _lastRenderedSampleTimeMs = 0;
    _lastDequeuedFrameMs = 0;
    _lastIdleLogMs = 0;
    _remainingDequeuedFrameLogCount = 8;
    memset(_renderIntervalSamples, 0, sizeof(_renderIntervalSamples));
    _requestedRendererMode = MLRequestedVideoRendererModeAuto;
    _activeRendererMode = MLActiveVideoRendererModeUnknown;
    _lastLoggedDecodedPixelFormat = 0;
    _lastLoggedDecodedPlaneCount = 0;
    _lastNativeDisplayBackpressureLogMs = 0;
    _nativeDisplayBackpressureCount = 0;
    _nativeDisplayBackpressureWindowStartMs = 0;
    _nativeDisplayBackpressureBurstCount = 0;
    _nativeFallbackScheduled = NO;
    _rendererStartTimeMs = 0;
    _enhancedStartupPacingUntilMs = 0;
    _enhancedStartupPresentedFrameCount = 0;
    _didLogEnhancedStartupPacing = NO;
    _metalInflightLimit = 0;
    _lastDrawableUnavailableLogMs = 0;
    _drawableUnavailableCount = 0;
    _lastInflightBackpressureLogMs = 0;
    _inflightBackpressureCount = 0;

    [self clearCurrentFrame];
    [self teardownEnhancementProcessor];

    [self resolveActiveRendererModeForStreamConfig:streamConfig];
}

- (int)desiredPendingFramesForDisplayRefreshRate:(double)displayRefreshRate
{
    if (_frameQueueTargetOverride >= 0) {
        return MLClampInt((int)_frameQueueTargetOverride, 0, 3);
    }

    int target = 1;
    switch (_timingBufferLevel) {
        case 0:
            target = 0;
            break;
        case 2:
            target = 2;
            break;
        default:
            target = 1;
            break;
    }

    if (_framePacingMode == 0) {
        target = MIN(target, 1);
        if (_smoothnessLatencyMode == 0) {
            target = 0;
        }
    }

    if (_timingResponsivenessBias >= 2) {
        target -= 2;
    } else if (_timingResponsivenessBias >= 1 || _timingPrioritizeResponsiveness) {
        target -= 1;
    }

    if (_timingEnableVsync) {
        target = MAX(target, 1);
    }

    if (_timingCompatibilityMode) {
        target = MAX(target, 1);
    }

    if (_timingSdrCompatibilityWorkaround && !(videoFormat & VIDEO_FORMAT_MASK_10BIT)) {
        target += 1;
    }

    if (_activeRendererMode == MLActiveVideoRendererModeEnhanced &&
        !_timingEnableVsync &&
        !_timingCompatibilityMode) {
        target -= 1;
    }

    if (displayRefreshRate > 0 && displayRefreshRate < (double)self.frameRate * 0.90) {
        if (_timingCompatibilityMode || _timingEnableVsync) {
            target = MAX(target, 1);
        } else {
            target -= 1;
        }
    }

    if (_activeRendererMode == MLActiveVideoRendererModeEnhanced &&
        !_timingEnableVsync &&
        !_timingCompatibilityMode &&
        _enhancedStartupPresentedFrameCount < kMLEnhancedStartupPacingPresentThreshold &&
        _enhancedStartupPacingUntilMs != 0 &&
        LiGetMillis() < _enhancedStartupPacingUntilMs) {
        if (!_didLogEnhancedStartupPacing) {
            _didLogEnhancedStartupPacing = YES;
            Log(LOG_I, @"[video] Enhanced startup pacing enabled: pending=0 window=%dms",
                (int)kMLEnhancedStartupPacingWindowMs);
        }
        target = 0;
    }

    return MLClampInt(target, 0, 3);
}

- (NSUInteger)desiredEnhancedDrawableDepth
{
    if (_timingEnableVsync || _timingCompatibilityMode || _timingBufferLevel >= 2 || _smoothnessLatencyMode >= 2) {
        return 3;
    }

    return 2;
}

- (NSUInteger)desiredEnhancedInflightLimit
{
    NSUInteger drawableDepth = [self desiredEnhancedDrawableDepth];
    if (_timingEnableVsync || _timingCompatibilityMode || _timingBufferLevel >= 2 || _smoothnessLatencyMode >= 2) {
        return drawableDepth;
    }

    if (_enableHdr) {
        return MIN(drawableDepth, (NSUInteger)2);
    }

    return 1;
}

- (BOOL)setupMetalRenderer {
    // Tear down AVSBDL
    [layerContainer removeFromSuperview];
    layerContainer = nil;
    displayLayer = nil;

    if (_device == nil) {
        _device = MLSharedMetalDevice();
    }
    if (!_device) {
        Log(LOG_E, @"Failed to create Metal device");
        return NO;
    }

    if (![self prepareHDRPresentationResources]) {
        return NO;
    }

    if (_metalView == nil) {
        _metalView = [[MTKView alloc] initWithFrame:_view.bounds device:_device];
        [_view addSubview:_metalView];
    } else if (_metalView.superview != _view) {
        [_view addSubview:_metalView];
    }

    _metalView.frame = _view.bounds;
    _metalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _metalView.device = _device;
    _metalView.delegate = self;
    _metalView.paused = YES;
    _metalView.enableSetNeedsDisplay = NO;
    _metalView.framebufferOnly = NO;
    if ([_metalView respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
        _metalView.preferredFramesPerSecond = MAX(self.frameRate, 60);
    }

    MTLPixelFormat desiredPixelFormat = MTLPixelFormatBGRA8Unorm;
    if (_enableHdr && _hdrOutputUsesEDR) {
        desiredPixelFormat = MTLPixelFormatRGBA16Float;
    } else if (_enableHdr && !_hdrToneMapToSDR) {
        desiredPixelFormat = MTLPixelFormatBGR10A2Unorm;
    }
    BOOL outputFormatChanged = (_metalView.colorPixelFormat != desiredPixelFormat);
    NSUInteger desiredDrawableDepth = [self desiredEnhancedDrawableDepth];
    NSUInteger desiredInflightLimit = [self desiredEnhancedInflightLimit];
    _metalView.colorPixelFormat = desiredPixelFormat;
    _metalView.colorspace = (_enableHdr && _hdrToneMapToSDR)
        ? _hdrSDROutputColorSpace
        : ((_enableHdr && _hdrOutputUsesEDR)
            ? _hdrLinearColorSpace
            : (_enableHdr ? _hdrTransferColorSpace : nil));

    CAMetalLayer *metalLayer = (CAMetalLayer *)_metalView.layer;
    if ([metalLayer isKindOfClass:[CAMetalLayer class]]) {
        metalLayer.device = _device;
        metalLayer.presentsWithTransaction = NO;
        if (@available(macOS 10.13, *)) {
            metalLayer.allowsNextDrawableTimeout = MLBoolForDrawableTimeoutMode(_allowDrawableTimeoutMode,
                                                                               _enableHdr,
                                                                               MLActiveVideoRendererModeEnhanced);
            metalLayer.displaySyncEnabled = MLBoolForDisplaySyncMode(_displaySyncMode, _timingEnableVsync);
        }
        if (@available(macOS 10.15, *)) {
            metalLayer.maximumDrawableCount = desiredDrawableDepth;
        }
        [self applyHDRPresentationStateToMetalLayer:metalLayer];
    }

    if (_commandQueue == nil) {
        _commandQueue = [_device newCommandQueue];
    }
    if (!_commandQueue) {
        Log(LOG_E, @"Failed to create Metal command queue");
        [_metalView removeFromSuperview];
        _metalView = nil;
        return NO;
    }

    if (_textureCache == NULL) {
        CVReturn err = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, _device, nil, &_textureCache);
        if (err != kCVReturnSuccess) {
            Log(LOG_E, @"Failed to create texture cache: %d", err);
            [_metalView removeFromSuperview];
            _metalView = nil;
            _commandQueue = nil;
            return NO;
        }
    }

    if (_metalInflightSemaphore == nil || _metalInflightLimit != desiredInflightLimit) {
        _metalInflightSemaphore = dispatch_semaphore_create((long)desiredInflightLimit);
        _metalInflightLimit = desiredInflightLimit;
        Log(LOG_I, @"[video] Enhanced drawable depth=%lu inflight=%lu vsync=%d compatibility=%d buffer=%ld smoothness=%ld",
            (unsigned long)desiredDrawableDepth,
            (unsigned long)desiredInflightLimit,
            _timingEnableVsync ? 1 : 0,
            _timingCompatibilityMode ? 1 : 0,
            (long)_timingBufferLevel,
            (long)_smoothnessLatencyMode);
    }

    if (outputFormatChanged) {
        _blitRenderPipelineState = nil;
        _intermediateTexture = nil;
    }

    if (!_computePipelineState || !_blitRenderPipelineState || _blitRenderPipelinePixelFormat != desiredPixelFormat) {
        NSError *sharedPipelineError = nil;
        if (![self loadSharedMetalPipelineForPixelFormat:desiredPixelFormat error:&sharedPipelineError]) {
            if (sharedPipelineError != nil) {
                Log(LOG_W, @"[video] Shared Metal pipeline cache unavailable; compiling locally: %@", sharedPipelineError);
            }
            [self setupMetalPipeline];
        }
    }

    Log(LOG_I, @"Metal renderer initialized with upscaling mode: %d hdr=%d transfer=%@ outputFormat=%lu",
        _upscalingMode,
        _enableHdr ? 1 : 0,
        MLHDRTransferModeName(_hdrTransferMode),
        (unsigned long)desiredPixelFormat);

    if (_rendererStartTimeMs == 0) {
        [self prewarmEnhancedDrawableIfNeeded];
    }

    return YES;
}

- (void)prewarmEnhancedDrawableIfNeeded
{
    if (_metalView == nil || _commandQueue == nil) {
        return;
    }

    CAMetalLayer *metalLayer = (CAMetalLayer *)_metalView.layer;
    if (![metalLayer isKindOfClass:[CAMetalLayer class]]) {
        return;
    }

    if (_metalView.window == nil || NSIsEmptyRect(_metalView.bounds)) {
        return;
    }

    [self applyHDRPresentationStateToMetalLayer:metalLayer];
    [_metalView layoutSubtreeIfNeeded];

    id<CAMetalDrawable> drawable = [_metalView currentDrawable];
    if (drawable == nil) {
        Log(LOG_D, @"[startup] Enhanced drawable prewarm skipped because no drawable is available yet");
        return;
    }

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    if (commandBuffer == nil) {
        return;
    }

    MTLRenderPassDescriptor *passDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    passDescriptor.colorAttachments[0].texture = drawable.texture;
    passDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

    id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
    [renderEncoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];

    Log(LOG_D, @"[startup] Enhanced drawable prewarm committed");
}

- (void)refreshEnhancedHDRPresentationIfNeeded
{
    if (_activeRendererMode != MLActiveVideoRendererModeEnhanced || !_enableHdr) {
        return;
    }

    NSScreen *screen = _view.window.screen ?: NSScreen.mainScreen;
    CGDirectDisplayID displayId = screen != nil ? getDisplayID(screen) : 0;
    BOOL screenSupportsEDRPresentation = [self currentDisplaySupportsEDRPresentation];
    if (_preparedHDRDisplayStateValid &&
        screenSupportsEDRPresentation == _preparedHDRDisplayHasEDRHeadroom &&
        displayId == _preparedHDRDisplayID) {
        return;
    }

    Log(LOG_I, @"[video] Enhanced HDR display state changed; rebuilding presentation state oldDisplay=%u newDisplay=%u oldSupportsEDR=%d newSupportsEDR=%d",
        (unsigned int)_preparedHDRDisplayID,
        (unsigned int)displayId,
        _preparedHDRDisplayHasEDRHeadroom ? 1 : 0,
        screenSupportsEDRPresentation ? 1 : 0);
    [self setupMetalRenderer];
}

- (BOOL)loadSharedMetalPipelineForPixelFormat:(MTLPixelFormat)pixelFormat
                                        error:(NSError **)errorOut
{
    id<MTLDevice> sharedDevice = nil;
    id<MTLComputePipelineState> sharedComputePipeline = nil;
    id<MTLRenderPipelineState> sharedBlitPipeline = nil;
    if (!MLGetSharedMetalPipelines(pixelFormat,
                                   &sharedDevice,
                                   &sharedComputePipeline,
                                   &sharedBlitPipeline,
                                   errorOut)) {
        return NO;
    }

    _device = sharedDevice;
    _computePipelineState = sharedComputePipeline;
    _blitRenderPipelineState = sharedBlitPipeline;
    _blitRenderPipelinePixelFormat = pixelFormat;
    return YES;
}

- (void)setupMetalPipeline {
    NSError *error = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:kMetalShaderSource options:nil error:&error];
    if (!library) {
        Log(LOG_E, @"Failed to create metal library: %@", error);
        return;
    }

    id<MTLFunction> fn = [library newFunctionWithName:@"ycbcrToRgb"];
    _computePipelineState = [_device newComputePipelineStateWithFunction:fn error:&error];
    if (!_computePipelineState) {
        Log(LOG_E, @"Failed to create pipeline state: %@", error);
    }

    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"fullscreenVertex"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"textureBlitFragment"];
    MTLRenderPipelineDescriptor *renderDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    renderDescriptor.vertexFunction = vertexFunction;
    renderDescriptor.fragmentFunction = fragmentFunction;
    renderDescriptor.colorAttachments[0].pixelFormat = _metalView.colorPixelFormat;
    _blitRenderPipelineState = [_device newRenderPipelineStateWithDescriptor:renderDescriptor error:&error];
    if (!_blitRenderPipelineState) {
        Log(LOG_E, @"Failed to create blit render pipeline state: %@", error);
    } else {
        _blitRenderPipelinePixelFormat = _metalView.colorPixelFormat;
    }
}

void decompressionOutputCallback(void *decompressionOutputRefCon, void *sourceFrameRefCon, OSStatus status, VTDecodeInfoFlags infoFlags, CVImageBufferRef imageBuffer, CMTime presentationTimeStamp, CMTime presentationDuration) {
    VideoDecoderRenderer *self = (__bridge VideoDecoderRenderer *)decompressionOutputRefCon;
    MLDecodeFrameContext *frameContext = (MLDecodeFrameContext *)sourceFrameRefCon;
    if (status == noErr && imageBuffer) {
        [self handleDecompressionOutput:imageBuffer
                   presentationTimeStamp:presentationTimeStamp
                                duration:presentationDuration
                            frameContext:frameContext];
    }
    if (frameContext != NULL) {
        free(frameContext);
    }
}

- (void)enqueueDecodedImageBuffer:(CVImageBufferRef)imageBuffer
            presentationTimeStamp:(CMTime)presentationTimeStamp
                         duration:(CMTime)duration
                     frameContext:(const MLDecodeFrameContext *)frameContext
{
    (void)presentationTimeStamp;
    (void)duration;

    if (displayLayer == nil) {
        return;
    }

    if (_activeRendererMode == MLActiveVideoRendererModeNative &&
        displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        Log(LOG_W, @"[video] Native display layer entered failed state; flushing and resuming");
        [displayLayer flushAndRemoveImage];
    }

    if (_activeRendererMode == MLActiveVideoRendererModeNative && !displayLayer.readyForMoreMediaData) {
        _nativeDisplayBackpressureCount += 1;
        uint64_t nowMs = LiGetMillis();
        if (_nativeDisplayBackpressureWindowStartMs == 0 || nowMs - _nativeDisplayBackpressureWindowStartMs > 1000) {
            _nativeDisplayBackpressureWindowStartMs = nowMs;
            _nativeDisplayBackpressureBurstCount = 0;
            _nativeFallbackScheduled = NO;
        }
        _nativeDisplayBackpressureBurstCount += 1;
        if (_lastNativeDisplayBackpressureLogMs == 0 || nowMs - _lastNativeDisplayBackpressureLogMs >= 1000) {
            _lastNativeDisplayBackpressureLogMs = nowMs;
            Log(LOG_W, @"[video] Native display layer backpressure detected; dropping decoded frame count=%lu",
                (unsigned long)_nativeDisplayBackpressureCount);
            _nativeDisplayBackpressureCount = 0;
        }

        if (_nativeDisplayBackpressureBurstCount >= 8 && !_nativeFallbackScheduled) {
            _nativeFallbackScheduled = YES;
            Log(LOG_W, @"[video] Native display layer appears stalled under backpressure; flushing queued samples to recover");
            [displayLayer flush];
        }
        return;
    }

    _nativeDisplayBackpressureCount = 0;
    _nativeDisplayBackpressureWindowStartMs = 0;
    _nativeDisplayBackpressureBurstCount = 0;
    _nativeFallbackScheduled = NO;

    [self applyNativePresentationAttachmentsToImageBuffer:imageBuffer];

    if (_nativeImageFormatDesc == NULL ||
        !CMVideoFormatDescriptionMatchesImageBuffer(_nativeImageFormatDesc, imageBuffer)) {
        if (_nativeImageFormatDesc != NULL) {
            CFRelease(_nativeImageFormatDesc);
            _nativeImageFormatDesc = NULL;
        }

        OSStatus formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                                             imageBuffer,
                                                                             &_nativeImageFormatDesc);
        if (formatStatus != noErr || _nativeImageFormatDesc == NULL) {
            Log(LOG_E, @"CMVideoFormatDescriptionCreateForImageBuffer failed: %d", (int)formatStatus);
            return;
        }
    }

    CMSampleTimingInfo timing = {
        .duration = kCMTimeInvalid,
        .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
        .decodeTimeStamp = kCMTimeInvalid,
    };

    CMSampleBufferRef sampleBuffer = NULL;
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(
        kCFAllocatorDefault,
        imageBuffer,
        _nativeImageFormatDesc,
        &timing,
        &sampleBuffer);
    if (status != noErr || sampleBuffer == NULL) {
        Log(LOG_E, @"CMSampleBufferCreateReadyWithImageBuffer failed: %d", (int)status);
        return;
    }

    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
    if (attachments != NULL && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        if (dict != NULL) {
            CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        }
    }

    [displayLayer enqueueSampleBuffer:sampleBuffer];

    CFRelease(sampleBuffer);
}

- (void)handleDecompressionOutput:(CVImageBufferRef)imageBuffer
             presentationTimeStamp:(CMTime)presentationTimeStamp
                          duration:(CMTime)duration
                      frameContext:(const MLDecodeFrameContext *)frameContext
{
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer);
    size_t planeCount = CVPixelBufferGetPlaneCount(imageBuffer);
    if (_lastLoggedDecodedPixelFormat != pixelFormat || _lastLoggedDecodedPlaneCount != planeCount) {
        _lastLoggedDecodedPixelFormat = pixelFormat;
        _lastLoggedDecodedPlaneCount = planeCount;
        Log(LOG_I, @"[video] Decoded image buffer format=0x%X planes=%zu renderer=%@ hdr=%d",
            (unsigned int)pixelFormat,
            planeCount,
            [self activeRendererModeName:_activeRendererMode],
            _enableHdr ? 1 : 0);
    }

    if (_activeRendererMode == MLActiveVideoRendererModeNative) {
        [self enqueueDecodedImageBuffer:imageBuffer
                   presentationTimeStamp:presentationTimeStamp
                                duration:duration
                            frameContext:frameContext];
        return;
    }

    CVImageBufferRef previousInterpolationSourceFrame = NULL;
    uint64_t sourceSequence = 0;
    @synchronized(self) {
        if (_currentFrame) {
            CVBufferRelease(_currentFrame);
        }
        if (_pendingInterpolatedFrame) {
            CVBufferRelease(_pendingInterpolatedFrame);
            _pendingInterpolatedFrame = NULL;
        }
        _pendingInterpolatedPresented = NO;
        _pendingInterpolatedForSourceSequence = 0;
        _pendingInterpolatedEnqueueTimeMs = 0;
        _pendingInterpolatedFrameNumber = 0;
        _deferredCurrentSourceSequence = 0;
        if (_previousInterpolationSourceFrame) {
            previousInterpolationSourceFrame = CVBufferRetain(_previousInterpolationSourceFrame);
        }
        _currentFrame = CVBufferRetain(imageBuffer);
        _currentFramePresentationTimeStamp = presentationTimeStamp;
        _currentFrameEnqueueTimeMs = frameContext != NULL ? frameContext->enqueueTimeMs : 0;
        _currentFrameNumber = frameContext != NULL ? frameContext->frameNumber : 0;
        _currentFrameSequence += 1;
        sourceSequence = _currentFrameSequence;
    }

    if (_requestedFrameInterpolationMode != MLRequestedVideoFrameInterpolationModeOff &&
        previousInterpolationSourceFrame != NULL) {
        [self stageInterpolatedFrameFromPreviousSource:previousInterpolationSourceFrame
                                              toSource:imageBuffer
                                         frameSequence:sourceSequence
                                         enqueueTimeMs:(frameContext != NULL ? frameContext->enqueueTimeMs : 0)
                                          frameNumber:(frameContext != NULL ? frameContext->frameNumber : 0)
                                    displayRefreshRate:_lastDisplayRefreshRate];
        CVBufferRelease(previousInterpolationSourceFrame);
    } else if (previousInterpolationSourceFrame != NULL) {
        CVBufferRelease(previousInterpolationSourceFrame);
    } else if (_requestedFrameInterpolationMode != MLRequestedVideoFrameInterpolationModeOff) {
        _activeFrameInterpolationEngine = MLActiveVideoFrameInterpolationEngineNone;
        [self logActiveFrameInterpolationEngine:_activeFrameInterpolationEngine
                                         reason:@"waiting for a previously presented source frame"];
    }

    [self requestEnhancedDraw];
}

- (BOOL)createDecompressionSession {
    [self teardownDecompressionSession];

    VTDecompressionOutputCallbackRecord callbackRecord;
    callbackRecord.decompressionOutputCallback = decompressionOutputCallback;
    callbackRecord.decompressionOutputRefCon = (__bridge void *)self;

    NSMutableDictionary *destinationImageBufferAttributes = [@{
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    } mutableCopy];

    if (_activeRendererMode == MLActiveVideoRendererModeEnhanced) {
        if ((videoFormat & VIDEO_FORMAT_MASK_YUV444) && (videoFormat & VIDEO_FORMAT_MASK_10BIT)) {
            destinationImageBufferAttributes[(id)kCVPixelBufferPixelFormatTypeKey] =
                @(kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange);
        } else if (videoFormat & VIDEO_FORMAT_MASK_YUV444) {
            destinationImageBufferAttributes[(id)kCVPixelBufferPixelFormatTypeKey] =
                @(kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange);
        } else if (videoFormat & VIDEO_FORMAT_MASK_10BIT) {
            destinationImageBufferAttributes[(id)kCVPixelBufferPixelFormatTypeKey] =
                @(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);
        } else {
            destinationImageBufferAttributes[(id)kCVPixelBufferPixelFormatTypeKey] =
                @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
        }
    }

    OSStatus status = VTDecompressionSessionCreate(kCFAllocatorDefault,
                                                   formatDesc,
                                                   NULL,
                                                   (__bridge CFDictionaryRef)destinationImageBufferAttributes,
                                                   &callbackRecord,
                                                   &_decompressionSession);
    if (status != noErr) {
        Log(LOG_E, @"VTDecompressionSessionCreate failed: %d", (int)status);
        return NO;
    }

    status = VTSessionSetProperty(_decompressionSession,
                                  kVTDecompressionPropertyKey_RealTime,
                                  kCFBooleanTrue);
    if (status != noErr) {
        Log(LOG_W, @"Failed to enable VT realtime decode: %d", (int)status);
    }

    if (@available(macOS 11.0, *)) {
        status = VTSessionSetProperty(_decompressionSession,
                                      kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata,
                                      kCFBooleanTrue);
        if (status != noErr) {
            Log(LOG_W, @"Failed to enable per-frame HDR metadata propagation: %d", (int)status);
        }
    }
    if (@available(macOS 14.0, *)) {
        status = VTSessionSetProperty(_decompressionSession,
                                      kVTDecompressionPropertyKey_GeneratePerFrameHDRDisplayMetadata,
                                      kCFBooleanTrue);
        if (status != noErr) {
            Log(LOG_W, @"Failed to enable per-frame HDR metadata generation: %d", (int)status);
        }
    }

    CFTypeRef hardwareDecodeValue = NULL;
    status = VTSessionCopyProperty(_decompressionSession,
                                   kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                   NULL,
                                   &hardwareDecodeValue);
    if (status == noErr && hardwareDecodeValue != NULL && CFGetTypeID(hardwareDecodeValue) == CFBooleanGetTypeID()) {
        Log(LOG_I, @"[video] VT decode session ready: hardware=%d hdr=%d renderer=%@",
            CFBooleanGetValue(hardwareDecodeValue) ? 1 : 0,
            _enableHdr ? 1 : 0,
            [self activeRendererModeName:_activeRendererMode]);
        CFRelease(hardwareDecodeValue);
    } else {
        Log(LOG_I, @"[video] VT decode session ready: hardware=unknown hdr=%d renderer=%@ status=%d",
            _enableHdr ? 1 : 0,
            [self activeRendererModeName:_activeRendererMode],
            (int)status);
    }

    return YES;
}

- (float)requestedScaleFactorForSourceWidth:(NSUInteger)sourceWidth
                                 sourceHeight:(NSUInteger)sourceHeight
                                  targetWidth:(NSUInteger)targetWidth
                                 targetHeight:(NSUInteger)targetHeight
{
    if (sourceWidth == 0 || sourceHeight == 0 || targetWidth == 0 || targetHeight == 0) {
        return 1.0f;
    }

    float scaleX = (float)targetWidth / (float)sourceWidth;
    float scaleY = (float)targetHeight / (float)sourceHeight;
    if (fabsf(scaleX - scaleY) > 0.02f) {
        return 0.0f;
    }

    return scaleX;
}

- (BOOL)floatScaleFactor:(float)scaleFactor isSupportedByValues:(NSArray<NSNumber *> *)values
{
    for (NSNumber *value in values) {
        if (fabsf(value.floatValue - scaleFactor) < 0.02f) {
            return YES;
        }
    }
    return NO;
}

- (MLActiveVideoEnhancementEngine)resolveEnhancementEngineForSourceWidth:(NSUInteger)sourceWidth
                                                             sourceHeight:(NSUInteger)sourceHeight
                                                              targetWidth:(NSUInteger)targetWidth
                                                             targetHeight:(NSUInteger)targetHeight
                                                              scaleFactor:(float *)scaleFactorOut
                                                                   reason:(NSString **)reasonOut
{
    float requestedScaleFactor = [self requestedScaleFactorForSourceWidth:sourceWidth
                                                              sourceHeight:sourceHeight
                                                               targetWidth:targetWidth
                                                              targetHeight:targetHeight];
    if (scaleFactorOut != NULL) {
        *scaleFactorOut = requestedScaleFactor;
    }

    if (_requestedEnhancementMode == MLRequestedVideoEnhancementModeOff) {
        if (reasonOut != NULL) {
            *reasonOut = @"enhancement disabled";
        }
        return MLActiveVideoEnhancementEngineNone;
    }

    if (_enableHdr) {
        if (reasonOut != NULL) {
            *reasonOut = requestedScaleFactor > 1.0f
                ? @"HDR stream uses direct Metal scaling to preserve HDR output"
                : @"HDR stream bypasses post-processing to preserve HDR output";
        }
        return requestedScaleFactor > 1.0f ? MLActiveVideoEnhancementEngineBasicScaling
                                           : MLActiveVideoEnhancementEngineNone;
    }

    if (requestedScaleFactor <= 1.0f && _requestedEnhancementMode != MLRequestedVideoEnhancementModeBasicScaling) {
        if (reasonOut != NULL) {
            *reasonOut = @"target size does not require upscale";
        }
        return MLActiveVideoEnhancementEngineNone;
    }

    BOOL vtLowLatencySupported = NO;
    BOOL vtQualitySupported = NO;
    if (@available(macOS 26.0, *)) {
        vtLowLatencySupported = VTLowLatencySuperResolutionScalerConfiguration.isSupported &&
            [self floatScaleFactor:requestedScaleFactor
                 isSupportedByValues:[VTLowLatencySuperResolutionScalerConfiguration supportedScaleFactorsForFrameWidth:(NSInteger)sourceWidth
                                                                                                             frameHeight:(NSInteger)sourceHeight]];
        vtQualitySupported = VTSuperResolutionScalerConfiguration.isSupported &&
            [self floatScaleFactor:requestedScaleFactor
                 isSupportedByValues:VTSuperResolutionScalerConfiguration.supportedScaleFactors];
    }

    BOOL metalFXSupported = MLMetalFXIsSupported();

    switch (_requestedEnhancementMode) {
        case MLRequestedVideoEnhancementModeAuto:
            if (vtLowLatencySupported) {
                if (reasonOut != NULL) {
                    *reasonOut = @"Auto selected VT low-latency super resolution";
                }
                return MLActiveVideoEnhancementEngineVTLowLatencySuperResolution;
            }
            if (metalFXSupported) {
                if (reasonOut != NULL) {
                    *reasonOut = @"Auto selected MetalFX";
                }
                return MLActiveVideoEnhancementEngineMetalFXQuality;
            }
            if (reasonOut != NULL) {
                *reasonOut = @"Auto fell back to basic scaling";
            }
            return MLActiveVideoEnhancementEngineBasicScaling;
        case MLRequestedVideoEnhancementModeVTLowLatencySuperResolution:
            if (vtLowLatencySupported) {
                if (reasonOut != NULL) {
                    *reasonOut = @"VT low-latency super resolution requested";
                }
                return MLActiveVideoEnhancementEngineVTLowLatencySuperResolution;
            }
            if (metalFXSupported) {
                if (reasonOut != NULL) {
                    *reasonOut = @"VT low-latency super resolution unavailable; fell back to MetalFX";
                }
                return MLActiveVideoEnhancementEngineMetalFXQuality;
            }
            if (reasonOut != NULL) {
                *reasonOut = @"VT low-latency super resolution unavailable; fell back to basic scaling";
            }
            return MLActiveVideoEnhancementEngineBasicScaling;
        case MLRequestedVideoEnhancementModeVTQualitySuperResolution:
            if (vtQualitySupported) {
                if (reasonOut != NULL) {
                    *reasonOut = @"VT quality super resolution requested";
                }
                return MLActiveVideoEnhancementEngineVTQualitySuperResolution;
            }
            if (vtLowLatencySupported) {
                if (reasonOut != NULL) {
                    *reasonOut = @"VT quality super resolution unavailable; fell back to VT low-latency super resolution";
                }
                return MLActiveVideoEnhancementEngineVTLowLatencySuperResolution;
            }
            if (metalFXSupported) {
                if (reasonOut != NULL) {
                    *reasonOut = @"VT quality super resolution unavailable; fell back to MetalFX";
                }
                return MLActiveVideoEnhancementEngineMetalFXQuality;
            }
            if (reasonOut != NULL) {
                *reasonOut = @"VT quality super resolution unavailable; fell back to basic scaling";
            }
            return MLActiveVideoEnhancementEngineBasicScaling;
        case MLRequestedVideoEnhancementModeMetalFXQuality:
            if (metalFXSupported) {
                if (reasonOut != NULL) {
                    *reasonOut = @"MetalFX quality requested";
                }
                return MLActiveVideoEnhancementEngineMetalFXQuality;
            }
            if (reasonOut != NULL) {
                *reasonOut = @"MetalFX quality unavailable; fell back to basic scaling";
            }
            return MLActiveVideoEnhancementEngineBasicScaling;
        case MLRequestedVideoEnhancementModeMetalFXPerformance:
            if (metalFXSupported) {
                if (reasonOut != NULL) {
                    *reasonOut = @"MetalFX performance requested";
                }
                return MLActiveVideoEnhancementEngineMetalFXPerformance;
            }
            if (reasonOut != NULL) {
                *reasonOut = @"MetalFX performance unavailable; fell back to basic scaling";
            }
            return MLActiveVideoEnhancementEngineBasicScaling;
        case MLRequestedVideoEnhancementModeBasicScaling:
            if (reasonOut != NULL) {
                *reasonOut = @"basic scaling requested";
            }
            return MLActiveVideoEnhancementEngineBasicScaling;
        case MLRequestedVideoEnhancementModeOff:
        default:
            if (reasonOut != NULL) {
                *reasonOut = @"enhancement disabled";
            }
            return MLActiveVideoEnhancementEngineNone;
    }
}

- (NSDictionary *)resolvedFrameProcessorAttributesWithPreferredPixelFormat:(OSType)preferredPixelFormat
                                                             baseAttributes:(NSDictionary *)baseAttributes
{
    NSDictionary *preferredAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(preferredPixelFormat),
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };

    CFDictionaryRef resolved = NULL;
    CVReturn status = CVPixelBufferCreateResolvedAttributesDictionary(kCFAllocatorDefault,
                                                                      (__bridge CFArrayRef)@[preferredAttributes, baseAttributes ?: @{}],
                                                                      &resolved);
    if (status != kCVReturnSuccess || resolved == NULL) {
        return preferredAttributes;
    }

    return CFBridgingRelease(resolved);
}

- (BOOL)shouldUseFrameInterpolationForDisplayRefreshRate:(double)displayRefreshRate
                                                  reason:(NSString **)reasonOut
{
    if (_requestedFrameInterpolationMode == MLRequestedVideoFrameInterpolationModeOff) {
        if (reasonOut != NULL) {
            *reasonOut = @"frame interpolation disabled";
        }
        return NO;
    }

    if (_activeRendererMode != MLActiveVideoRendererModeEnhanced) {
        if (reasonOut != NULL) {
            *reasonOut = @"frame interpolation is only available in Metal Renderer";
        }
        return NO;
    }

    if (_enableHdr) {
        if (reasonOut != NULL) {
            *reasonOut = @"HDR stream keeps native Metal present path; frame interpolation stays disabled";
        }
        return NO;
    }

    if (displayRefreshRate <= 0.0) {
        if (reasonOut != NULL) {
            *reasonOut = @"display refresh rate unavailable";
        }
        return NO;
    }

    double minimumRefreshRate = MAX((double)self.frameRate * 1.5, (double)self.frameRate + 12.0);
    if (displayRefreshRate < minimumRefreshRate) {
        if (reasonOut != NULL) {
            *reasonOut = [NSString stringWithFormat:@"display %.2fHz does not have cadence headroom over stream %d FPS",
                          displayRefreshRate,
                          self.frameRate];
        }
        return NO;
    }

    return YES;
}

- (BOOL)frameInterpolationConfiguration:(VTLowLatencyFrameInterpolationConfiguration *)configuration
                 supportsSourcePixelFormat:(OSType)pixelFormat API_AVAILABLE(macos(26.0))
{
    for (NSNumber *value in configuration.frameSupportedPixelFormats) {
        if ((OSType)value.unsignedIntValue == pixelFormat) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)prepareFrameInterpolationProcessorForSourceFrame:(CVImageBufferRef)sourceFrame
{
    if (sourceFrame == NULL) {
        return NO;
    }

    if (@available(macOS 26.0, *)) {
        const NSInteger sourceWidth = (NSInteger)CVPixelBufferGetWidth(sourceFrame);
        const NSInteger sourceHeight = (NSInteger)CVPixelBufferGetHeight(sourceFrame);
        const OSType sourcePixelFormat = CVPixelBufferGetPixelFormatType(sourceFrame);

        if (_frameInterpolationProcessor != nil &&
            _frameInterpolationInputWidth == sourceWidth &&
            _frameInterpolationInputHeight == sourceHeight &&
            _frameInterpolationSourcePixelFormat == sourcePixelFormat) {
            return YES;
        }

        if (_frameInterpolationProcessor != nil &&
            _frameInterpolationInputWidth == sourceWidth &&
            _frameInterpolationInputHeight == sourceHeight &&
            _frameInterpolationSourcePixelFormat == 0 &&
            [self ensureFrameInterpolationOutputPoolForConfiguration:(VTLowLatencyFrameInterpolationConfiguration *)_frameInterpolationConfiguration
                                                   sourcePixelFormat:sourcePixelFormat]) {
            return YES;
        }

        [self requestFrameInterpolationWarmupForStreamWidth:sourceWidth
                                               streamHeight:sourceHeight];
        return NO;
    }

    return NO;
}

- (BOOL)ensureFrameInterpolationOutputPoolForConfiguration:(VTLowLatencyFrameInterpolationConfiguration *)configuration
                                         sourcePixelFormat:(OSType)sourcePixelFormat API_AVAILABLE(macos(26.0))
{
    if (configuration == nil || _frameInterpolationProcessor == nil) {
        return NO;
    }

    if (![self frameInterpolationConfiguration:configuration
                        supportsSourcePixelFormat:sourcePixelFormat]) {
        Log(LOG_W, @"[video] VT frame interpolation doesn't support source pixel format 0x%X",
            (unsigned int)sourcePixelFormat);
        return NO;
    }

    if (_frameInterpolationOutputPool != NULL &&
        _frameInterpolationSourcePixelFormat == sourcePixelFormat) {
        return YES;
    }

    if (_frameInterpolationOutputPool != NULL) {
        CFRelease(_frameInterpolationOutputPool);
        _frameInterpolationOutputPool = NULL;
    }

    NSDictionary *outputAttributes =
        [self resolvedFrameProcessorAttributesWithPreferredPixelFormat:kCVPixelFormatType_32BGRA
                                                        baseAttributes:configuration.destinationPixelBufferAttributes];
    CVPixelBufferPoolRef pool = NULL;
    CVReturn poolStatus = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                                  NULL,
                                                  (__bridge CFDictionaryRef)outputAttributes,
                                                  &pool);
    if (poolStatus != kCVReturnSuccess || pool == NULL) {
        Log(LOG_W, @"[video] Failed to create VT frame interpolation output pool: %d", (int)poolStatus);
        return NO;
    }

    _frameInterpolationOutputPool = pool;
    _frameInterpolationSourcePixelFormat = sourcePixelFormat;
    return YES;
}

- (void)requestFrameInterpolationWarmupForStreamWidth:(NSInteger)streamWidth
                                         streamHeight:(NSInteger)streamHeight
{
    if (_requestedFrameInterpolationMode != MLRequestedVideoFrameInterpolationModeVTLowLatency ||
        _activeRendererMode != MLActiveVideoRendererModeEnhanced ||
        _enableHdr ||
        streamWidth <= 0 ||
        streamHeight <= 0) {
        return;
    }

    if (@available(macOS 26.0, *)) {
        if (_frameInterpolationProcessor != nil &&
            _frameInterpolationInputWidth == streamWidth &&
            _frameInterpolationInputHeight == streamHeight) {
            return;
        }

        if (_frameInterpolationWarmupInFlight &&
            _frameInterpolationWarmupWidth == streamWidth &&
            _frameInterpolationWarmupHeight == streamHeight) {
            return;
        }

        _frameInterpolationWarmupInFlight = YES;
        _frameInterpolationWarmupWidth = streamWidth;
        _frameInterpolationWarmupHeight = streamHeight;
        NSUInteger warmupGeneration = ++_frameInterpolationWarmupGeneration;

        dispatch_async(_vtWarmupQueue, ^{
            VTLowLatencyFrameInterpolationConfiguration *configuration =
                [[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:streamWidth
                                                                            frameHeight:streamHeight
                                                                numberOfInterpolatedFrames:1];
            if (configuration == nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (warmupGeneration != self->_frameInterpolationWarmupGeneration) {
                        return;
                    }
                    self->_frameInterpolationWarmupInFlight = NO;
                });
                return;
            }

            VTFrameProcessor *processor = [[VTFrameProcessor alloc] init];
            NSError *error = nil;
            BOOL started = [processor startSessionWithConfiguration:configuration error:&error];

            dispatch_async(dispatch_get_main_queue(), ^{
                if (warmupGeneration != self->_frameInterpolationWarmupGeneration) {
                    if (started) {
                        [processor endSession];
                    }
                    return;
                }

                self->_frameInterpolationWarmupInFlight = NO;
                if (!started) {
                    Log(LOG_W, @"[video] Failed to prewarm VT frame interpolation session: %@", error);
                    return;
                }

                if (self->_frameInterpolationProcessor != nil &&
                    self->_frameInterpolationInputWidth == streamWidth &&
                    self->_frameInterpolationInputHeight == streamHeight) {
                    [processor endSession];
                    return;
                }

                NSUInteger preservedWarmupGeneration = self->_frameInterpolationWarmupGeneration;
                [self teardownFrameInterpolationProcessor];
                self->_frameInterpolationWarmupGeneration = preservedWarmupGeneration;
                self->_frameInterpolationWarmupInFlight = NO;
                self->_frameInterpolationWarmupWidth = streamWidth;
                self->_frameInterpolationWarmupHeight = streamHeight;
                self->_frameInterpolationProcessor = processor;
                self->_frameInterpolationConfiguration = configuration;
                self->_frameInterpolationInputWidth = streamWidth;
                self->_frameInterpolationInputHeight = streamHeight;
                self->_frameInterpolationSourcePixelFormat = 0;
                Log(LOG_I, @"[video] VT frame interpolation prewarmed for %ldx%ld",
                    (long)streamWidth,
                    (long)streamHeight);
            });
        });
    }
}

- (void)resolveHDRLuminanceFromHostMetadata:(const SS_HDR_METADATA *)hostHdrMetadata
                             hasHostMetadata:(BOOL)hasHostHdrMetadata
                                minLuminance:(float *)minOut
                                maxLuminance:(float *)maxOut
                      maxAverageLuminance:(float *)maxAverageOut
{
    float resolvedMinLuminance = fmaxf(_hdrMinLuminance, 0.0001f);
    float resolvedMaxLuminance = fmaxf(_hdrMaxLuminance, 100.0f);
    float resolvedMaxAverageLuminance = fmaxf(_hdrMaxAverageLuminance, 1.0f);
    const BOOL manualMetadataConfigured =
        _hdrClientDisplayProfileMode == MLHDRClientDisplayProfileModeManual;

    if (hasHostHdrMetadata &&
        hostHdrMetadata != NULL &&
        _hdrMetadataSourceMode != MLHDRMetadataSourceModeClientOverride) {
        if (hostHdrMetadata->minDisplayLuminance != 0) {
            resolvedMinLuminance = fmaxf((float)hostHdrMetadata->minDisplayLuminance / 10000.0f, 0.0001f);
        }
        if (hostHdrMetadata->maxDisplayLuminance != 0) {
            resolvedMaxLuminance = fmaxf((float)hostHdrMetadata->maxDisplayLuminance, 100.0f);
        }
        if (hostHdrMetadata->maxFrameAverageLightLevel != 0) {
            resolvedMaxAverageLuminance = fmaxf((float)hostHdrMetadata->maxFrameAverageLightLevel, 1.0f);
        } else if (hostHdrMetadata->maxFullFrameLuminance != 0) {
            resolvedMaxAverageLuminance = fmaxf((float)hostHdrMetadata->maxFullFrameLuminance, 1.0f);
        }
    }

    if (_hdrMetadataSourceMode == MLHDRMetadataSourceModeClientOverride ||
        (_hdrMetadataSourceMode == MLHDRMetadataSourceModeHybrid && manualMetadataConfigured) ||
        (!hasHostHdrMetadata && manualMetadataConfigured)) {
        resolvedMinLuminance = fmaxf(_hdrMinLuminance, 0.0001f);
        resolvedMaxLuminance = fmaxf(_hdrMaxLuminance, 100.0f);
        resolvedMaxAverageLuminance = fmaxf(_hdrMaxAverageLuminance, 1.0f);
    }

    if (minOut != NULL) {
        *minOut = resolvedMinLuminance;
    }
    if (maxOut != NULL) {
        *maxOut = resolvedMaxLuminance;
    }
    if (maxAverageOut != NULL) {
        *maxAverageOut = resolvedMaxAverageLuminance;
    }
}

- (void)copyResolvedHDRStaticMetadataWithHostMetadata:(const SS_HDR_METADATA *)hostHdrMetadata
                                      hasHostMetadata:(BOOL)hasHostHdrMetadata
                                       displayInfoOut:(CFDataRef *)displayInfoOut
                                       contentInfoOut:(CFDataRef *)contentInfoOut
                                         minLuminance:(float *)minOut
                                         maxLuminance:(float *)maxOut
                               maxAverageLuminance:(float *)maxAverageOut
{
    float resolvedMinLuminance = 0.0001f;
    float resolvedMaxLuminance = 1000.0f;
    float resolvedMaxAverageLuminance = 1000.0f;
    [self resolveHDRLuminanceFromHostMetadata:hostHdrMetadata
                               hasHostMetadata:hasHostHdrMetadata
                                  minLuminance:&resolvedMinLuminance
                                  maxLuminance:&resolvedMaxLuminance
                        maxAverageLuminance:&resolvedMaxAverageLuminance];

    if (minOut != NULL) {
        *minOut = resolvedMinLuminance;
    }
    if (maxOut != NULL) {
        *maxOut = resolvedMaxLuminance;
    }
    if (maxAverageOut != NULL) {
        *maxAverageOut = resolvedMaxAverageLuminance;
    }

    const BOOL manualMetadataConfigured =
        _hdrClientDisplayProfileMode == MLHDRClientDisplayProfileModeManual;
    const BOOL shouldUseHostStaticMetadata =
        hasHostHdrMetadata &&
        hostHdrMetadata != NULL &&
        _hdrMetadataSourceMode != MLHDRMetadataSourceModeClientOverride &&
        !(_hdrMetadataSourceMode == MLHDRMetadataSourceModeHybrid && manualMetadataConfigured);

    if (displayInfoOut != NULL) {
        *displayInfoOut = shouldUseHostStaticMetadata
            ? MLCreateMasteringDisplayColorVolumeData(hostHdrMetadata)
            : MLCreateMasteringDisplayColorVolumeDataFromLuminance(resolvedMinLuminance, resolvedMaxLuminance);
    }
    if (contentInfoOut != NULL) {
        *contentInfoOut = shouldUseHostStaticMetadata
            ? MLCreateContentLightLevelInfoData(hostHdrMetadata)
            : MLCreateContentLightLevelInfoDataFromLuminance(resolvedMaxLuminance, resolvedMaxAverageLuminance);
    }
}

- (CVImageBufferRef)copyInterpolatedFrameFromPreviousSource:(CVImageBufferRef)previousSourceFrame
                                                   toSource:(CVImageBufferRef)sourceFrame
{
    if (previousSourceFrame == NULL || sourceFrame == NULL) {
        return NULL;
    }

    if (![self prepareFrameInterpolationProcessorForSourceFrame:sourceFrame]) {
        return NULL;
    }

    if (_frameInterpolationOutputPool == NULL || _frameInterpolationProcessor == nil) {
        return NULL;
    }

    CVPixelBufferRef destinationBuffer = NULL;
    CVReturn createStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                               _frameInterpolationOutputPool,
                                                               &destinationBuffer);
    if (createStatus != kCVReturnSuccess || destinationBuffer == NULL) {
        Log(LOG_W, @"[video] Failed to allocate VT frame interpolation output buffer: %d", (int)createStatus);
        return NULL;
    }

    if (@available(macOS 26.0, *)) {
        CMTime presentationTimestamp = CMTIME_IS_VALID(_currentFramePresentationTimeStamp)
            ? _currentFramePresentationTimeStamp
            : kCMTimeZero;
        VTFrameProcessorFrame *sourceProcessorFrame =
            [[VTFrameProcessorFrame alloc] initWithBuffer:sourceFrame
                                    presentationTimeStamp:presentationTimestamp];
        VTFrameProcessorFrame *previousProcessorFrame =
            [[VTFrameProcessorFrame alloc] initWithBuffer:previousSourceFrame
                                    presentationTimeStamp:kCMTimeZero];
        VTFrameProcessorFrame *destinationProcessorFrame =
            [[VTFrameProcessorFrame alloc] initWithBuffer:destinationBuffer
                                    presentationTimeStamp:presentationTimestamp];
        if (sourceProcessorFrame == nil || previousProcessorFrame == nil || destinationProcessorFrame == nil) {
            CVBufferRelease(destinationBuffer);
            return NULL;
        }

        NSError *error = nil;
        VTLowLatencyFrameInterpolationParameters *parameters =
            [[VTLowLatencyFrameInterpolationParameters alloc] initWithSourceFrame:sourceProcessorFrame
                                                                    previousFrame:previousProcessorFrame
                                                               interpolationPhase:@[@0.5f]
                                                                destinationFrames:@[destinationProcessorFrame]];
        BOOL processed = parameters != nil &&
            [(VTFrameProcessor *)_frameInterpolationProcessor processWithParameters:parameters error:&error];
        if (!processed) {
            Log(LOG_W, @"[video] VT frame interpolation failed: %@", error);
            CVBufferRelease(destinationBuffer);
            return NULL;
        }

        return destinationBuffer;
    }

    CVBufferRelease(destinationBuffer);
    return NULL;
}

- (BOOL)stageInterpolatedFrameFromPreviousSource:(CVImageBufferRef)previousSourceFrame
                                        toSource:(CVImageBufferRef)sourceFrame
                                   frameSequence:(uint64_t)sourceSequence
                                   enqueueTimeMs:(uint64_t)enqueueTimeMs
                                     frameNumber:(uint32_t)frameNumber
                              displayRefreshRate:(double)displayRefreshRate
{
    NSString *reason = nil;
    if (![self shouldUseFrameInterpolationForDisplayRefreshRate:displayRefreshRate reason:&reason]) {
        _activeFrameInterpolationEngine = MLActiveVideoFrameInterpolationEngineNone;
        [self logActiveFrameInterpolationEngine:_activeFrameInterpolationEngine reason:reason];
        return NO;
    }

    CVImageBufferRef interpolatedFrame =
        [self copyInterpolatedFrameFromPreviousSource:previousSourceFrame toSource:sourceFrame];
    if (interpolatedFrame == NULL) {
        NSString *runtimeReason = _frameInterpolationWarmupInFlight
            ? @"VT frame interpolation warmup in progress"
            : @"VT frame interpolation unavailable at runtime";
        if (!_frameInterpolationWarmupInFlight && _frameInterpolationProcessor != nil) {
            [self teardownFrameInterpolationProcessor];
        }
        _activeFrameInterpolationEngine = MLActiveVideoFrameInterpolationEngineNone;
        [self logActiveFrameInterpolationEngine:_activeFrameInterpolationEngine
                                         reason:runtimeReason];
        return NO;
    }

    @synchronized(self) {
        if (_pendingInterpolatedFrame) {
            CVBufferRelease(_pendingInterpolatedFrame);
        }
        _pendingInterpolatedFrame = interpolatedFrame;
        _pendingInterpolatedEnqueueTimeMs = enqueueTimeMs;
        _pendingInterpolatedFrameNumber = frameNumber;
        _pendingInterpolatedForSourceSequence = sourceSequence;
        _pendingInterpolatedPresented = NO;
        _deferredCurrentSourceSequence = sourceSequence;
    }

    _activeFrameInterpolationEngine = MLActiveVideoFrameInterpolationEngineVTLowLatency;
    [self logActiveFrameInterpolationEngine:_activeFrameInterpolationEngine
                                     reason:[NSString stringWithFormat:@"display %.2fHz provides cadence headroom over %d FPS stream",
                                             displayRefreshRate,
                                             self.frameRate]];
    return YES;
}

- (void)cachePresentedInterpolationSourceFrame:(CVImageBufferRef)sourceFrame
{
    if (sourceFrame == NULL) {
        return;
    }

    @synchronized(self) {
        if (_previousInterpolationSourceFrame) {
            CVBufferRelease(_previousInterpolationSourceFrame);
        }
        _previousInterpolationSourceFrame = CVBufferRetain(sourceFrame);
    }
}

- (BOOL)prepareFrameProcessorForEngine:(MLActiveVideoEnhancementEngine)engine
                           sourceWidth:(NSUInteger)sourceWidth
                          sourceHeight:(NSUInteger)sourceHeight
                           scaleFactor:(float)scaleFactor
                         warmupPending:(BOOL *)warmupPending
{
    if (warmupPending != NULL) {
        *warmupPending = NO;
    }

    if (engine != MLActiveVideoEnhancementEngineVTLowLatencySuperResolution &&
        engine != MLActiveVideoEnhancementEngineVTQualitySuperResolution) {
        [self teardownEnhancementProcessor];
        return NO;
    }

    if (@available(macOS 26.0, *)) {
        if (_frameProcessor != nil &&
            _frameProcessorEngine == engine &&
            _frameProcessorInputWidth == (NSInteger)sourceWidth &&
            _frameProcessorInputHeight == (NSInteger)sourceHeight &&
            fabsf(_frameProcessorScaleFactor - scaleFactor) < 0.02f) {
            return YES;
        }

        if (_enhancementWarmupInFlight &&
            _enhancementWarmupEngine == engine &&
            _enhancementWarmupWidth == (NSInteger)sourceWidth &&
            _enhancementWarmupHeight == (NSInteger)sourceHeight &&
            fabsf(_enhancementWarmupScaleFactor - scaleFactor) < 0.02f) {
            if (warmupPending != NULL) {
                *warmupPending = YES;
            }
            return NO;
        }

        [self requestEnhancementWarmupForEngine:engine
                                    sourceWidth:sourceWidth
                                   sourceHeight:sourceHeight
                                    scaleFactor:scaleFactor];
        if (_enhancementWarmupInFlight &&
            _enhancementWarmupEngine == engine &&
            _enhancementWarmupWidth == (NSInteger)sourceWidth &&
            _enhancementWarmupHeight == (NSInteger)sourceHeight &&
            fabsf(_enhancementWarmupScaleFactor - scaleFactor) < 0.02f) {
            if (warmupPending != NULL) {
                *warmupPending = YES;
            }
        }
        return NO;
    }

    return NO;
}

- (void)requestEnhancementWarmupForEngine:(MLActiveVideoEnhancementEngine)engine
                              sourceWidth:(NSInteger)sourceWidth
                             sourceHeight:(NSInteger)sourceHeight
                              scaleFactor:(float)scaleFactor
{
    if ((engine != MLActiveVideoEnhancementEngineVTLowLatencySuperResolution &&
         engine != MLActiveVideoEnhancementEngineVTQualitySuperResolution) ||
        sourceWidth <= 0 ||
        sourceHeight <= 0 ||
        scaleFactor <= 1.0f) {
        return;
    }

    if (@available(macOS 26.0, *)) {
        if (_frameProcessor != nil &&
            _frameProcessorEngine == engine &&
            _frameProcessorInputWidth == sourceWidth &&
            _frameProcessorInputHeight == sourceHeight &&
            fabsf(_frameProcessorScaleFactor - scaleFactor) < 0.02f) {
            return;
        }

        if (_enhancementWarmupInFlight &&
            _enhancementWarmupEngine == engine &&
            _enhancementWarmupWidth == sourceWidth &&
            _enhancementWarmupHeight == sourceHeight &&
            fabsf(_enhancementWarmupScaleFactor - scaleFactor) < 0.02f) {
            return;
        }

        _enhancementWarmupInFlight = YES;
        _enhancementWarmupWidth = sourceWidth;
        _enhancementWarmupHeight = sourceHeight;
        _enhancementWarmupScaleFactor = scaleFactor;
        _enhancementWarmupEngine = engine;
        NSUInteger warmupGeneration = ++_enhancementWarmupGeneration;

        dispatch_async(_vtWarmupQueue, ^{
            id configuration = nil;
            if (engine == MLActiveVideoEnhancementEngineVTLowLatencySuperResolution) {
                configuration =
                    [[VTLowLatencySuperResolutionScalerConfiguration alloc] initWithFrameWidth:sourceWidth
                                                                                   frameHeight:sourceHeight
                                                                                   scaleFactor:scaleFactor];
            } else {
                configuration =
                    [[VTSuperResolutionScalerConfiguration alloc] initWithFrameWidth:sourceWidth
                                                                         frameHeight:sourceHeight
                                                                         scaleFactor:(NSInteger)lroundf(scaleFactor)
                                                                           inputType:VTSuperResolutionScalerConfigurationInputTypeVideo
                                                                  usePrecomputedFlow:NO
                                                               qualityPrioritization:VTSuperResolutionScalerConfigurationQualityPrioritizationNormal
                                                                            revision:VTSuperResolutionScalerConfiguration.defaultRevision];
                if ([configuration respondsToSelector:@selector(configurationModelStatus)]) {
                    NSInteger modelStatus = (NSInteger)[configuration configurationModelStatus];
                    if (modelStatus != 2) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (warmupGeneration != self->_enhancementWarmupGeneration) {
                                return;
                            }
                            self->_enhancementWarmupInFlight = NO;
                            Log(LOG_W, @"[video] VT quality super-resolution model not ready (status=%ld)", (long)modelStatus);
                        });
                        return;
                    }
                }
            }

            if (configuration == nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (warmupGeneration != self->_enhancementWarmupGeneration) {
                        return;
                    }
                    self->_enhancementWarmupInFlight = NO;
                });
                return;
            }

            VTFrameProcessor *processor = [[VTFrameProcessor alloc] init];
            NSError *error = nil;
            BOOL started = [processor startSessionWithConfiguration:configuration error:&error];
            CVPixelBufferPoolRef pool = NULL;
            CVReturn poolStatus = kCVReturnError;

            if (started) {
                NSDictionary *outputAttributes =
                    [self resolvedFrameProcessorAttributesWithPreferredPixelFormat:kCVPixelFormatType_32BGRA
                                                                    baseAttributes:[configuration destinationPixelBufferAttributes]];
                poolStatus = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                                     NULL,
                                                     (__bridge CFDictionaryRef)outputAttributes,
                                                     &pool);
                if (poolStatus != kCVReturnSuccess || pool == NULL) {
                    [processor endSession];
                    started = NO;
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (warmupGeneration != self->_enhancementWarmupGeneration) {
                    if (started) {
                        [processor endSession];
                    }
                    if (pool != NULL) {
                        CFRelease(pool);
                    }
                    return;
                }

                self->_enhancementWarmupInFlight = NO;
                if (!started) {
                    if (poolStatus != kCVReturnSuccess && pool == NULL) {
                        Log(LOG_W, @"[video] Failed to prewarm VT frame processor output pool: %d", (int)poolStatus);
                    } else {
                        Log(LOG_W, @"[video] Failed to prewarm VT frame processor session: %@", error);
                    }
                    return;
                }

                if (self->_frameProcessor != nil &&
                    self->_frameProcessorEngine == engine &&
                    self->_frameProcessorInputWidth == sourceWidth &&
                    self->_frameProcessorInputHeight == sourceHeight &&
                    fabsf(self->_frameProcessorScaleFactor - scaleFactor) < 0.02f) {
                    [processor endSession];
                    if (pool != NULL) {
                        CFRelease(pool);
                    }
                    return;
                }

                NSUInteger preservedWarmupGeneration = self->_enhancementWarmupGeneration;
                [self teardownEnhancementProcessor];
                self->_enhancementWarmupGeneration = preservedWarmupGeneration;
                self->_enhancementWarmupInFlight = NO;
                self->_enhancementWarmupWidth = sourceWidth;
                self->_enhancementWarmupHeight = sourceHeight;
                self->_enhancementWarmupScaleFactor = scaleFactor;
                self->_enhancementWarmupEngine = engine;
                self->_frameProcessor = processor;
                self->_frameProcessorConfiguration = configuration;
                self->_frameProcessorOutputPool = pool;
                self->_frameProcessorEngine = engine;
                self->_frameProcessorInputWidth = sourceWidth;
                self->_frameProcessorInputHeight = sourceHeight;
                self->_frameProcessorScaleFactor = scaleFactor;
                Log(LOG_I, @"[video] %@ prewarmed for %ldx%ld scale=%.2f",
                    MLVideoEnhancementEngineName(engine),
                    (long)sourceWidth,
                    (long)sourceHeight,
                    scaleFactor);
            });
        });
    }
}

- (CVImageBufferRef)copyFrameUsingFrameProcessorIfNeeded:(CVImageBufferRef)sourceFrame
                                         activeEnhancement:(MLActiveVideoEnhancementEngine)engine
                                              scaleFactor:(float)scaleFactor
                                            warmupPending:(BOOL *)warmupPending
{
    if (warmupPending != NULL) {
        *warmupPending = NO;
    }

    if (sourceFrame == NULL) {
        return NULL;
    }

    if (engine != MLActiveVideoEnhancementEngineVTLowLatencySuperResolution &&
        engine != MLActiveVideoEnhancementEngineVTQualitySuperResolution) {
        return NULL;
    }

    if (![self prepareFrameProcessorForEngine:engine
                                  sourceWidth:CVPixelBufferGetWidth(sourceFrame)
                                 sourceHeight:CVPixelBufferGetHeight(sourceFrame)
                                  scaleFactor:scaleFactor
                                warmupPending:warmupPending]) {
        return NULL;
    }

    if (_frameProcessorOutputPool == NULL || _frameProcessor == nil) {
        return NULL;
    }

    CVPixelBufferRef destinationBuffer = NULL;
    CVReturn createStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                               _frameProcessorOutputPool,
                                                               &destinationBuffer);
    if (createStatus != kCVReturnSuccess || destinationBuffer == NULL) {
        Log(LOG_W, @"[video] Failed to allocate VT frame processor output buffer: %d", (int)createStatus);
        return NULL;
    }

    if (@available(macOS 26.0, *)) {
        VTFrameProcessorFrame *sourceProcessorFrame =
            [[VTFrameProcessorFrame alloc] initWithBuffer:sourceFrame
                                    presentationTimeStamp:CMTIME_IS_VALID(_currentFramePresentationTimeStamp) ? _currentFramePresentationTimeStamp : kCMTimeZero];
        VTFrameProcessorFrame *destinationProcessorFrame =
            [[VTFrameProcessorFrame alloc] initWithBuffer:destinationBuffer
                                    presentationTimeStamp:CMTIME_IS_VALID(_currentFramePresentationTimeStamp) ? _currentFramePresentationTimeStamp : kCMTimeZero];
        if (sourceProcessorFrame == nil || destinationProcessorFrame == nil) {
            CVBufferRelease(destinationBuffer);
            return NULL;
        }

        NSError *error = nil;
        BOOL processed = NO;
        if (engine == MLActiveVideoEnhancementEngineVTLowLatencySuperResolution) {
            VTLowLatencySuperResolutionScalerParameters *parameters =
                [[VTLowLatencySuperResolutionScalerParameters alloc] initWithSourceFrame:sourceProcessorFrame
                                                                         destinationFrame:destinationProcessorFrame];
            processed = parameters != nil && [(VTFrameProcessor *)_frameProcessor processWithParameters:parameters error:&error];
        } else {
            VTFrameProcessorFrame *previousSourceFrame = nil;
            VTFrameProcessorFrame *previousOutputFrame = nil;
            VTSuperResolutionScalerParametersSubmissionMode submissionMode =
                VTSuperResolutionScalerParametersSubmissionModeRandom;

            if (_previousEnhancedSourceFrame != NULL) {
                previousSourceFrame =
                    [[VTFrameProcessorFrame alloc] initWithBuffer:_previousEnhancedSourceFrame
                                            presentationTimeStamp:kCMTimeZero];
            }
            if (_previousEnhancedOutputFrame != NULL) {
                previousOutputFrame =
                    [[VTFrameProcessorFrame alloc] initWithBuffer:_previousEnhancedOutputFrame
                                            presentationTimeStamp:kCMTimeZero];
            }
            if (previousSourceFrame != nil && previousOutputFrame != nil) {
                submissionMode = VTSuperResolutionScalerParametersSubmissionModeSequential;
            }

            VTSuperResolutionScalerParameters *parameters =
                [[VTSuperResolutionScalerParameters alloc] initWithSourceFrame:sourceProcessorFrame
                                                                 previousFrame:previousSourceFrame
                                                           previousOutputFrame:previousOutputFrame
                                                                   opticalFlow:nil
                                                                submissionMode:submissionMode
                                                              destinationFrame:destinationProcessorFrame];
            processed = parameters != nil && [(VTFrameProcessor *)_frameProcessor processWithParameters:parameters error:&error];
        }

        if (!processed) {
            Log(LOG_W, @"[video] VT frame processor failed: %@", error);
            CVBufferRelease(destinationBuffer);
            return NULL;
        }

        if (engine == MLActiveVideoEnhancementEngineVTQualitySuperResolution) {
            [self releasePreviousEnhancedFrames];
            _previousEnhancedSourceFrame = CVBufferRetain(sourceFrame);
            _previousEnhancedOutputFrame = CVBufferRetain(destinationBuffer);
        }

        return destinationBuffer;
    }

    CVBufferRelease(destinationBuffer);
    return NULL;
}

- (MTLPixelFormat)metalLumaPlaneFormatForPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    switch (pixelFormat) {
        case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
        case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
        case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
        case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
        case kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return MTLPixelFormatR16Unorm;
        case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange:
        case kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:
        case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange:
        case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        default:
            return MTLPixelFormatR8Unorm;
    }
}

- (MTLPixelFormat)metalChromaPlaneFormatForPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    switch (pixelFormat) {
        case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
        case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
        case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
        case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
        case kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return MTLPixelFormatRG16Unorm;
        case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange:
        case kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:
        case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange:
        case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        default:
            return MTLPixelFormatRG8Unorm;
    }
}

- (BOOL)encodePresentFromTexture:(id<MTLTexture>)sourceTexture
                    toDrawable:(id<CAMetalDrawable>)drawable
                  commandBuffer:(id<MTLCommandBuffer>)commandBuffer
{
    if (sourceTexture == nil || drawable == nil || commandBuffer == nil || _blitRenderPipelineState == nil) {
        return NO;
    }

    MTLRenderPassDescriptor *passDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    passDescriptor.colorAttachments[0].texture = drawable.texture;
    passDescriptor.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
    if (renderEncoder == nil) {
        return NO;
    }

    [renderEncoder setRenderPipelineState:_blitRenderPipelineState];
    [renderEncoder setFragmentTexture:sourceTexture atIndex:0];
    [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [renderEncoder endEncoding];
    return YES;
}

- (BOOL)encodeMetalFXScalingFromTexture:(id<MTLTexture>)sourceTexture
                              engine:(MLActiveVideoEnhancementEngine)engine
                              toView:(MTKView *)view
                        commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                            drawable:(id<CAMetalDrawable>)drawable
{
    if (sourceTexture == nil || view == nil || commandBuffer == nil || drawable == nil) {
        return NO;
    }

    if (!MLMetalFXIsSupported()) {
        return NO;
    }

#if ML_HAS_METALFX
    if (@available(macOS 13.0, *)) {
        MTLFXSpatialScalerColorProcessingMode colorMode =
            _enableHdr ? MTLFXSpatialScalerColorProcessingModeHDR : MTLFXSpatialScalerColorProcessingModePerceptual;

        if (_spatialScaler
            && ([_spatialScaler inputWidth] != sourceTexture.width
                || [_spatialScaler inputHeight] != sourceTexture.height
                || [_spatialScaler outputWidth] != drawable.texture.width
                || [_spatialScaler outputHeight] != drawable.texture.height
                || [_spatialScaler colorTextureFormat] != sourceTexture.pixelFormat
                || [_spatialScaler outputTextureFormat] != view.colorPixelFormat
                || [_spatialScaler colorProcessingMode] != colorMode)) {
            _spatialScaler = nil;
        }

        if (!_spatialScaler) {
            MTLFXSpatialScalerDescriptor *scalerDesc = [[MTLFXSpatialScalerDescriptor alloc] init];
            scalerDesc.inputWidth = sourceTexture.width;
            scalerDesc.inputHeight = sourceTexture.height;
            scalerDesc.outputWidth = drawable.texture.width;
            scalerDesc.outputHeight = drawable.texture.height;
            scalerDesc.colorTextureFormat = sourceTexture.pixelFormat;
            scalerDesc.outputTextureFormat = view.colorPixelFormat;
            scalerDesc.colorProcessingMode = colorMode;
            _spatialScaler = [scalerDesc newSpatialScalerWithDevice:_device];
        }

        if (!_spatialScaler) {
            return NO;
        }

        id<MTLTexture> targetTexture = drawable.texture;
        if (drawable.texture.storageMode != MTLStorageModePrivate) {
            if (!_upscaledTexture || _upscaledTexture.width != drawable.texture.width
                || _upscaledTexture.height != drawable.texture.height
                || _upscaledTexture.pixelFormat != drawable.texture.pixelFormat) {
                MTLTextureDescriptor *upscaledDesc =
                    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:drawable.texture.pixelFormat
                                                                      width:drawable.texture.width
                                                                     height:drawable.texture.height
                                                                  mipmapped:NO];
                upscaledDesc.storageMode = MTLStorageModePrivate;
                upscaledDesc.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
                _upscaledTexture = [_device newTextureWithDescriptor:upscaledDesc];
            }
            targetTexture = _upscaledTexture;
        }

        [_spatialScaler setColorTexture:sourceTexture];
        [_spatialScaler setOutputTexture:targetTexture];
        [_spatialScaler encodeToCommandBuffer:commandBuffer];

        if (targetTexture != drawable.texture) {
            return [self encodePresentFromTexture:targetTexture toDrawable:drawable commandBuffer:commandBuffer];
        }

        return YES;
    }
#endif

    return NO;
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
}

- (void)drawInMTKView:(MTKView *)view {
    if (_activeRendererMode != MLActiveVideoRendererModeEnhanced) {
        return;
    }

    if (_enableHdr) {
        [self refreshEnhancedHDRPresentationIfNeeded];
    }

    CVImageBufferRef frame = NULL;
    CVImageBufferRef interpolatedFrame = NULL;
    uint64_t frameEnqueueTimeMs = 0;
    uint32_t frameNumber = 0;
    uint64_t frameSequence = 0;
    BOOL presentingInterpolatedFrame = NO;
    @synchronized(self) {
        if (_currentFrame) {
            frame = CVBufferRetain(_currentFrame);
            frameEnqueueTimeMs = _currentFrameEnqueueTimeMs;
            frameNumber = _currentFrameNumber;
            frameSequence = _currentFrameSequence;
        }
        if (_pendingInterpolatedFrame != NULL &&
            _pendingInterpolatedForSourceSequence != 0 &&
            _pendingInterpolatedForSourceSequence == _deferredCurrentSourceSequence &&
            !_pendingInterpolatedPresented) {
            interpolatedFrame = CVBufferRetain(_pendingInterpolatedFrame);
            frameEnqueueTimeMs = _pendingInterpolatedEnqueueTimeMs;
            frameNumber = _pendingInterpolatedFrameNumber;
            presentingInterpolatedFrame = YES;
        }
    }

    CVImageBufferRef presentationFrame = interpolatedFrame != NULL ? interpolatedFrame : frame;
    if (!presentationFrame) {
        return;
    }

    // Lazy init pipeline
    if (!_computePipelineState) {
        [self setupMetalPipeline];
    }
    if (!_computePipelineState || !_textureCache) {
        if (interpolatedFrame) {
            CVBufferRelease(interpolatedFrame);
        }
        if (frame) {
            CVBufferRelease(frame);
        }
        return;
    }

    const NSUInteger sourceWidth = CVPixelBufferGetWidth(presentationFrame);
    const NSUInteger sourceHeight = CVPixelBufferGetHeight(presentationFrame);
    const NSUInteger targetWidth = MAX((NSUInteger)1, (NSUInteger)llround(view.drawableSize.width));
    const NSUInteger targetHeight = MAX((NSUInteger)1, (NSUInteger)llround(view.drawableSize.height));
    float resolvedScaleFactor = 1.0f;
    NSString *enhancementReason = nil;
    MLActiveVideoEnhancementEngine resolvedEngine =
        [self resolveEnhancementEngineForSourceWidth:sourceWidth
                                        sourceHeight:sourceHeight
                                         targetWidth:targetWidth
                                        targetHeight:targetHeight
                                         scaleFactor:&resolvedScaleFactor
                                              reason:&enhancementReason];
    _activeEnhancementEngine = resolvedEngine;
    [self logActiveEnhancementEngine:_activeEnhancementEngine reason:enhancementReason];

    BOOL enhancementWarmupPending = NO;
    CVImageBufferRef processedFrame = [self copyFrameUsingFrameProcessorIfNeeded:presentationFrame
                                                               activeEnhancement:_activeEnhancementEngine
                                                                    scaleFactor:resolvedScaleFactor
                                                                  warmupPending:&enhancementWarmupPending];
    if (processedFrame == NULL &&
        (_activeEnhancementEngine == MLActiveVideoEnhancementEngineVTLowLatencySuperResolution ||
         _activeEnhancementEngine == MLActiveVideoEnhancementEngineVTQualitySuperResolution)) {
        if (!enhancementWarmupPending) {
            [self teardownEnhancementProcessor];
        }
        _activeEnhancementEngine = MLMetalFXIsSupported()
            ? MLActiveVideoEnhancementEngineMetalFXQuality
            : MLActiveVideoEnhancementEngineBasicScaling;
        [self logActiveEnhancementEngine:_activeEnhancementEngine
                                  reason:enhancementWarmupPending
            ? (_activeEnhancementEngine == MLActiveVideoEnhancementEngineMetalFXQuality
                ? @"VT enhancement warmup in progress; temporarily using MetalFX"
                : @"VT enhancement warmup in progress; temporarily using basic scaling")
            : @"VT enhancement unavailable at runtime; fell back"];
    }

    CVImageBufferRef workingFrame = processedFrame != NULL ? processedFrame : presentationFrame;
    const OSType pixelFormat = CVPixelBufferGetPixelFormatType(workingFrame);
    const size_t workingWidth = CVPixelBufferGetWidth(workingFrame);
    const size_t workingHeight = CVPixelBufferGetHeight(workingFrame);
    const size_t planeCount = CVPixelBufferGetPlaneCount(workingFrame);

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    if (commandBuffer == nil) {
        if (processedFrame) {
            CVBufferRelease(processedFrame);
        }
        if (interpolatedFrame) {
            CVBufferRelease(interpolatedFrame);
        }
        if (frame) {
            CVBufferRelease(frame);
        }
        return;
    }

    id<MTLTexture> sourceRGBTexture = nil;
    CVMetalTextureRef primaryTextureRef = NULL;
    CVMetalTextureRef secondaryTextureRef = NULL;

    if (planeCount >= 2) {
        const size_t lumaWidth = CVPixelBufferGetWidthOfPlane(workingFrame, 0);
        const size_t lumaHeight = CVPixelBufferGetHeightOfPlane(workingFrame, 0);
        const size_t chromaWidth = CVPixelBufferGetWidthOfPlane(workingFrame, 1);
        const size_t chromaHeight = CVPixelBufferGetHeightOfPlane(workingFrame, 1);
        CVReturn yStatus = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                     _textureCache,
                                                                     workingFrame,
                                                                     nil,
                                                                     [self metalLumaPlaneFormatForPixelBuffer:workingFrame],
                                                                     lumaWidth,
                                                                     lumaHeight,
                                                                     0,
                                                                     &primaryTextureRef);
        CVReturn uvStatus = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                      _textureCache,
                                                                      workingFrame,
                                                                      nil,
                                                                      [self metalChromaPlaneFormatForPixelBuffer:workingFrame],
                                                                      chromaWidth,
                                                                      chromaHeight,
                                                                      1,
                                                                      &secondaryTextureRef);
        if (yStatus == kCVReturnSuccess && uvStatus == kCVReturnSuccess && primaryTextureRef != NULL && secondaryTextureRef != NULL) {
            id<MTLTexture> yTexture = CVMetalTextureGetTexture(primaryTextureRef);
            id<MTLTexture> uvTexture = CVMetalTextureGetTexture(secondaryTextureRef);
            MLYCbCrConversionParameters conversionParams =
                MLYCbCrConversionParametersForPixelFormat(pixelFormat,
                                                         _hdrTransferMode,
                                                         _hdrToneMapToSDR ? -_hdrOpticalOutputScale : _hdrOpticalOutputScale,
                                                         _hdrOutputUsesEDR,
                                                         _hdrToneMapToSDR,
                                                         _hdrToneMappingPolicy,
                                                         _hdrMinLuminance,
                                                         _hdrMaxLuminance,
                                                         _hdrMaxAverageLuminance);
            MTLPixelFormat intermediatePixelFormat = MTLPixelFormatBGRA8Unorm;
            if (_enableHdr && _hdrOutputUsesEDR) {
                intermediatePixelFormat = MTLPixelFormatRGBA16Float;
            } else if (_enableHdr && !_hdrToneMapToSDR) {
                intermediatePixelFormat = MTLPixelFormatBGR10A2Unorm;
            }
            id<MTLTexture> intermediateTexture = [self intermediateTextureForWidth:workingWidth
                                                                            height:workingHeight
                                                                       pixelFormat:intermediatePixelFormat];

            id<MTLComputeCommandEncoder> computeEncoder = [commandBuffer computeCommandEncoder];
            [computeEncoder setComputePipelineState:_computePipelineState];
            [computeEncoder setTexture:yTexture atIndex:0];
            [computeEncoder setTexture:uvTexture atIndex:1];
            [computeEncoder setTexture:intermediateTexture atIndex:2];
            [computeEncoder setBytes:&conversionParams length:sizeof(conversionParams) atIndex:0];

            NSUInteger w = _computePipelineState.threadExecutionWidth;
            NSUInteger h = MAX((NSUInteger)1, _computePipelineState.maxTotalThreadsPerThreadgroup / w);
            MTLSize threadsPerThreadgroup = MTLSizeMake(w, h, 1);
            MTLSize threadgroups = MTLSizeMake((workingWidth + w - 1) / w, (workingHeight + h - 1) / h, 1);
            [computeEncoder dispatchThreadgroups:threadgroups threadsPerThreadgroup:threadsPerThreadgroup];
            [computeEncoder endEncoding];
            sourceRGBTexture = intermediateTexture;
        }
    } else if (pixelFormat == kCVPixelFormatType_32BGRA) {
        CVReturn textureStatus = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                           _textureCache,
                                                                           workingFrame,
                                                                           nil,
                                                                           MTLPixelFormatBGRA8Unorm,
                                                                           workingWidth,
                                                                           workingHeight,
                                                                           0,
                                                                           &primaryTextureRef);
        if (textureStatus == kCVReturnSuccess && primaryTextureRef != NULL) {
            sourceRGBTexture = CVMetalTextureGetTexture(primaryTextureRef);
        }
    } else {
        Log(LOG_W, @"[video] Unsupported enhanced pixel format: 0x%X planes=%zu", (unsigned int)pixelFormat, planeCount);
    }

    if (sourceRGBTexture != nil) {
        CAMetalLayer *metalLayer = (CAMetalLayer *)view.layer;
        if ([metalLayer isKindOfClass:[CAMetalLayer class]]) {
            [self applyHDRPresentationStateToMetalLayer:metalLayer];
        }

        BOOL acquiredInflightSlot = NO;
        if (_metalInflightSemaphore != nil) {
            if (dispatch_semaphore_wait(_metalInflightSemaphore, DISPATCH_TIME_NOW) != 0) {
                _inflightBackpressureCount += 1;
                uint64_t nowMs = LiGetMillis();
                if (_lastInflightBackpressureLogMs == 0 || nowMs - _lastInflightBackpressureLogMs >= 1000) {
                    Log(LOG_W, @"[video] Enhanced inflight backpressure count=%lu depth=%lu",
                        (unsigned long)_inflightBackpressureCount,
                        (unsigned long)_metalInflightLimit);
                    _lastInflightBackpressureLogMs = nowMs;
                    _inflightBackpressureCount = 0;
                }
                if (primaryTextureRef) CFRelease(primaryTextureRef);
                if (secondaryTextureRef) CFRelease(secondaryTextureRef);
                if (processedFrame) {
                    CVBufferRelease(processedFrame);
                }
                if (interpolatedFrame) {
                    CVBufferRelease(interpolatedFrame);
                }
                if (frame) {
                    CVBufferRelease(frame);
                }
                return;
            }
            acquiredInflightSlot = YES;
            [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _) {
                dispatch_semaphore_signal(self->_metalInflightSemaphore);
            }];
        }

        id<CAMetalDrawable> drawable = view.currentDrawable;
        if (drawable == nil) {
            _drawableUnavailableCount += 1;
            uint64_t nowMs = LiGetMillis();
            if (_lastDrawableUnavailableLogMs == 0 || nowMs - _lastDrawableUnavailableLogMs >= 1000) {
                Log(LOG_W, @"[video] Enhanced drawable unavailable count=%lu windowVisible=%d occluded=%d",
                    (unsigned long)_drawableUnavailableCount,
                    (_view.window != nil && _view.window.isVisible) ? 1 : 0,
                    (_view.window != nil && ((_view.window.occlusionState & NSWindowOcclusionStateVisible) != 0)) ? 0 : 1);
                _lastDrawableUnavailableLogMs = nowMs;
                _drawableUnavailableCount = 0;
            }
            if (acquiredInflightSlot) {
                dispatch_semaphore_signal(_metalInflightSemaphore);
            }
            if (primaryTextureRef) CFRelease(primaryTextureRef);
            if (secondaryTextureRef) CFRelease(secondaryTextureRef);
            if (processedFrame) {
                CVBufferRelease(processedFrame);
            }
            if (interpolatedFrame) {
                CVBufferRelease(interpolatedFrame);
            }
            if (frame) {
                CVBufferRelease(frame);
            }
            return;
        }

        BOOL usedMetalFX = NO;
        if (_activeEnhancementEngine == MLActiveVideoEnhancementEngineMetalFXQuality ||
            _activeEnhancementEngine == MLActiveVideoEnhancementEngineMetalFXPerformance) {
            usedMetalFX = [self encodeMetalFXScalingFromTexture:sourceRGBTexture
                                                         engine:_activeEnhancementEngine
                                                         toView:view
                                                   commandBuffer:commandBuffer
                                                       drawable:drawable];
            if (!usedMetalFX) {
                _activeEnhancementEngine = MLActiveVideoEnhancementEngineBasicScaling;
                [self logActiveEnhancementEngine:_activeEnhancementEngine
                                          reason:@"MetalFX unavailable at runtime; fell back to basic scaling"];
            }
        }

        if (!usedMetalFX) {
            [self encodePresentFromTexture:sourceRGBTexture
                                toDrawable:drawable
                              commandBuffer:commandBuffer];
        }

        NSUInteger presentedCount = 0;
        if (!presentingInterpolatedFrame && frameSequence != 0) {
            @synchronized(self) {
                if (frameSequence != _lastPresentedFrameSequence) {
                    _lastPresentedFrameSequence = frameSequence;
                    _enhancedStartupPresentedFrameCount += 1;
                    presentedCount = _enhancedStartupPresentedFrameCount;
                }
            }
        }

        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];

        if (presentingInterpolatedFrame) {
            @synchronized(self) {
                if (_pendingInterpolatedForSourceSequence == frameSequence) {
                    _pendingInterpolatedPresented = YES;
                }
            }
        } else if (frame != NULL) {
            [self cachePresentedInterpolationSourceFrame:frame];
            @synchronized(self) {
                if (_deferredCurrentSourceSequence == frameSequence) {
                    _deferredCurrentSourceSequence = 0;
                    if (_pendingInterpolatedFrame) {
                        CVBufferRelease(_pendingInterpolatedFrame);
                        _pendingInterpolatedFrame = NULL;
                    }
                    _pendingInterpolatedPresented = NO;
                    _pendingInterpolatedForSourceSequence = 0;
                    _pendingInterpolatedEnqueueTimeMs = 0;
                    _pendingInterpolatedFrameNumber = 0;
                }
            }
        }

        if (presentedCount > 0) {
            uint64_t presentMs = LiGetMillis();
            [self recordRenderedFrameSampleAtTimeMs:presentMs enqueueTimeMs:frameEnqueueTimeMs];
            if (presentedCount == 1) {
                unsigned long long startupMs = (_rendererStartTimeMs != 0 && presentMs >= _rendererStartTimeMs)
                    ? (unsigned long long)(presentMs - _rendererStartTimeMs)
                    : 0;
                unsigned long long queueAgeMs = (frameEnqueueTimeMs != 0 && presentMs >= frameEnqueueTimeMs)
                    ? (unsigned long long)(presentMs - frameEnqueueTimeMs)
                    : 0;
                Log(LOG_I, @"[video] Enhanced first present startup=%llums queueAge=%llums frame=%u",
                    startupMs,
                    queueAgeMs,
                    (unsigned int)frameNumber);
            }
        }
    }

    if (primaryTextureRef) CFRelease(primaryTextureRef);
    if (secondaryTextureRef) CFRelease(secondaryTextureRef);
    if (processedFrame) {
        CVBufferRelease(processedFrame);
    }
    if (interpolatedFrame) {
        CVBufferRelease(interpolatedFrame);
    }
    if (frame) {
        CVBufferRelease(frame);
    }
}

- (void)start
{
    _rendererStartTimeMs = LiGetMillis();
    _enhancedStartupPacingUntilMs = _rendererStartTimeMs + kMLEnhancedStartupPacingWindowMs;
    _enhancedStartupPresentedFrameCount = 0;
    _didLogEnhancedStartupPacing = NO;

    void (^startBlock)(void) = ^{
        NSScreen *screen = self->_view.window.screen;
        CVReturn status = kCVReturnError;
        if (screen != nil) {
            CGDirectDisplayID displayId = getDisplayID(screen);
            status = CVDisplayLinkCreateWithCGDisplay(displayId, &self->_displayLink);
        } else {
            status = CVDisplayLinkCreateWithActiveCGDisplays(&self->_displayLink);
        }
        if (status != kCVReturnSuccess) {
            status = CVDisplayLinkCreateWithActiveCGDisplays(&self->_displayLink);
        }
        if (status != kCVReturnSuccess) {
            Log(LOG_E, @"Failed to create CVDisplayLink: %d", status);
        }

        status = CVDisplayLinkSetOutputCallback(self->_displayLink, displayLinkCallback, (__bridge void * _Nullable)(self));
        if (status != kCVReturnSuccess) {
            Log(LOG_E, @"CVDisplayLinkSetOutputCallback() failed: %d", status);
        }

        status = CVDisplayLinkStart(self->_displayLink);
        if (status != kCVReturnSuccess) {
            Log(LOG_E, @"CVDisplayLinkStart() failed: %d", status);
        } else {
            unsigned long long startupMs = (unsigned long long)(LiGetMillis() - self->_rendererStartTimeMs);
            Log(LOG_I, @"[video] Display link started in %llums renderer=%@",
                startupMs,
                [self activeRendererModeName:self->_activeRendererMode]);
        }
    };

    if ([NSThread isMainThread]) {
        startBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), startBlock);
    }
}

// TODO: Refactor this
int DrSubmitDecodeUnit(PDECODE_UNIT decodeUnit);

static CVReturn displayLinkCallback(CVDisplayLinkRef displayLink,
                                          const CVTimeStamp *inNow,
                                          const CVTimeStamp *inOutputTime,
                                          CVOptionFlags flagsIn,
                                          CVOptionFlags *flagsOut,
                                          void *displayLinkContext)
{
    VideoDecoderRenderer *self = (__bridge VideoDecoderRenderer *)displayLinkContext;
    PML_DEPACKETIZER_CONTEXT depacketizerCtx = (PML_DEPACKETIZER_CONTEXT)self.depacketizerContext;
    if (depacketizerCtx == NULL) {
        return kCVReturnSuccess;
    }
    if (depacketizerCtx->connectionContext != NULL) {
        LiSetThreadConnectionContext(depacketizerCtx->connectionContext);
    }

    VIDEO_FRAME_HANDLE handle;
    PDECODE_UNIT du;
    BOOL dequeuedAny = NO;
    double displayRefreshRate = 0.0;
    if (self->_displayLink != NULL) {
        double refreshPeriod = CVDisplayLinkGetActualOutputVideoRefreshPeriod(self->_displayLink);
        if (refreshPeriod > 0.0) {
            displayRefreshRate = 1.0 / refreshPeriod;
        }
    }
    self->_lastDisplayRefreshRate = displayRefreshRate;
    int desiredPendingFrames = [self desiredPendingFramesForDisplayRefreshRate:displayRefreshRate];
    if (self->_lastLoggedPendingTarget != desiredPendingFrames) {
        self->_lastLoggedPendingTarget = desiredPendingFrames;
        Log(LOG_I, @"[diag] Renderer pacing target updated: pending=%d framePacing=%ld mode=%ld buffer=%ld responsiveness=%d compatibility=%d vsync=%d sdrCompat=%d display=%.2fHz stream=%d",
            desiredPendingFrames,
            (long)self->_framePacingMode,
            (long)self->_smoothnessLatencyMode,
            (long)self->_timingBufferLevel,
            self->_timingPrioritizeResponsiveness ? 1 : 0,
            self->_timingCompatibilityMode ? 1 : 0,
            self->_timingEnableVsync ? 1 : 0,
            self->_timingSdrCompatibilityWorkaround ? 1 : 0,
            displayRefreshRate,
            self.frameRate);
    }

    while (LiPollNextVideoFrameCtx(depacketizerCtx, &handle, &du)) {
        dequeuedAny = YES;

        // Cache fields before LiCompleteVideoFrame() frees the decode unit.
        const uint64_t enqueueTimeMs = du->enqueueTimeMs;
        const uint64_t receiveTimeMs = du->receiveTimeMs;
        const unsigned int presentationTimeMs = du->presentationTimeMs;
        const int fullLengthBytes = du->fullLength;
        const uint64_t nowMs = LiGetMillis();

        if (self->_remainingDequeuedFrameLogCount > 0) {
            Log(LOG_D, @"[diag] Pull renderer dequeued frame=%d len=%d pending=%d enqueueAge=%llums",
                du->frameNumber,
                fullLengthBytes,
                LiGetPendingVideoFramesCtx(depacketizerCtx),
                (unsigned long long)(enqueueTimeMs != 0 && nowMs >= enqueueTimeMs ? nowMs - enqueueTimeMs : 0));
            self->_remainingDequeuedFrameLogCount -= 1;
        }
        self->_lastDequeuedFrameMs = nowMs;
        self->_lastIdleLogMs = 0;

        if (!self->_lastFrameNumber) {
            self->_activeWndVideoStats.measurementStartTimestamp = nowMs;
            self->_lastFrameNumber = du->frameNumber;
        } else {
            self->_activeWndVideoStats.networkDroppedFrames += du->frameNumber - (self->_lastFrameNumber + 1);
            self->_activeWndVideoStats.totalFrames += du->frameNumber - (self->_lastFrameNumber + 1);
            self->_lastFrameNumber = du->frameNumber;
        }

        uint64_t now = nowMs;
        if (now - self->_activeWndVideoStats.measurementStartTimestamp >= 1000) {
            self->_activeWndVideoStats.totalFps = (float)self->_activeWndVideoStats.totalFrames;
            self->_activeWndVideoStats.receivedFps = (float)self->_activeWndVideoStats.receivedFrames;
            self->_activeWndVideoStats.decodedFps = (float)self->_activeWndVideoStats.decodedFrames;
            self->_activeWndVideoStats.renderedFps = (float)self->_activeWndVideoStats.renderedFrames;

            self->_activeWndVideoStats.jitterMs = self->_jitterMsEstimate;
            self->_activeWndVideoStats.renderedFpsOnePercentLow = MLComputeRenderedOnePercentLowFps(self->_renderIntervalSamples,
                                                                                                   self->_renderIntervalSampleCount);

            VideoStats completedStats = self->_activeWndVideoStats;
            completedStats.lastUpdatedTimestamp = now;
            self->_videoStats = completedStats;

            memset(&self->_activeWndVideoStats, 0, sizeof(VideoStats));
            self->_activeWndVideoStats.measurementStartTimestamp = now;
        }

        self->_activeWndVideoStats.receivedFrames++;
        self->_activeWndVideoStats.totalFrames++;

        if (fullLengthBytes > 0) {
            self->_activeWndVideoStats.receivedBytes += (uint64_t)fullLengthBytes;
        }

        // RFC3550-style jitter estimate using frame timing deltas.
        if (self->_lastFrameReceiveTimeMs != 0 && self->_lastFramePresentationTimeMs != 0) {
            int64_t arrivalDelta = (int64_t)(receiveTimeMs - self->_lastFrameReceiveTimeMs);
            int64_t nominalDelta = (int64_t)((int64_t)presentationTimeMs - (int64_t)self->_lastFramePresentationTimeMs);
            int64_t d = arrivalDelta - nominalDelta;
            if (d < 0) d = -d;
            self->_jitterMsEstimate += ((float)d - self->_jitterMsEstimate) / 16.0f;
        }
        self->_lastFrameReceiveTimeMs = receiveTimeMs;
        self->_lastFramePresentationTimeMs = presentationTimeMs;

        if (du->frameHostProcessingLatency != 0) {
            self->_activeWndVideoStats.totalHostProcessingLatency += du->frameHostProcessingLatency;
            self->_activeWndVideoStats.framesWithHostProcessingLatency++;
        }

        uint64_t decodeStart = LiGetMillis();
        int ret = DrSubmitDecodeUnit(du);
        LiCompleteVideoFrameCtx(depacketizerCtx, handle, ret);

        if (ret == DR_OK) {
            uint64_t renderSampleNowMs = LiGetMillis();
            self->_activeWndVideoStats.decodedFrames++;
            self->_activeWndVideoStats.totalDecodeTime += LiGetMillis() - decodeStart;
            if (self->_activeRendererMode != MLActiveVideoRendererModeEnhanced) {
                [self recordRenderedFrameSampleAtTimeMs:renderSampleNowMs
                                          enqueueTimeMs:enqueueTimeMs];
            }

            if (depacketizerCtx->connectionContext != NULL) {
                PML_INPUT_STREAM_CONTEXT inputCtx = &depacketizerCtx->connectionContext->inputContext;
                if (LiIsScrollTraceDiagnosticsEnabledCtx(inputCtx) &&
                    LiIsScrollTraceAwaitingRenderCtx(inputCtx) &&
                    LiGetScrollTraceIdCtx(inputCtx) != 0) {
                    uint64_t traceId = LiGetScrollTraceIdCtx(inputCtx);
                    uint64_t startMs = LiGetScrollTraceStartMsCtx(inputCtx);
                    uint64_t localDispatchMs = LiGetScrollTraceLocalDispatchMsCtx(inputCtx);
                    uint64_t sendMs = LiGetScrollTraceSentMsCtx(inputCtx);
                    short amount = LiGetScrollTraceLastDispatchAmountCtx(inputCtx);
                    BOOL horizontal = LiGetScrollTraceLastDispatchHorizontalCtx(inputCtx) ? YES : NO;
                    BOOL highRes = LiGetScrollTraceLastDispatchHighResCtx(inputCtx) ? YES : NO;
                    unsigned long long startAgeMs = startMs != 0 && renderSampleNowMs >= startMs ? renderSampleNowMs - startMs : 0;
                    unsigned long long localAgeMs = localDispatchMs != 0 && renderSampleNowMs >= localDispatchMs ? renderSampleNowMs - localDispatchMs : 0;
                    unsigned long long sendAgeMs = sendMs != 0 && renderSampleNowMs >= sendMs ? renderSampleNowMs - sendMs : 0;

                    if (amount != 0 && localDispatchMs != 0 && sendMs != 0) {
                        Log(LOG_D, @"[inputdiag] scroll-trace render trace=%llu axis=%@ amount=%d highRes=%d frame=%d startAge=%llums localAge=%llums sendAge=%llums pending=%d",
                            (unsigned long long)traceId,
                            horizontal ? @"H" : @"V",
                            (int)amount,
                            highRes ? 1 : 0,
                            du->frameNumber,
                            startAgeMs,
                            localAgeMs,
                            sendAgeMs,
                            LiGetPendingVideoFramesCtx(depacketizerCtx));
                    }
                    LiCompleteScrollTraceRenderCtx(inputCtx);
                }
            }
        }

        VideoStats snapshotStats = self->_activeWndVideoStats;
        snapshotStats.jitterMs = self->_jitterMsEstimate;
        snapshotStats.renderedFpsOnePercentLow = MLComputeRenderedOnePercentLowFps(self->_renderIntervalSamples,
                                                                                   self->_renderIntervalSampleCount);
        snapshotStats.lastUpdatedTimestamp = LiGetMillis();
        self->_videoStats = snapshotStats;

        int pendingFrames = LiGetPendingVideoFramesCtx(depacketizerCtx);
        if (pendingFrames <= desiredPendingFrames) {
            break;
        }
    }

    if (!dequeuedAny && self->_lastDequeuedFrameMs != 0) {
        uint64_t idleMs = LiGetMillis() - self->_lastDequeuedFrameMs;
        if (idleMs >= 2000 &&
            (self->_lastIdleLogMs == 0 || LiGetMillis() - self->_lastIdleLogMs >= 5000)) {
            self->_lastIdleLogMs = LiGetMillis();
            Log(LOG_W, @"[diag] Pull renderer idle for %llums pending=%d",
                (unsigned long long)idleMs,
                LiGetPendingVideoFramesCtx(depacketizerCtx));
        }
    }

    BOOL shouldPresentDeferredSourceFrame = NO;
    @synchronized(self) {
        shouldPresentDeferredSourceFrame =
            (self->_deferredCurrentSourceSequence != 0 && self->_pendingInterpolatedPresented);
    }
    if (shouldPresentDeferredSourceFrame) {
        [self requestEnhancedDraw];
    }

    return kCVReturnSuccess;
}

- (void)stop
{
    if (_displayLink != NULL) {
        CVDisplayLinkStop(_displayLink);
        CVDisplayLinkRelease(_displayLink);
        _displayLink = NULL;
    }

    [self clearCurrentFrame];
    [self teardownDecompressionSession];
    [self teardownEnhancementProcessor];
    [self teardownFrameInterpolationProcessor];
    [self teardownHDRPresentationResources];
    [self teardownNativePresentationResources];
    _intermediateTexture = nil;
    _metalDrawScheduled = NO;
    _lastLoggedDrawableWidth = 0;
    _lastLoggedDrawableHeight = 0;
    _rendererStartTimeMs = 0;
    _enhancedStartupPacingUntilMs = 0;
    _enhancedStartupPresentedFrameCount = 0;
    _didLogEnhancedStartupPacing = NO;
    _metalInflightLimit = 0;
    _lastDrawableUnavailableLogMs = 0;
    _drawableUnavailableCount = 0;
    _lastInflightBackpressureLogMs = 0;
    _inflightBackpressureCount = 0;
}

- (void)dealloc
{
    [self stop];
}

#define FRAME_START_PREFIX_SIZE 4
#define NALU_START_PREFIX_SIZE 3
#define NAL_LENGTH_PREFIX_SIZE 4

- (Boolean)readyForPictureData
{
    if (videoFormat & VIDEO_FORMAT_MASK_AV1) {
        return true;
    }
    if (videoFormat & VIDEO_FORMAT_MASK_H264) {
        return !waitingForSps && !waitingForPps;
    }
    else {
        // H.265 requires VPS in addition to SPS and PPS
        return !waitingForVps && !waitingForSps && !waitingForPps;
    }
}

- (NSData *)av1CodecConfigurationBoxForFrame:(NSData *)frameData
{
    AVIOContext *ioctx = NULL;
    int err = avio_open_dyn_buf(&ioctx);
    if (err < 0) {
        Log(LOG_E, @"avio_open_dyn_buf() failed: %d", err);
        return nil;
    }

    err = ff_isom_write_av1c(ioctx, (uint8_t *)frameData.bytes, (int)frameData.length, 1);
    if (err < 0) {
        Log(LOG_E, @"ff_isom_write_av1c() failed: %d", err);
    }

    uint8_t *av1cBuf = NULL;
    int av1cBufLen = avio_close_dyn_buf(ioctx, &av1cBuf);
    NSData *data = nil;
    if (err >= 0 && av1cBufLen > 0) {
        data = [NSData dataWithBytes:av1cBuf length:av1cBufLen];
    }

    av_free(av1cBuf);
    return data;
}

- (CMVideoFormatDescriptionRef)createAV1FormatDescriptionForIDRFrame:(NSData *)frameData
{
    NSMutableDictionary *extensions = [[NSMutableDictionary alloc] init];

    CodedBitstreamContext *cbsCtx = NULL;
    int err = ff_cbs_init(&cbsCtx, AV_CODEC_ID_AV1, NULL);
    if (err < 0) {
        Log(LOG_E, @"ff_cbs_init() failed: %d", err);
        return nil;
    }

    AVPacket avPacket = {};
    avPacket.data = (uint8_t *)frameData.bytes;
    avPacket.size = (int)frameData.length;

    CodedBitstreamFragment cbsFrag = {};
    err = ff_cbs_read_packet(cbsCtx, &cbsFrag, &avPacket);
    if (err < 0) {
        Log(LOG_E, @"ff_cbs_read_packet() failed: %d", err);
        ff_cbs_close(&cbsCtx);
        return nil;
    }

#define SET_CFSTR_EXTENSION(key, value) extensions[(__bridge NSString*)key] = (__bridge NSString*)(value)
#define SET_EXTENSION(key, value) extensions[(__bridge NSString*)key] = (value)

    SET_EXTENSION(kCMFormatDescriptionExtension_FormatName, @"av01");
    SET_EXTENSION(kCMFormatDescriptionExtension_Depth, @24);

    CodedBitstreamAV1Context *bitstreamCtx = (CodedBitstreamAV1Context *)cbsCtx->priv_data;
    AV1RawSequenceHeader *seqHeader = bitstreamCtx->sequence_header;
    if (seqHeader == NULL) {
        Log(LOG_E, @"AV1 sequence header not found in IDR frame");
        ff_cbs_fragment_free(&cbsFrag);
        ff_cbs_close(&cbsCtx);
        return nil;
    }

    switch (seqHeader->color_config.color_primaries) {
        case 1:
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ColorPrimaries,
                                kCMFormatDescriptionColorPrimaries_ITU_R_709_2);
            break;
        case 6:
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ColorPrimaries,
                                kCMFormatDescriptionColorPrimaries_SMPTE_C);
            break;
        case 9:
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ColorPrimaries,
                                kCMFormatDescriptionColorPrimaries_ITU_R_2020);
            break;
        default:
            break;
    }

    switch (seqHeader->color_config.transfer_characteristics) {
        case 1:
        case 6:
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_ITU_R_709_2);
            break;
        case 7:
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_SMPTE_240M_1995);
            break;
        case 8:
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_Linear);
            break;
        case 14:
        case 15:
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_ITU_R_2020);
            break;
        case 16:
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ);
            break;
        case 17:
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG);
            break;
        default:
            break;
    }

    switch (seqHeader->color_config.matrix_coefficients) {
        case 1:
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2);
            break;
        case 6:
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4);
            break;
        case 7:
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995);
            break;
        case 9:
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_ITU_R_2020);
            break;
        default:
            break;
    }

    SET_EXTENSION(kCMFormatDescriptionExtension_FullRangeVideo, @(seqHeader->color_config.color_range == 1));
    SET_EXTENSION(kCMFormatDescriptionExtension_FieldCount, @(1));

    switch (seqHeader->color_config.chroma_sample_position) {
        case 1:
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ChromaLocationTopField,
                                kCMFormatDescriptionChromaLocation_Left);
            break;
        case 2:
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ChromaLocationTopField,
                                kCMFormatDescriptionChromaLocation_TopLeft);
            break;
        default:
            break;
    }

    NSData *av1Config = [self av1CodecConfigurationBoxForFrame:frameData];
    if (av1Config != nil) {
        extensions[(__bridge NSString *)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = @{
            @"av1C": av1Config,
        };
    }
    extensions[@"BitsPerComponent"] = @(bitstreamCtx->bit_depth);

    CMVideoFormatDescriptionRef av1FormatDesc = NULL;
    OSStatus status = CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
                                                     kCMVideoCodecType_AV1,
                                                     bitstreamCtx->frame_width,
                                                     bitstreamCtx->frame_height,
                                                     (__bridge CFDictionaryRef)extensions,
                                                     &av1FormatDesc);
    if (status != noErr) {
        Log(LOG_E, @"Failed to create AV1 format description: %d", (int)status);
        av1FormatDesc = NULL;
    }

#undef SET_EXTENSION
#undef SET_CFSTR_EXTENSION

    ff_cbs_fragment_free(&cbsFrag);
    ff_cbs_close(&cbsCtx);
    return av1FormatDesc;
}

- (void)updateBufferForRange:(CMBlockBufferRef)frameBuffer dataBlock:(CMBlockBufferRef)dataBuffer offset:(int)offset length:(int)nalLength
{
    OSStatus status;
    size_t oldOffset = CMBlockBufferGetDataLength(frameBuffer);

    // Append a 4 byte buffer to the frame block for the length prefix
    status = CMBlockBufferAppendMemoryBlock(frameBuffer, NULL,
                                            NAL_LENGTH_PREFIX_SIZE,
                                            kCFAllocatorDefault, NULL, 0,
                                            NAL_LENGTH_PREFIX_SIZE, 0);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferAppendMemoryBlock failed: %d", (int)status);
        return;
    }

    // Write the length prefix to the new buffer
    const int dataLength = nalLength - NALU_START_PREFIX_SIZE;
    const uint8_t lengthBytes[] = {(uint8_t)(dataLength >> 24), (uint8_t)(dataLength >> 16),
        (uint8_t)(dataLength >> 8), (uint8_t)dataLength};
    status = CMBlockBufferReplaceDataBytes(lengthBytes, frameBuffer,
                                           oldOffset, NAL_LENGTH_PREFIX_SIZE);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferReplaceDataBytes failed: %d", (int)status);
        return;
    }

    // Attach the data buffer to the frame buffer by reference
    status = CMBlockBufferAppendBufferReference(frameBuffer, dataBuffer, offset + NALU_START_PREFIX_SIZE, dataLength, 0);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferAppendBufferReference failed: %d", (int)status);
        return;
    }
}

- (int)submitDecodeUnit:(void *)du_void {
    PDECODE_UNIT decodeUnit = (PDECODE_UNIT)du_void;
    int offset = 0;
    int ret;

    // Fallback to standard malloc to avoid potential pool/locking issues
    unsigned char* data = (unsigned char*) malloc(decodeUnit->fullLength);
    if (data == NULL) {
        return DR_NEED_IDR;
    }

    PLENTRY entry = decodeUnit->bufferList;
    while (entry != NULL) {
        if (entry->bufferType != BUFFER_TYPE_PICDATA) {
            ret = [self submitDecodeBuffer:(unsigned char*)entry->data
                                    length:entry->length
                                bufferType:entry->bufferType
                                 frameType:decodeUnit->frameType
                                       pts:decodeUnit->presentationTimeMs
                               frameNumber:decodeUnit->frameNumber
                            enqueueTimeMs:decodeUnit->enqueueTimeMs];
            if (ret != DR_OK) {
                free(data);
                return ret;
            }
        }
        else {
            memcpy(&data[offset], entry->data, entry->length);
            offset += entry->length;
        }

        entry = entry->next;
    }

    // Standard submission - renderer takes ownership and will free()
    return [self submitDecodeBuffer:data
                             length:offset
                         bufferType:BUFFER_TYPE_PICDATA
                          frameType:decodeUnit->frameType
                                pts:decodeUnit->presentationTimeMs
                        frameNumber:decodeUnit->frameNumber
                     enqueueTimeMs:decodeUnit->enqueueTimeMs];
}

// Legacy entry point
- (int)submitDecodeBuffer:(unsigned char *)data length:(int)length bufferType:(int)bufferType frameType:(int)frameType pts:(unsigned int)pts {
    return [self submitDecodeBuffer:data
                             length:length
                         bufferType:bufferType
                          frameType:frameType
                                pts:pts
                        frameNumber:0
                     enqueueTimeMs:0
                        blockSource:NULL];
}

- (int)submitDecodeBuffer:(unsigned char *)data
                   length:(int)length
               bufferType:(int)bufferType
                frameType:(int)frameType
                      pts:(unsigned int)pts
              frameNumber:(uint32_t)frameNumber
            enqueueTimeMs:(uint64_t)enqueueTimeMs
{
    return [self submitDecodeBuffer:data
                             length:length
                         bufferType:bufferType
                          frameType:frameType
                                pts:pts
                        frameNumber:frameNumber
                     enqueueTimeMs:enqueueTimeMs
                        blockSource:NULL];
}

// This function must free data for bufferType == BUFFER_TYPE_PICDATA (if blockSource is NULL)
- (int)submitDecodeBuffer:(unsigned char *)data
                   length:(int)length
               bufferType:(int)bufferType
                frameType:(int)frameType
                      pts:(unsigned int)pts
              frameNumber:(uint32_t)frameNumber
           enqueueTimeMs:(uint64_t)enqueueTimeMs
              blockSource:(CMBlockBufferCustomBlockSource *)blockSource
{
    OSStatus status;

    if (bufferType != BUFFER_TYPE_PICDATA) {
        if (bufferType == BUFFER_TYPE_VPS) {
            Log(LOG_D, @"Got VPS");
            vpsData = [NSData dataWithBytes:&data[FRAME_START_PREFIX_SIZE] length:length - FRAME_START_PREFIX_SIZE];
            waitingForVps = false;

            // We got a new VPS so wait for a new SPS to match it
            waitingForSps = true;
        }
        else if (bufferType == BUFFER_TYPE_SPS) {
            Log(LOG_D, @"Got SPS");
            spsData = [NSData dataWithBytes:&data[FRAME_START_PREFIX_SIZE] length:length - FRAME_START_PREFIX_SIZE];
            waitingForSps = false;

            // We got a new SPS so wait for a new PPS to match it
            waitingForPps = true;
        } else if (bufferType == BUFFER_TYPE_PPS) {
            Log(LOG_D, @"Got PPS");
            ppsData = [NSData dataWithBytes:&data[FRAME_START_PREFIX_SIZE] length:length - FRAME_START_PREFIX_SIZE];
            waitingForPps = false;
        }

        // See if we've got all the parameter sets we need for our video format
        if ([self readyForPictureData]) {

            if (formatDesc != nil) {
                CFRelease(formatDesc);
                formatDesc = nil;
            }

            if (videoFormat & VIDEO_FORMAT_MASK_H264) {
                const uint8_t* const parameterSetPointers[] = { [spsData bytes], [ppsData bytes] };
                const size_t parameterSetSizes[] = { [spsData length], [ppsData length] };

                Log(LOG_D, @"Constructing new H264 format description");
                status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                                                                             2, /* count of parameter sets */
                                                                             parameterSetPointers,
                                                                             parameterSetSizes,
                                                                             NAL_LENGTH_PREFIX_SIZE,
                                                                             &formatDesc);
                if (status != noErr) {
                    Log(LOG_E, @"Failed to create H264 format description: %d", (int)status);
                    formatDesc = NULL;
                }
            }
            else {
                const uint8_t* const parameterSetPointers[] = { [vpsData bytes], [spsData bytes], [ppsData bytes] };
                const size_t parameterSetSizes[] = { [vpsData length], [spsData length], [ppsData length] };

                Log(LOG_I, @"Constructing new HEVC format description");

                if (@available(iOS 11.0, macOS 10.14, *)) {
                    status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault,
                                                                                 3, /* count of parameter sets */
                                                                                 parameterSetPointers,
                                                                                 parameterSetSizes,
                                                                                 NAL_LENGTH_PREFIX_SIZE,
                                                                                 nil,
                                                                                 &formatDesc);
                } else {
                    // This means Moonlight-common-c decided to give us an HEVC stream
                    // even though we said we couldn't support it. All we can do is abort().
                    abort();
                }

                if (status != noErr) {
                    Log(LOG_E, @"Failed to create HEVC format description: %d", (int)status);
                    formatDesc = NULL;
                }
            }

            if ([self usesDecompressionSession]) {
                if (![self createDecompressionSession]) {
                    [self fallbackToCompatibilityRenderer];
                }
            }
        }

        // Data is NOT to be freed here. It's a direct usage of the caller's buffer.

        // No frame data to submit for these NALUs
        return DR_OK;
    }

    if ((videoFormat & VIDEO_FORMAT_MASK_AV1) && frameType != FRAME_TYPE_PFRAME) {
        if (formatDesc != nil) {
            CFRelease(formatDesc);
            formatDesc = nil;
        }

        NSData *fullFrameData = [NSData dataWithBytesNoCopy:data length:length freeWhenDone:NO];
        Log(LOG_I, @"Constructing new AV1 format description");
        formatDesc = [self createAV1FormatDescriptionForIDRFrame:fullFrameData];

        if ([self usesDecompressionSession] && formatDesc != NULL) {
            if (![self createDecompressionSession]) {
                [self fallbackToCompatibilityRenderer];
            }
        }
    }

    if (formatDesc == NULL) {
        // Can't decode if we haven't gotten our parameter sets yet
        free(data);
        return DR_NEED_IDR;
    }

    // Check for previous decoder errors before doing anything
    if (displayLayer && displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        Log(LOG_E, @"Display layer rendering failed: %@", displayLayer.error);

        // Recreate the display layer
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self reinitializeDisplayLayer];
        });

        // Request an IDR frame to initialize the new decoder
        free(data);
        return DR_NEED_IDR;
    }

    // Now we're decoding actual frame data here
    CMBlockBufferRef frameBlockBuffer;
    CMBlockBufferRef dataBlockBuffer;

    if (blockSource != NULL) {
        status = CMBlockBufferCreateWithMemoryBlock(NULL, data, length, kCFAllocatorNull, blockSource, 0, length, 0, &dataBlockBuffer);
    } else {
        // Legacy path: uses kCFAllocatorDefault which calls free()
        status = CMBlockBufferCreateWithMemoryBlock(NULL, data, length, kCFAllocatorDefault, NULL, 0, length, 0, &dataBlockBuffer);
    }

    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferCreateWithMemoryBlock failed: %d", (int)status);
        if (blockSource != NULL) {
            blockSource->FreeBlock(NULL, data, length);
        } else {
            free(data);
        }
        return DR_NEED_IDR;
    }

    // From now on, CMBlockBuffer owns the data pointer and will free it when it's dereferenced

    status = CMBlockBufferCreateEmpty(NULL, 0, 0, &frameBlockBuffer);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferCreateEmpty failed: %d", (int)status);
        CFRelease(dataBlockBuffer);
        return DR_NEED_IDR;
    }

    if (videoFormat & (VIDEO_FORMAT_MASK_H264 | VIDEO_FORMAT_MASK_H265)) {
        int lastOffset = -1;
        for (int i = 0; i < length - FRAME_START_PREFIX_SIZE; i++) {
            // Search for a NALU
            if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 1) {
                // It's the start of a new NALU
                if (lastOffset != -1) {
                    // We've seen a start before this so enqueue that NALU
                    [self updateBufferForRange:frameBlockBuffer dataBlock:dataBlockBuffer offset:lastOffset length:i - lastOffset];
                }

                lastOffset = i;
            }
        }

        if (lastOffset != -1) {
            // Enqueue the remaining data
            [self updateBufferForRange:frameBlockBuffer dataBlock:dataBlockBuffer offset:lastOffset length:length - lastOffset];
        }
    } else {
        status = CMBlockBufferAppendBufferReference(frameBlockBuffer, dataBlockBuffer, 0, length, 0);
        if (status != noErr) {
            Log(LOG_E, @"CMBlockBufferAppendBufferReference failed: %d", (int)status);
            CFRelease(dataBlockBuffer);
            CFRelease(frameBlockBuffer);
            return DR_NEED_IDR;
        }
    }

    // From now on, CMBlockBuffer owns the data pointer and will free it when it's dereferenced

    CMSampleBufferRef sampleBuffer;

    CMSampleTimingInfo sampleTiming = {
        .duration = self.frameRate > 0 ? CMTimeMake(1, self.frameRate) : kCMTimeInvalid,
        .presentationTimeStamp = CMTimeMake(pts, 1000),
        .decodeTimeStamp = kCMTimeInvalid,
    };

    status = CMSampleBufferCreate(kCFAllocatorDefault,
                                  frameBlockBuffer,
                                  true, NULL,
                                  NULL, formatDesc, 1, 1,
                                  &sampleTiming, 0, NULL,
                                  &sampleBuffer);
    if (status != noErr) {
        Log(LOG_E, @"CMSampleBufferCreate failed: %d", (int)status);
        CFRelease(dataBlockBuffer);
        CFRelease(frameBlockBuffer);
        return DR_NEED_IDR;
    }

//    TODO: Make P3 color work
//    CVBufferRemoveAttachment(frame, kCVImageBufferCGColorSpaceKey);
//    CVBufferSetAttachment(frame, kCVImageBufferCGColorSpaceKey, CGColorSpaceCreateWithName([NSScreen.mainScreen canRepresentDisplayGamut:NSDisplayGamutP3] ? kCGColorSpaceDisplayP3 : kCGColorSpaceSRGB), kCVAttachmentMode_ShouldPropagate);

    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
    CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);

    CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    CFDictionarySetValue(dict, kCMSampleAttachmentKey_IsDependedOnByOthers, kCFBooleanTrue);

    if (frameType == FRAME_TYPE_PFRAME) {
        // P-frame
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DependsOnOthers, kCFBooleanTrue);
    } else {
        // I-frame
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_NotSync, kCFBooleanFalse);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DependsOnOthers, kCFBooleanFalse);
    }

    // Enqueue the next frame
    if ([self usesDecompressionSession]) {
        if (_decompressionSession) {
            VTDecodeFrameFlags decodeFlags = kVTDecodeFrame_EnableAsynchronousDecompression |
                                             kVTDecodeFrame_1xRealTimePlayback;
            VTDecodeInfoFlags infoFlags = 0;
            MLDecodeFrameContext *frameContext = NULL;
            if (_activeRendererMode == MLActiveVideoRendererModeEnhanced) {
                frameContext = malloc(sizeof(*frameContext));
                if (frameContext != NULL) {
                    frameContext->enqueueTimeMs = enqueueTimeMs;
                    frameContext->frameNumber = frameNumber;
                }
            }
            status = VTDecompressionSessionDecodeFrame(_decompressionSession,
                                                       sampleBuffer,
                                                       decodeFlags,
                                                       frameContext,
                                                       &infoFlags);
            if (status != noErr) {
                if (frameContext != NULL) {
                    free(frameContext);
                }
                Log(LOG_W, @"VTDecompressionSessionDecodeFrame failed: %d infoFlags=0x%x. Falling back to Compatibility.",
                    (int)status,
                    (unsigned int)infoFlags);
                [self fallbackToCompatibilityRenderer];
                [displayLayer enqueueSampleBuffer:sampleBuffer];
            }
        } else {
            [self fallbackToCompatibilityRenderer];
            [displayLayer enqueueSampleBuffer:sampleBuffer];
        }
    } else {
        [displayLayer enqueueSampleBuffer:sampleBuffer];
    }

    // Dereference the buffers
    CFRelease(dataBlockBuffer);
    CFRelease(frameBlockBuffer);
    CFRelease(sampleBuffer);

    return DR_OK;
}

@end
