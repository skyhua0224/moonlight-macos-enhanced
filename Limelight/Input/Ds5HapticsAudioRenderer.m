#import "Ds5HapticsAudioRenderer.h"

#if TARGET_OS_OSX
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <math.h>

#import "../Utility/Logger.h"

static const UInt32 kDs5EndpointChannels = 4;
static const UInt32 kDs5HapticsChannelOffset = 2;
static const UInt32 kDs5QueueBufferFrames = 480;
static const UInt32 kDs5QueueBufferCount = 32;
static const UInt32 kDs5PrebufferFrames = 720;

static BOOL Ds5GetProperty(AudioObjectID object,
                           AudioObjectPropertySelector selector,
                           AudioObjectPropertyScope scope,
                           void *value,
                           UInt32 valueSize) {
    AudioObjectPropertyAddress address = {
        selector,
        scope,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = valueSize;
    return AudioObjectGetPropertyData(object, &address, 0, NULL, &size, value) == noErr;
}

static NSString *Ds5DeviceName(AudioDeviceID device) {
    CFStringRef name = NULL;
    if (!Ds5GetProperty(device, kAudioObjectPropertyName,
                        kAudioObjectPropertyScopeGlobal, &name, sizeof(name)) || name == NULL) {
        return @"";
    }
    NSString *result = [(__bridge NSString *)name copy];
    CFRelease(name);
    return result;
}

static BOOL Ds5NameLooksLikeController(NSString *name) {
    NSString *lower = name.lowercaseString;
    return [lower containsString:@"dualsense"] ||
           [lower containsString:@"wireless controller"] ||
           [lower containsString:@"hidmaestro"];
}

static UInt32 Ds5OutputChannelCount(AudioDeviceID device) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) != noErr || size == 0) {
        return 0;
    }

    void *storage = calloc(1, size);
    if (storage == NULL) {
        return 0;
    }
    AudioBufferList *list = storage;
    UInt32 result = 0;
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, list) == noErr) {
        for (UInt32 index = 0; index < list->mNumberBuffers; index++) {
            result += list->mBuffers[index].mNumberChannels;
        }
    }
    free(storage);
    return result;
}

static BOOL Ds5EndpointIsAvailable(AudioDeviceID *outDevice, NSString **outName) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr ||
        size == 0) {
        return NO;
    }

    AudioDeviceID *devices = calloc(1, size);
    if (devices == NULL) {
        return NO;
    }
    BOOL found = NO;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices) == noErr) {
        for (UInt32 index = 0; index < size / sizeof(AudioDeviceID); index++) {
            AudioDeviceID device = devices[index];
            NSString *name = Ds5DeviceName(device);
            Float64 sampleRate = 0;
            UInt32 transport = 0;
            if (!Ds5GetProperty(device, kAudioDevicePropertyTransportType,
                               kAudioObjectPropertyScopeGlobal, &transport, sizeof(transport)) ||
                transport != kAudioDeviceTransportTypeUSB || !Ds5NameLooksLikeController(name) ||
                Ds5OutputChannelCount(device) != kDs5EndpointChannels ||
                !Ds5GetProperty(device, kAudioDevicePropertyNominalSampleRate,
                                kAudioObjectPropertyScopeGlobal, &sampleRate, sizeof(sampleRate)) ||
                fabs(sampleRate - 48000.0) > 0.5) {
                continue;
            }
            if (outDevice != NULL) {
                *outDevice = device;
            }
            if (outName != NULL) {
                *outName = name;
            }
            found = YES;
            break;
        }
    }
    free(devices);
    return found;
}

@interface Ds5HapticsAudioRenderer () {
    AudioQueueRef _queue;
    AudioDeviceID _device;
    NSMutableArray<NSValue *> *_freeBuffers;
    NSLock *_lock;
    UInt32 _queuedFrames;
    UInt32 _prebufferedFrames;
    BOOL _started;
    BOOL _streamActive;
    UInt32 _expectedSequence;
}
@end

@implementation Ds5HapticsAudioRenderer

static void Ds5AudioQueueBufferDone(void *userData,
                                    AudioQueueRef queue,
                                    AudioQueueBufferRef buffer) {
    (void)queue;
    Ds5HapticsAudioRenderer *renderer = (__bridge Ds5HapticsAudioRenderer *)userData;
    [renderer bufferDidFinish:buffer];
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _device = kAudioObjectUnknown;
        _freeBuffers = [NSMutableArray arrayWithCapacity:kDs5QueueBufferCount];
        _lock = [[NSLock alloc] init];
    }
    return self;
}

- (void)dealloc {
    [self reset];
    [self closeQueue];
}

- (void)bufferDidFinish:(AudioQueueBufferRef)buffer {
    [_lock lock];
    _queuedFrames -= buffer->mAudioDataByteSize / (kDs5EndpointChannels * sizeof(float));
    [_freeBuffers addObject:[NSValue valueWithPointer:buffer]];
    [_lock unlock];
}

// Read-only capability check; never open an unrelated system audio output.
+ (BOOL)hasPhysicalEndpoint { return Ds5EndpointIsAvailable(NULL, NULL); }

- (BOOL)openIfNeeded {
    if (_queue != NULL) {
        return YES;
    }

    AudioDeviceID device = kAudioObjectUnknown;
    NSString *name = nil;
    if (!Ds5EndpointIsAvailable(&device, &name)) {
        return NO;
    }

    AudioStreamBasicDescription format = {0};
    format.mSampleRate = 48000.0;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mChannelsPerFrame = kDs5EndpointChannels;
    format.mBitsPerChannel = 32;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = kDs5EndpointChannels * sizeof(float);
    format.mBytesPerPacket = format.mBytesPerFrame;

    if (AudioQueueNewOutput(&format, Ds5AudioQueueBufferDone,
                            (__bridge void *)self, NULL, NULL, 0, &_queue) != noErr) {
        _queue = NULL;
        return NO;
    }

    CFStringRef uid = NULL;
    BOOL hasUID = Ds5GetProperty(device, kAudioDevicePropertyDeviceUID,
                                 kAudioObjectPropertyScopeGlobal, &uid, sizeof(uid)) && uid != NULL;
    BOOL selected = hasUID &&
        AudioQueueSetProperty(_queue, kAudioQueueProperty_CurrentDevice,
                              &uid, sizeof(uid)) == noErr;
    if (uid != NULL) {
        CFRelease(uid);
    }
    if (!selected) {
        [self closeQueue];
        return NO;
    }

    for (UInt32 index = 0; index < kDs5QueueBufferCount; index++) {
        AudioQueueBufferRef buffer = NULL;
        if (AudioQueueAllocateBuffer(_queue,
                                     kDs5QueueBufferFrames * kDs5EndpointChannels * sizeof(float),
                                     &buffer) != noErr) {
            [self closeQueue];
            return NO;
        }
        [_freeBuffers addObject:[NSValue valueWithPointer:buffer]];
    }
    _device = device;
    Log(LOG_I, @"[ds5-haptics] Core Audio endpoint ready: %@ (48 kHz, 4-channel float)", name);
    return YES;
}

- (void)closeQueue {
    if (_queue != NULL) {
        AudioQueueDispose(_queue, true);
        _queue = NULL;
    }
    [_freeBuffers removeAllObjects];
    _device = kAudioObjectUnknown;
    _queuedFrames = 0;
    _prebufferedFrames = 0;
    _started = NO;
}

- (void)reset {
    [_lock lock];
    if (_queue != NULL) {
        if (_started) {
            AudioQueuePause(_queue);
        }
        AudioQueueReset(_queue);
    }
    _streamActive = NO;
    _expectedSequence = 0;
    _prebufferedFrames = 0;
    _queuedFrames = 0;
    _started = NO;
    [_lock unlock];
}

- (BOOL)enqueueFrame:(const LI_DS5_HAPTICS_PCM_FRAME *)frame {
    if (![self openIfNeeded] || _queue == NULL) {
        return NO;
    }

    [_lock lock];
    if (_freeBuffers.count == 0 ||
        _queuedFrames + frame->frameCount > 2400 /* 50 ms at 48 kHz */) {
        [_lock unlock];
        return NO;
    }

    NSValue *value = _freeBuffers.lastObject;
    [_freeBuffers removeLastObject];
    AudioQueueBufferRef buffer = value.pointerValue;
    float *samples = buffer->mAudioData;
    memset(samples, 0, frame->frameCount * kDs5EndpointChannels * sizeof(float));
    const int16_t *input = (const int16_t *)frame->pcmData;
    for (UInt16 index = 0; index < frame->frameCount; index++) {
        samples[index * kDs5EndpointChannels + kDs5HapticsChannelOffset] =
            (float)input[index * 2] / 32768.0f;
        samples[index * kDs5EndpointChannels + kDs5HapticsChannelOffset + 1] =
            (float)input[index * 2 + 1] / 32768.0f;
    }
    buffer->mAudioDataByteSize = frame->frameCount * kDs5EndpointChannels * sizeof(float);
    OSStatus status = AudioQueueEnqueueBuffer(_queue, buffer, 0, NULL);
    if (status != noErr) {
        [_freeBuffers addObject:value];
        [_lock unlock];
        [self closeQueue];
        return NO;
    }
    _queuedFrames += frame->frameCount;
    _prebufferedFrames += frame->frameCount;

    if (!_started && (_prebufferedFrames >= kDs5PrebufferFrames || _freeBuffers.count == 0)) {
        status = AudioQueueStart(_queue, NULL);
        if (status != noErr) {
            [_lock unlock];
            [self closeQueue];
            return NO;
        }
        _started = YES;
        _prebufferedFrames = 0;
    }
    [_lock unlock];
    return YES;
}

- (BOOL)submitPCMFrame:(const LI_DS5_HAPTICS_PCM_FRAME *)frame {
    if (frame == NULL || frame->sampleRate != 48000 || frame->channelCount != 2 ||
        frame->bitsPerSample != 16 || frame->frameCount > 480 ||
        frame->pcmDataLength != (UInt32)frame->frameCount * 4 ||
        (frame->pcmDataLength != 0 && frame->pcmData == NULL)) {
        return NO;
    }
    if ((frame->flags & LI_DS5_HAPTICS_PCM_FLAG_STREAM_END) != 0 || frame->frameCount == 0) {
        [self reset];
        return _queue != NULL;
    }

    [_lock lock];
    BOOL discontinuity = !_streamActive ||
        (frame->flags & (LI_DS5_HAPTICS_PCM_FLAG_STREAM_START |
                         LI_DS5_HAPTICS_PCM_FLAG_DISCONTINUITY)) != 0 ||
        (_streamActive && frame->sequenceNumber != _expectedSequence);
    if (discontinuity) {
        if (_queue != NULL) {
            if (_started) {
                AudioQueuePause(_queue);
            }
            AudioQueueReset(_queue);
        }
        _prebufferedFrames = 0;
        _queuedFrames = 0;
        _started = NO;
    }
    _streamActive = YES;
    _expectedSequence = frame->sequenceNumber + 1;
    [_lock unlock];
    return [self enqueueFrame:frame];
}

@end

#else

@implementation Ds5HapticsAudioRenderer
+ (BOOL)hasPhysicalEndpoint { return NO; }
- (BOOL)submitPCMFrame:(const LI_DS5_HAPTICS_PCM_FRAME *)frame { (void)frame; return NO; }
- (void)reset {}
@end

#endif
