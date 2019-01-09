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

#define TIMER_SLACK_MS 3
#define FRAME_HISTORY_ENTRIES 8

@implementation VideoDecoderRenderer {
    ViewType *_view;
    CVDisplayLinkRef _displayLink;
    StreamConfiguration *_config;
    os_unfair_lock _frameQueueLock;
    NSMutableArray<NSNumber *> *_frameQueueHistory;
    NSMutableArray<NSDictionary *> *_frameQueue;
    
    RendererLayerContainer *layerContainer;
    
    AVSampleBufferDisplayLayer* displayLayer;
    Boolean waitingForSps, waitingForPps, waitingForVps;
    int videoFormat;
    
    NSData *spsData, *ppsData, *vpsData;
    CMVideoFormatDescriptionRef formatDesc;
}

- (void)printStreamInfo {
    NSLog(@"SPS: %@, PPS: %@, VPS: %@", [self decodeData:spsData], [self decodeData:ppsData], [self decodeData:vpsData]);
}

- (NSString *)decodeData:(NSData *)data {
    NSMutableString *string = [NSMutableString string];
    const void *bytes = [data bytes];
    for (NSInteger i = 0; i < data.length; i++) {
        uint8_t byte = ((uint8_t *)bytes)[i];
        [string appendFormat:@"%02x ", byte];
    }
    return [string copy];
}

- (void)reinitializeDisplayLayer
{
    [layerContainer removeFromSuperview];
    layerContainer = [[RendererLayerContainer alloc] init];
    layerContainer.frame = _view.bounds;
    layerContainer.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    [_view addSubview:layerContainer];
    
    displayLayer = (AVSampleBufferDisplayLayer *)layerContainer.layer;
    displayLayer.backgroundColor = [ColorType blackColor].CGColor;
    
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

static CVReturn displayLinkOutputCallback(CVDisplayLinkRef displayLink,
                                          const CVTimeStamp *now,
                                          const CVTimeStamp *vsyncTime,
                                          CVOptionFlags flagsIn,
                                          CVOptionFlags *flagsOut,
                                          void *displayLinkContext)
{
    VideoDecoderRenderer *me = (__bridge VideoDecoderRenderer *)(displayLinkContext);
    
    [me vsyncCallback:(500 / me->_config.frameRate)];
    
    return kCVReturnSuccess;
}

- (BOOL)initializeDisplayLink
{
    CGDirectDisplayID displayId = getDisplayID(_view.window.screen);
    CVReturn status = CVDisplayLinkCreateWithCGDisplay(displayId, &_displayLink);
    if (status != kCVReturnSuccess) {
        Log(LOG_E, @"Failed to create CVDisplayLink: %d", status);
        return NO;
    }
    
    status = CVDisplayLinkSetOutputCallback(_displayLink, displayLinkOutputCallback, (__bridge void * _Nullable)(self));
    if (status != kCVReturnSuccess) {
        Log(LOG_E, @"CVDisplayLinkSetOutputCallback() failed: %d", status);
        return NO;
    }
    
    status = CVDisplayLinkStart(_displayLink);
    if (status != kCVReturnSuccess) {
        Log(LOG_E, @"CVDisplayLinkStart() failed: %d", status);
        return NO;
    }
    
    return YES;
}

- (id)initWithView:(ViewType *)view
{
    self = [super init];
    
    _view = view;
    
    _frameQueueHistory = [NSMutableArray arrayWithCapacity:FRAME_HISTORY_ENTRIES];
    _frameQueue = [NSMutableArray arrayWithCapacity:3];
    
    [self reinitializeDisplayLayer];
    
    [self initializeDisplayLink];
    
    return self;
}

- (void)dealloc
{
    if (_displayLink != NULL) {
        CVDisplayLinkStop(_displayLink);
        CVDisplayLinkRelease(_displayLink);
    }
    
    _frameQueueHistory = nil;
    _frameQueue = nil;
}

- (void)setupWithVideoFormat:(int)videoFormat
{
    self->videoFormat = videoFormat;
}

- (void)setStreamConfig:(StreamConfiguration *)config
{
    _config = config;
}

- (void)vsyncCallback:(int)timeUntilNextVsyncMillis
{
    int maxVideoFps = _config.frameRate;
    int displayFps = ceil(1 / CVDisplayLinkGetActualOutputVideoRefreshPeriod(_displayLink));
    
    // Make sure initialize() has been called
    assert(maxVideoFps != 0);
    
    assert(timeUntilNextVsyncMillis >= TIMER_SLACK_MS);
    
    uint64_t vsyncCallbackStartTime = mach_absolute_time() / 1000000;
    
    os_unfair_lock_lock(&_frameQueueLock);
    
    // If the queue length history entries are large, be strict
    // about dropping excess frames.
    int frameDropTarget = 1;
    
    // If we may get more frames per second than we can display, use
    // frame history to drop frames only if consistently above the
    // one queued frame mark.
    if (maxVideoFps >= displayFps) {
        for (int i = 0; i < _frameQueueHistory.count; i++) {
            if (_frameQueueHistory[i].integerValue <= 1) {
                // Be lenient as long as the queue length
                // resolves before the end of frame history
                frameDropTarget = 3;
                break;
            }
        }
        
        if (_frameQueueHistory.count == FRAME_HISTORY_ENTRIES) {
            [_frameQueueHistory removeLastObject];
        }
        
        [_frameQueueHistory insertObject:@(_frameQueue.count) atIndex:0];
    }
    
    // Catch up if we're several frames ahead
    while (_frameQueue.count > frameDropTarget) {
//        Log(LOG_I, @"Discarding");
//        [self printNaluTypeWithFrame:_frameQueue.lastObject];
        [_frameQueue removeLastObject];
    }
    
    
    if (_frameQueue.count == 0) {
        os_unfair_lock_unlock(&_frameQueueLock);
        
        while (mach_absolute_time() / 1000000 < vsyncCallbackStartTime + timeUntilNextVsyncMillis - TIMER_SLACK_MS) {
            usleep(1000);
            
            os_unfair_lock_lock(&_frameQueueLock);
            if (_frameQueue.count > 0) {
                // Don't release the lock
                goto RenderNextFrame;
            }
            os_unfair_lock_unlock(&_frameQueueLock);
        }
        
        // Nothing to render at this time
        return;
    }
    
RenderNextFrame:
    {
        // Grab the first frame
        NSDictionary *frame = _frameQueue.lastObject;
        os_unfair_lock_unlock(&_frameQueueLock);
        
        // Render it
//        [self printNaluTypeWithFrame:frame];
        [self renderFrameAtVsync:frame];
        
        // Free the frame
        frame = nil;
    }
}

- (void)printNaluTypeWithFrame:(NSDictionary *)frame {
    CMBlockBufferRef blockBuffer = (__bridge CMBlockBufferRef)frame[@"buffer"];
    size_t length = 1;
    char *pointer;
    CMBlockBufferGetDataPointer(blockBuffer, 4, &length, NULL, &pointer);
    Log(LOG_I, @"Frame nalu type: %c", pointer[0]);
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

- (Boolean)isNalReferencePicture:(unsigned char)nalType
{
    if (videoFormat & VIDEO_FORMAT_MASK_H264) {
        return nalType == 0x65;
    }
    else {
        // HEVC has several types of reference NALU types
        switch (nalType) {
            case 0x20:
            case 0x22:
            case 0x24:
            case 0x26:
            case 0x28:
            case 0x2A:
                return true;
            default:
                return false;
        }
    }
}

- (void)updateBufferForRange:(CMBlockBufferRef)existingBuffer data:(unsigned char *)data offset:(int)offset length:(int)nalLength
{
    OSStatus status;
    size_t oldOffset = CMBlockBufferGetDataLength(existingBuffer);
    
    // If we're at index 1 (first NALU in frame), enqueue this buffer to the memory block
    // so it can handle freeing it when the block buffer is destroyed
    if (offset == 1) {
        int dataLength = nalLength - NALU_START_PREFIX_SIZE;
        
        // Pass the real buffer pointer directly (no offset)
        // This will give it to the block buffer to free when it's released.
        // All further calls to CMBlockBufferAppendMemoryBlock will do so
        // at an offset and will not be asking the buffer to be freed.
        status = CMBlockBufferAppendMemoryBlock(existingBuffer, data,
                                                nalLength + 1, // Add 1 for the offset we decremented
                                                kCFAllocatorDefault,
                                                NULL, 0, nalLength + 1, 0);
        if (status != noErr) {
            Log(LOG_E, @"CMBlockBufferReplaceDataBytes failed: %d", (int)status);
            return;
        }
        
        // Write the length prefix to existing buffer
        const uint8_t lengthBytes[] = {(uint8_t)(dataLength >> 24), (uint8_t)(dataLength >> 16),
            (uint8_t)(dataLength >> 8), (uint8_t)dataLength};
        status = CMBlockBufferReplaceDataBytes(lengthBytes, existingBuffer,
                                               oldOffset, NAL_LENGTH_PREFIX_SIZE);
        if (status != noErr) {
            Log(LOG_E, @"CMBlockBufferReplaceDataBytes failed: %d", (int)status);
            return;
        }
    } else {
        // Append a 4 byte buffer to this block for the length prefix
        status = CMBlockBufferAppendMemoryBlock(existingBuffer, NULL,
                                                NAL_LENGTH_PREFIX_SIZE,
                                                kCFAllocatorDefault, NULL, 0,
                                                NAL_LENGTH_PREFIX_SIZE, 0);
        if (status != noErr) {
            Log(LOG_E, @"CMBlockBufferAppendMemoryBlock failed: %d", (int)status);
            return;
        }
        
        // Write the length prefix to the new buffer
        int dataLength = nalLength - NALU_START_PREFIX_SIZE;
        const uint8_t lengthBytes[] = {(uint8_t)(dataLength >> 24), (uint8_t)(dataLength >> 16),
            (uint8_t)(dataLength >> 8), (uint8_t)dataLength};
        status = CMBlockBufferReplaceDataBytes(lengthBytes, existingBuffer,
                                               oldOffset, NAL_LENGTH_PREFIX_SIZE);
        if (status != noErr) {
            Log(LOG_E, @"CMBlockBufferReplaceDataBytes failed: %d", (int)status);
            return;
        }
        
        // Attach the buffer by reference to the block buffer
        status = CMBlockBufferAppendMemoryBlock(existingBuffer, &data[offset+NALU_START_PREFIX_SIZE],
                                                dataLength,
                                                kCFAllocatorNull, // Don't deallocate data on free
                                                NULL, 0, dataLength, 0);
        if (status != noErr) {
            Log(LOG_E, @"CMBlockBufferReplaceDataBytes failed: %d", (int)status);
            return;
        }
    }
}

// This function must free data for bufferType == BUFFER_TYPE_PICDATA
- (int)submitDecodeBuffer:(unsigned char *)data length:(int)length bufferType:(int)bufferType
{
    unsigned char nalType = data[FRAME_START_PREFIX_SIZE];
    OSStatus status;
//    Log(LOG_I, @"nalType: %c", nalType);
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
            if (videoFormat & VIDEO_FORMAT_MASK_H264) {
                [self printStreamInfo];
                
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
                if (@available(iOS 11.0, macOS 10.13, *)) {
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
    CMBlockBufferRef blockBuffer;
    
    status = CMBlockBufferCreateEmpty(NULL, 0, 0, &blockBuffer);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferCreateEmpty failed: %d", (int)status);
        free(data);
        return DR_NEED_IDR;
    }
    
    int lastOffset = -1;
    for (int i = 0; i < length - FRAME_START_PREFIX_SIZE; i++) {
        // Search for a NALU
        if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 1) {
            // It's the start of a new NALU
            if (lastOffset != -1) {
                // We've seen a start before this so enqueue that NALU
                [self updateBufferForRange:blockBuffer data:data offset:lastOffset length:i - lastOffset];
            }
            
            lastOffset = i;
        }
    }
    
    if (lastOffset != -1) {
        // Enqueue the remaining data
        [self updateBufferForRange:blockBuffer data:data offset:lastOffset length:length - lastOffset];
    }
    
    // From now on, CMBlockBuffer owns the data pointer and will free it when it's dereferenced
    
    NSDictionary *frame = @{@"buffer": CFBridgingRelease(blockBuffer), @"nalType": @(nalType)};
    os_unfair_lock_lock(&_frameQueueLock);
    [_frameQueue insertObject:frame atIndex:0];
    os_unfair_lock_unlock(&_frameQueueLock);
    
    return DR_OK;
}

- (void)renderFrameAtVsync:(NSDictionary *)frame {
    CMBlockBufferRef blockBuffer = (CMBlockBufferRef)CFBridgingRetain(frame[@"buffer"]);
    unsigned char nalType = ((NSNumber *)frame[@"nalType"]).unsignedCharValue;
    
    // Queue this sample for the next v-sync
    CMSampleTimingInfo timingInfo = {
        .duration = kCMTimeInvalid,
        .decodeTimeStamp = kCMTimeInvalid,
        .presentationTimeStamp = CMTimeMake(mach_absolute_time(), 1000 * 1000 * 1000)
    };
    
    CMSampleBufferRef sampleBuffer;
    OSStatus status = CMSampleBufferCreate(kCFAllocatorDefault,
                                  blockBuffer,
                                  true, NULL,
                                  NULL, formatDesc, 1, 1,
                                  &timingInfo, 0, NULL,
                                  &sampleBuffer);
    if (status != noErr) {
        Log(LOG_E, @"CMSampleBufferCreate failed: %d", (int)status);
        CFRelease(blockBuffer);
        return;
    }
    
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
    CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
    
    CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    CFDictionarySetValue(dict, kCMSampleAttachmentKey_IsDependedOnByOthers, kCFBooleanTrue);
    
    if (![self isNalReferencePicture:nalType]) {
        // P-frame
//        Log(LOG_I, @"P-frame");
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DependsOnOthers, kCFBooleanTrue);
    } else {
        // I-frame
//        Log(LOG_I, @"I-frame");
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_NotSync, kCFBooleanFalse);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DependsOnOthers, kCFBooleanFalse);
    }
    
    [displayLayer enqueueSampleBuffer:sampleBuffer];
    
    // Dereference the buffers
    CFRelease(blockBuffer);
    CFRelease(sampleBuffer);
}

@end
