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

@import VideoToolbox;


@interface VideoDecoderRenderer ()
@property (nonatomic) int frameRate;

@end


@implementation VideoDecoderRenderer {
    OSView *_view;

    AVSampleBufferDisplayLayer* displayLayer;
    RendererLayerContainer *layerContainer;
    Boolean waitingForSps, waitingForPps, waitingForVps;
    int videoFormat;
    
    NSData *spsData, *ppsData, *vpsData;
    CMVideoFormatDescriptionRef _imageFormatDesc;
    CMVideoFormatDescriptionRef formatDesc;

    CVDisplayLinkRef _displayLink;
    
    VideoStats _activeWndVideoStats;
    int _lastFrameNumber;
}

@synthesize videoFormat;

- (void)reinitializeDisplayLayer
{
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

- (void)setupWithVideoFormat:(int)videoFormat frameRate:(int)frameRate
{
    self->videoFormat = videoFormat;
    self.frameRate = frameRate;
    memset(&_activeWndVideoStats, 0, sizeof(_activeWndVideoStats));
    _lastFrameNumber = 0;
    _videoStats = (VideoStats){0};
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
    if (displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
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
    [displayLayer enqueueSampleBuffer:sampleBuffer];
    
    // Dereference the buffers
    CFRelease(dataBlockBuffer);
    CFRelease(frameBlockBuffer);
    CFRelease(sampleBuffer);
    
    return DR_OK;
}

@end
