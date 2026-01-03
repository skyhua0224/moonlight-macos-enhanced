//
//  VideoDecoderRenderer.m
//  Moonlight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "VideoDecoderRenderer.h"
#import "RendererLayerContainer.h"

#include "Limelight.h"
#include <pthread.h>
#import "Moonlight-Swift.h"

@import VideoToolbox;
@import MetalKit;
@import MetalFX;

@interface VideoDecoderRenderer () <MTKViewDelegate>
@property (nonatomic) int frameRate;

@end

static NSString *const kMetalShaderSource = @"#include <metal_stdlib>\n"
"using namespace metal;\n"
"kernel void ycbcrToRgb(texture2d<float, access::read> textureY [[texture(0)]],\n"
"                       texture2d<float, access::read> textureCbCr [[texture(1)]],\n"
"                       texture2d<float, access::write> textureRGB [[texture(2)]],\n"
"                       uint2 gid [[thread_position_in_grid]]) {\n"
"    if (gid.x >= textureRGB.get_width() || gid.y >= textureRGB.get_height()) return;\n"
"    float3 colorOffset = float3(0, -0.5, -0.5);\n"
"    float3x3 colorMatrix = float3x3(\n"
"        float3(1, 1, 1),\n"
"        float3(0, -0.3441, 1.772),\n"
"        float3(1.402, -0.7141, 0)\n"
"    );\n"
"    float y = textureY.read(gid).r;\n"
"    float2 cbcr = textureCbCr.read(gid / 2).rg;\n"
"    float3 ycbcr = float3(y, cbcr.x, cbcr.y);\n"
"    float3 rgb = colorMatrix * (ycbcr + colorOffset);\n"
"    textureRGB.write(float4(rgb, 1.0), gid);\n"
"}\n";

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
    id<MTLFXSpatialScaler> _spatialScaler;
    id<MTLTexture> _upscaledTexture;
    id<MTLComputePipelineState> _computePipelineState;
    
    // Common
    Boolean waitingForSps, waitingForPps, waitingForVps;

    int videoFormat;
    
    NSData *spsData, *ppsData, *vpsData;
    CMVideoFormatDescriptionRef _imageFormatDesc;
    CMVideoFormatDescriptionRef formatDesc;

    CVDisplayLinkRef _displayLink;
    
    VideoStats _activeWndVideoStats;
    int _lastFrameNumber;
    
    int _upscalingMode;
    VTDecompressionSessionRef _decompressionSession;
    CVImageBufferRef _currentFrame;
}

@synthesize videoFormat;

- (void)reinitializeDisplayLayer
{
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
    
    // We need some parameter sets before we can properly start decoding frames
    waitingForSps = true;
    spsData = nil;
    waitingForPps = true;
    ppsData = nil;
    waitingForVps = true;
    vpsData = nil;
    
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
    
    [self reinitializeDisplayLayer];
        
    return self;
}

- (void)setupWithVideoFormat:(int)videoFormat frameRate:(int)frameRate upscalingMode:(int)upscalingMode
{
    self->videoFormat = videoFormat;
    self.frameRate = frameRate;
    self->_upscalingMode = upscalingMode;
    memset(&_activeWndVideoStats, 0, sizeof(_activeWndVideoStats));
    _lastFrameNumber = 0;
    _videoStats = (VideoStats){0};
    
    if (_currentFrame) {
        CVBufferRelease(_currentFrame);
        _currentFrame = NULL;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_upscalingMode > 0) {
            [self setupMetalRenderer];
        } else {
            if (self->_metalView) {
                [self->_metalView removeFromSuperview];
                self->_metalView = nil;
                [self reinitializeDisplayLayer];
            }
        }
    });
}

- (void)setupMetalRenderer {
    if (_metalView) return;
    
    // Tear down AVSBDL
    [layerContainer removeFromSuperview];
    layerContainer = nil;
    displayLayer = nil;
    
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) {
        Log(LOG_E, @"Failed to create Metal device");
        return;
    }
    
    _metalView = [[MTKView alloc] initWithFrame:_view.bounds device:_device];
    _metalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _metalView.delegate = self;
    // We blit/copy into the drawable texture (and sometimes render into it),
    // which is not allowed when framebufferOnly is enabled.
    _metalView.framebufferOnly = NO;
    _metalView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    
    [_view addSubview:_metalView];
    
    _commandQueue = [_device newCommandQueue];
    
    CVReturn err = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, _device, nil, &_textureCache);
    if (err != kCVReturnSuccess) {
        Log(LOG_E, @"Failed to create texture cache: %d", err);
    }
    
    Log(LOG_I, @"Metal renderer initialized with upscaling mode: %d", _upscalingMode);
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
}

void decompressionOutputCallback(void *decompressionOutputRefCon, void *sourceFrameRefCon, OSStatus status, VTDecodeInfoFlags infoFlags, CVImageBufferRef imageBuffer, CMTime presentationTimeStamp, CMTime presentationDuration) {
    VideoDecoderRenderer *self = (__bridge VideoDecoderRenderer *)decompressionOutputRefCon;
    if (status == noErr && imageBuffer) {
        [self handleDecompressionOutput:imageBuffer];
    }
}

- (void)handleDecompressionOutput:(CVImageBufferRef)imageBuffer {
    @synchronized(self) {
        if (_currentFrame) {
            CVBufferRelease(_currentFrame);
        }
        _currentFrame = CVBufferRetain(imageBuffer);
    }
}

- (void)createDecompressionSession {
    if (_decompressionSession) {
        VTDecompressionSessionInvalidate(_decompressionSession);
        CFRelease(_decompressionSession);
        _decompressionSession = NULL;
    }
    
    VTDecompressionOutputCallbackRecord callbackRecord;
    callbackRecord.decompressionOutputCallback = decompressionOutputCallback;
    callbackRecord.decompressionOutputRefCon = (__bridge void *)self;
    
    NSDictionary *destinationImageBufferAttributes = @{
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    
    OSStatus status = VTDecompressionSessionCreate(kCFAllocatorDefault,
                                                   formatDesc,
                                                   NULL,
                                                   (__bridge CFDictionaryRef)destinationImageBufferAttributes,
                                                   &callbackRecord,
                                                   &_decompressionSession);
    if (status != noErr) {
        Log(LOG_E, @"VTDecompressionSessionCreate failed: %d", (int)status);
    }
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
}

- (void)drawInMTKView:(MTKView *)view {
    CVImageBufferRef frame = NULL;
    @synchronized(self) {
        if (_currentFrame) {
            frame = CVBufferRetain(_currentFrame);
        }
    }
    
    if (!frame) return;
    
    // Lazy init pipeline
    if (!_computePipelineState) {
        [self setupMetalPipeline];
    }
    if (!_computePipelineState || !_textureCache) {
        CVBufferRelease(frame);
        return;
    }
    
    size_t width = CVPixelBufferGetWidth(frame);
    size_t height = CVPixelBufferGetHeight(frame);
    
    // Create textures from YUV planes
    CVMetalTextureRef yTextureRef = NULL;
    CVMetalTextureRef uvTextureRef = NULL;
    
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache, frame, nil, MTLPixelFormatR8Unorm, width, height, 0, &yTextureRef);
    CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache, frame, nil, MTLPixelFormatRG8Unorm, width / 2, height / 2, 1, &uvTextureRef);
    
    if (yTextureRef && uvTextureRef) {
        id<MTLTexture> yTexture = CVMetalTextureGetTexture(yTextureRef);
        id<MTLTexture> uvTexture = CVMetalTextureGetTexture(uvTextureRef);
        
        id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
        id<MTLTexture> drawableTexture = view.currentDrawable.texture;
        
        if (drawableTexture) {
            // 1. YUV -> RGB
            MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
            desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
            desc.storageMode = MTLStorageModePrivate;
            id<MTLTexture> intermediateTexture = [_device newTextureWithDescriptor:desc];
            
            id<MTLComputeCommandEncoder> computeEncoder = [commandBuffer computeCommandEncoder];
            [computeEncoder setComputePipelineState:_computePipelineState];
            [computeEncoder setTexture:yTexture atIndex:0];
            [computeEncoder setTexture:uvTexture atIndex:1];
            [computeEncoder setTexture:intermediateTexture atIndex:2];
            
            NSUInteger w = _computePipelineState.threadExecutionWidth;
            NSUInteger h = _computePipelineState.maxTotalThreadsPerThreadgroup / w;
            MTLSize threadsPerThreadgroup = MTLSizeMake(w, h, 1);
            MTLSize threadgroups = MTLSizeMake((width + w - 1) / w, (height + h - 1) / h, 1);
            
            [computeEncoder dispatchThreadgroups:threadgroups threadsPerThreadgroup:threadsPerThreadgroup];
            [computeEncoder endEncoding];
            
            // 2. MetalFX Upscaling
            if (!_spatialScaler) {
                MTLFXSpatialScalerDescriptor *scalerDesc = [[MTLFXSpatialScalerDescriptor alloc] init];
                scalerDesc.inputWidth = width;
                scalerDesc.inputHeight = height;
                scalerDesc.outputWidth = drawableTexture.width;
                scalerDesc.outputHeight = drawableTexture.height;
                scalerDesc.colorTextureFormat = MTLPixelFormatBGRA8Unorm;
                scalerDesc.outputTextureFormat = view.colorPixelFormat;
                scalerDesc.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
                
                _spatialScaler = [scalerDesc newSpatialScalerWithDevice:_device];
            }
            
            // Handle Resize
            if (_spatialScaler.inputWidth != width || _spatialScaler.inputHeight != height || _spatialScaler.outputWidth != drawableTexture.width || _spatialScaler.outputHeight != drawableTexture.height) {
                 _spatialScaler = nil;
                 MTLFXSpatialScalerDescriptor *scalerDesc = [[MTLFXSpatialScalerDescriptor alloc] init];
                 scalerDesc.inputWidth = width;
                 scalerDesc.inputHeight = height;
                 scalerDesc.outputWidth = drawableTexture.width;
                 scalerDesc.outputHeight = drawableTexture.height;
                 scalerDesc.colorTextureFormat = MTLPixelFormatBGRA8Unorm;
                 scalerDesc.outputTextureFormat = view.colorPixelFormat;
                 scalerDesc.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
                 _spatialScaler = [scalerDesc newSpatialScalerWithDevice:_device];
            }
            
            if (_spatialScaler) {
                id<MTLTexture> targetTexture = drawableTexture;
                
                // MetalFX requires the output texture to be in private storage mode.
                // If the drawable texture is not private (e.g. Managed), we must render to an intermediate private texture.
                if (drawableTexture.storageMode != MTLStorageModePrivate) {
                    if (!_upscaledTexture || _upscaledTexture.width != drawableTexture.width || _upscaledTexture.height != drawableTexture.height || _upscaledTexture.pixelFormat != drawableTexture.pixelFormat) {
                        MTLTextureDescriptor *upscaledDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:drawableTexture.pixelFormat width:drawableTexture.width height:drawableTexture.height mipmapped:NO];
                        upscaledDesc.storageMode = MTLStorageModePrivate;
                        // MetalFXSpatialScaler internally uses a render pass for output; the output texture must be a render target.
                        upscaledDesc.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
                        _upscaledTexture = [_device newTextureWithDescriptor:upscaledDesc];
                    }
                    targetTexture = _upscaledTexture;
                }
                
                _spatialScaler.colorTexture = intermediateTexture;
                _spatialScaler.outputTexture = targetTexture;
                [_spatialScaler encodeToCommandBuffer:commandBuffer];
                
                if (targetTexture != drawableTexture) {
                    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
                    [blit copyFromTexture:targetTexture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(targetTexture.width, targetTexture.height, 1) toTexture:drawableTexture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
                    [blit endEncoding];
                }
            } else {
                id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
                [blit copyFromTexture:intermediateTexture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(width, height, 1) toTexture:drawableTexture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
                [blit endEncoding];
            }
            
            [commandBuffer presentDrawable:view.currentDrawable];
            [commandBuffer commit];
        }
    }
    
    if (yTextureRef) CFRelease(yTextureRef);
    if (uvTextureRef) CFRelease(uvTextureRef);
    CVBufferRelease(frame);
}

- (void)start
{
    dispatch_async(dispatch_get_main_queue(), ^{
        CGDirectDisplayID displayId = getDisplayID(self->_view.window.screen);
        CVReturn status = CVDisplayLinkCreateWithCGDisplay(displayId, &self->_displayLink);
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
        }
    });
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
    
    VIDEO_FRAME_HANDLE handle;
    PDECODE_UNIT du;
    
    while (LiPollNextVideoFrame(&handle, &du)) {
        if (!self->_lastFrameNumber) {
            self->_activeWndVideoStats.measurementStartTimestamp = LiGetMillis();
            self->_lastFrameNumber = du->frameNumber;
        } else {
            self->_activeWndVideoStats.networkDroppedFrames += du->frameNumber - (self->_lastFrameNumber + 1);
            self->_activeWndVideoStats.totalFrames += du->frameNumber - (self->_lastFrameNumber + 1);
            self->_lastFrameNumber = du->frameNumber;
        }
        
        uint64_t now = LiGetMillis();
        if (now - self->_activeWndVideoStats.measurementStartTimestamp >= 1000) {
            self->_activeWndVideoStats.totalFps = (float)self->_activeWndVideoStats.totalFrames;
            self->_activeWndVideoStats.receivedFps = (float)self->_activeWndVideoStats.receivedFrames;
            self->_activeWndVideoStats.decodedFps = (float)self->_activeWndVideoStats.decodedFrames;
            self->_activeWndVideoStats.renderedFps = (float)self->_activeWndVideoStats.renderedFrames;
            
            self->_videoStats = self->_activeWndVideoStats;
            
            memset(&self->_activeWndVideoStats, 0, sizeof(VideoStats));
            self->_activeWndVideoStats.measurementStartTimestamp = now;
        }
        
        self->_activeWndVideoStats.receivedFrames++;
        self->_activeWndVideoStats.totalFrames++;
        
        if (du->frameHostProcessingLatency != 0) {
            self->_activeWndVideoStats.totalHostProcessingLatency += du->frameHostProcessingLatency;
            self->_activeWndVideoStats.framesWithHostProcessingLatency++;
        }
        
        uint64_t decodeStart = LiGetMillis();
        int ret = DrSubmitDecodeUnit(du);
        LiCompleteVideoFrame(handle, ret);
        
        if (ret == DR_OK) {
            self->_activeWndVideoStats.decodedFrames++;
            self->_activeWndVideoStats.renderedFrames++;
            self->_activeWndVideoStats.totalDecodeTime += LiGetMillis() - decodeStart;
            self->_activeWndVideoStats.totalRenderTime += LiGetMillis() - du->enqueueTimeMs;
        }
        
        // Calculate the actual display refresh rate
        double displayRefreshRate = 1 / CVDisplayLinkGetActualOutputVideoRefreshPeriod(self->_displayLink);
        
        // Only pace frames if the display refresh rate is >= 90% of our stream frame rate.
        // Battery saver, accessibility settings, or device thermals can cause the actual
        // refresh rate of the display to drop below the physical maximum.
        if (displayRefreshRate >= self.frameRate * 0.9f) {
            // Keep one pending frame to smooth out gaps due to
            // network jitter at the cost of 1 frame of latency
            if (LiGetPendingVideoFrames() == 1) {
                break;
            }
        }
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
    
    if (_currentFrame) {
        CVBufferRelease(_currentFrame);
        _currentFrame = NULL;
    }
    if (_decompressionSession) {
        VTDecompressionSessionInvalidate(_decompressionSession);
        CFRelease(_decompressionSession);
        _decompressionSession = NULL;
    }
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
    if (videoFormat & VIDEO_FORMAT_MASK_H264) {
        return !waitingForSps && !waitingForPps;
    }
    else {
        // H.265 requires VPS in addition to SPS and PPS
        return !waitingForVps && !waitingForSps && !waitingForPps;
    }
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
                                       pts:decodeUnit->presentationTimeMs];
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
                                pts:decodeUnit->presentationTimeMs];
}

// Legacy entry point
- (int)submitDecodeBuffer:(unsigned char *)data length:(int)length bufferType:(int)bufferType frameType:(int)frameType pts:(unsigned int)pts {
    return [self submitDecodeBuffer:data length:length bufferType:bufferType frameType:frameType pts:pts blockSource:NULL];
}

// This function must free data for bufferType == BUFFER_TYPE_PICDATA (if blockSource is NULL)
- (int)submitDecodeBuffer:(unsigned char *)data length:(int)length bufferType:(int)bufferType frameType:(int)frameType pts:(unsigned int)pts blockSource:(CMBlockBufferCustomBlockSource *)blockSource
{
    OSStatus status;

    if (bufferType != BUFFER_TYPE_PICDATA) {
        if (bufferType == BUFFER_TYPE_VPS) {
            Log(LOG_I, @"Got VPS");
            vpsData = [NSData dataWithBytes:&data[FRAME_START_PREFIX_SIZE] length:length - FRAME_START_PREFIX_SIZE];
            waitingForVps = false;
            
            // We got a new VPS so wait for a new SPS to match it
            waitingForSps = true;
        }
        else if (bufferType == BUFFER_TYPE_SPS) {
            Log(LOG_I, @"Got SPS");
            spsData = [NSData dataWithBytes:&data[FRAME_START_PREFIX_SIZE] length:length - FRAME_START_PREFIX_SIZE];
            waitingForSps = false;
            
            // We got a new SPS so wait for a new PPS to match it
            waitingForPps = true;
        } else if (bufferType == BUFFER_TYPE_PPS) {
            Log(LOG_I, @"Got PPS");
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
                
                Log(LOG_I, @"Constructing new H264 format description");
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
            
            if (_upscalingMode > 0) {
                [self createDecompressionSession];
            }
        }
        
        // Data is NOT to be freed here. It's a direct usage of the caller's buffer.
        
        // No frame data to submit for these NALUs
        return DR_OK;
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
    
    // From now on, CMBlockBuffer owns the data pointer and will free it when it's dereferenced
    
    CMSampleBufferRef sampleBuffer;
    
    status = CMSampleBufferCreate(kCFAllocatorDefault,
                                  frameBlockBuffer,
                                  true, NULL,
                                  NULL, formatDesc, 1, 0,
                                  NULL, 0, NULL,
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
    if (_upscalingMode > 0) {
        if (_decompressionSession) {
            VTDecompressionSessionDecodeFrame(_decompressionSession, sampleBuffer, 0, NULL, NULL);
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
