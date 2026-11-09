#import "Ds5HapticsAudioRenderer.h"
#import "DS5PadMix.h"
#include "../../core/interaction/ds5-core/include/alkaidlab/ds5_core/ds5_core.h"

#if TARGET_OS_OSX
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <math.h>
#import <stdatomic.h>

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
           [lower containsString:@"wireless controller"];
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

// The endpoint the last lookup found, kAudioObjectUnknown for none. The lookup reads the name of
// every audio device, and CoreAudio makes such a read wait while a device is being opened: ~10 s
// for an HDMI TV whose clock does not start, which is what a stream's audio output start runs
// into. The answer is wanted on the main thread (stream setup, controller arrival) and on the
// control stream thread, so the lookup runs on a queue of its own, at launch and whenever the
// device list changes, and those callers read its last answer.
static _Atomic AudioDeviceID sDs5Endpoint = kAudioObjectUnknown;

static void Ds5RefreshEndpoint(void) {
    AudioDeviceID device = kAudioObjectUnknown;
    if (!Ds5EndpointIsAvailable(&device, NULL)) {
        device = kAudioObjectUnknown;
    }
    atomic_store(&sDs5Endpoint, device);
}

// What macOS does with the pad's output device: a per-channel volume or a mute set on the device would scale or
// silence the queue's samples before the pad sees them.
typedef struct Ds5SavedDeviceState {
    Float32 volume[5];
    UInt32 mute[5];
    uint8_t volumeChanged, muteChanged;  // bit per element
} Ds5SavedDeviceState;

static void Ds5LogDeviceAudioState(AudioDeviceID device, NSString *name, BOOL raiseToUnity, Ds5SavedDeviceState *saved) {
    for (UInt32 element = 0; element <= 4; element++) {
        AudioObjectPropertyAddress volume = {kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element};
        AudioObjectPropertyAddress mute = {kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, element};
        AudioObjectPropertyAddress decibels = {kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyScopeOutput, element};
        const BOOL hasVolume = AudioObjectHasProperty(device, &volume);
        const BOOL hasMute = AudioObjectHasProperty(device, &mute);
        if (!hasVolume && !hasMute) continue;
        Float32 scalar = -1.0f, db = 0.0f;
        UInt32 muted = 0, size = sizeof(scalar);
        Boolean settableVolume = false, settableMute = false;
        if (hasVolume) {
            AudioObjectGetPropertyData(device, &volume, 0, NULL, &size, &scalar);
            AudioObjectIsPropertySettable(device, &volume, &settableVolume);
            size = sizeof(db);
            if (AudioObjectHasProperty(device, &decibels)) AudioObjectGetPropertyData(device, &decibels, 0, NULL, &size, &db);
        }
        if (hasMute) {
            size = sizeof(muted);
            AudioObjectGetPropertyData(device, &mute, 0, NULL, &size, &muted);
            AudioObjectIsPropertySettable(device, &mute, &settableMute);
        }
        Log(LOG_I, @"[ds5-haptics] device %@ element %u: volume=%.3f (%.1f dB, settable=%d) mute=%u (settable=%d)",
            name, (unsigned)element, scalar, db, (int)settableVolume, (unsigned)muted, (int)settableMute);
        if (raiseToUnity) {
            if (hasVolume && settableVolume && scalar >= 0.0f && scalar < 0.999f) {
                Float32 unity = 1.0f;
                if (saved != NULL && element < 5 && !(saved->volumeChanged & (1u << element))) { saved->volume[element] = scalar; saved->volumeChanged |= (uint8_t)(1u << element); }
                const OSStatus status = AudioObjectSetPropertyData(device, &volume, 0, NULL, sizeof(unity), &unity);
                Log(LOG_I, @"[ds5-haptics] device %@ element %u volume raised from %.3f to 1.0 (status %d)", name, (unsigned)element, scalar, (int)status);
            }
            if (hasMute && settableMute && muted != 0) {
                UInt32 off = 0;
                if (saved != NULL && element < 5 && !(saved->muteChanged & (1u << element))) { saved->mute[element] = muted; saved->muteChanged |= (uint8_t)(1u << element); }
                const OSStatus status = AudioObjectSetPropertyData(device, &mute, 0, NULL, sizeof(off), &off);
                Log(LOG_I, @"[ds5-haptics] device %@ element %u unmuted (status %d)", name, (unsigned)element, (int)status);
            }
        }
    }
    AudioObjectPropertyAddress streams = {kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    UInt32 streamsSize = 0;
    if (AudioObjectGetPropertyDataSize(device, &streams, 0, NULL, &streamsSize) == noErr && streamsSize >= sizeof(AudioStreamID)) {
        AudioStreamID streamIDs[8] = {0};
        if (streamsSize > sizeof(streamIDs)) streamsSize = sizeof(streamIDs);
        AudioObjectGetPropertyData(device, &streams, 0, NULL, &streamsSize, streamIDs);
        for (UInt32 index = 0; index < streamsSize / sizeof(AudioStreamID); index++) {
            AudioStreamBasicDescription format = {0};
            UInt32 formatSize = sizeof(format);
            AudioObjectPropertyAddress physical = {kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
            if (AudioObjectGetPropertyData(streamIDs[index], &physical, 0, NULL, &formatSize, &format) == noErr) {
                Log(LOG_I, @"[ds5-haptics] device %@ stream %u physical format: %.0f Hz, %u channels, %u bits, flags=0x%x",
                    name, (unsigned)index, format.mSampleRate, (unsigned)format.mChannelsPerFrame, (unsigned)format.mBitsPerChannel, (unsigned)format.mFormatFlags);
            }
        }
    }
    AudioObjectPropertyAddress layoutAddress = {kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    UInt32 layoutSize = 0;
    if (AudioObjectGetPropertyDataSize(device, &layoutAddress, 0, NULL, &layoutSize) == noErr && layoutSize >= sizeof(AudioChannelLayout)) {
        AudioChannelLayout *layout = calloc(1, layoutSize);
        if (layout != NULL && AudioObjectGetPropertyData(device, &layoutAddress, 0, NULL, &layoutSize, layout) == noErr) {
            NSMutableString *labels = [NSMutableString string];
            if (layout->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions) {
                for (UInt32 index = 0; index < layout->mNumberChannelDescriptions && index < 8; index++) {
                    [labels appendFormat:@" %u", (unsigned)layout->mChannelDescriptions[index].mChannelLabel];
                }
            }
            Log(LOG_I, @"[ds5-haptics] device %@ preferred channel layout tag=0x%x channels=%u labels:%@", name,
                (unsigned)layout->mChannelLayoutTag, (unsigned)(layout->mChannelLayoutTag & 0xffff), labels);
        }
        free(layout);
    }
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
    AlkDs5Core *_core;
    AlkDs5DeviceFacts _facts;
    // The five-second line: what was written to the endpoint, per channel.
    NSString *_deviceName;
    float _peak[4];
    unsigned _framesWritten, _framesRefused, _chunks;
    CFAbsoluteTime _lastLog;
    BOOL _headsetRoute;
    DS5PadMix _mix;
    Ds5SavedDeviceState _saved;
}
@end

@implementation Ds5HapticsAudioRenderer

@synthesize headsetRoute = _headsetRoute;

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
        {
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            _mix = ds5_pad_mix_from_names([defaults stringForKey:@"ds5PadSpeakerMix"].UTF8String, [defaults stringForKey:@"ds5PadHeadsetMix"].UTF8String);
        }
        _freeBuffers = [NSMutableArray arrayWithCapacity:kDs5QueueBufferCount];
        _lock = [[NSLock alloc] init];
        AlkDs5BackendEvidence evidence = {
            .struct_size = sizeof(evidence), .abi = ALK_DS5_CORE_ABI_VERSION,
            .proven_capabilities = ALK_DS5_CAP_AUDIO_PCM | ALK_DS5_CAP_AUDIO_RENDER,
            .audio = {sizeof(AlkDs5AudioFacts), ALK_DS5_CORE_ABI_VERSION, 48000u, 16u, 4u,
                      {1u, 2u, 3u, 4u}, 2400u, 1u, 1u, 0u}};
        AlkDs5Profile profile = {
            .struct_size = sizeof(profile), .abi = ALK_DS5_CORE_ABI_VERSION,
            .vendor_id = 0x054c, .product_id = 0x0ce6,
            .transport = ALK_DS5_TRANSPORT_USB, .max_devices = 1,
            .product_string = "DualSense", .manufacturer = "Sony",
            .backend_evidence = &evidence};
        if (alk_ds5_core_create(&profile, &_core) == ALK_DS5_OK) {
            _facts.struct_size = sizeof(_facts);
            _facts.abi = ALK_DS5_CORE_ABI_VERSION;
            (void)alk_ds5_core_read_facts(_core, &_facts);
            AlkDs5Event event = {.struct_size = sizeof(event), .abi = ALK_DS5_CORE_ABI_VERSION};
            (void)alk_ds5_core_arrive(_core, 0, &event);
        }
    }
    return self;
}

- (void)dealloc {
    [self reset];
    [self closeQueue];
    alk_ds5_core_destroy(_core);
}

- (void)bufferDidFinish:(AudioQueueBufferRef)buffer {
    [_lock lock];
    _queuedFrames -= buffer->mAudioDataByteSize / (kDs5EndpointChannels * sizeof(float));
    [_freeBuffers addObject:[NSValue valueWithPointer:buffer]];
    [_lock unlock];
}

+ (void)startWatchingPhysicalEndpoint {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_t queue = dispatch_queue_create("moonlight.ds5.endpoint",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        dispatch_async(queue, ^{
            AudioObjectPropertyAddress address = {
                kAudioHardwarePropertyDevices,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };
            AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &address, queue,
                                                ^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
                Ds5RefreshEndpoint();
            });
            Ds5RefreshEndpoint();
        });
    });
}

// Read-only capability check; never open an unrelated system audio output.
+ (BOOL)usbPcmRequested {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"ds5UsbPcmHaptics"];
}

+ (BOOL)padSpeakerEnabled {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults objectForKey:@"ds5PadAudioOffer"] == nil ? YES : [defaults boolForKey:@"ds5PadAudioOffer"];
}

+ (BOOL)hasPhysicalEndpoint {
    [self startWatchingPhysicalEndpoint];
    return atomic_load(&sDs5Endpoint) != kAudioObjectUnknown;
}

- (BOOL)openIfNeeded {
    if (_queue != NULL) {
        return YES;
    }

    // The endpoint from the last lookup: looking it up here would wait for any device that is
    // being opened, on the control stream thread (see sDs5Endpoint).
    AudioDeviceID device = atomic_load(&sDs5Endpoint);
    if (device == kAudioObjectUnknown) {
        return NO;
    }
    if (_core == NULL || _facts.audio.sample_rate_hz != 48000u || _facts.audio.channel_count != 4u ||
        _facts.audio.supports_render == 0u || Ds5OutputChannelCount(device) != 4u) {
        return NO;
    }
    Float64 actualRate = 0.0;
    if (!Ds5GetProperty(device, kAudioDevicePropertyNominalSampleRate,
                        kAudioObjectPropertyScopeGlobal, &actualRate, sizeof(actualRate)) ||
        fabs(actualRate - 48000.0) > 0.5) return NO;
    NSString *name = Ds5DeviceName(device);

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
    {
        // The queue's own gain must be unity: it scales every channel, speaker and haptics alike.
        AudioQueueSetParameter(_queue, kAudioQueueParam_Volume, 1.0f);
        AudioQueueParameterValue queueVolume = -1.0f;
        AudioQueueGetParameter(_queue, kAudioQueueParam_Volume, &queueVolume);
        Log(LOG_I, @"[ds5-haptics] Core Audio queue volume parameter reads %.3f", queueVolume);
    }
    _device = device;
    _deviceName = name;
    UInt32 transport = 0;
    (void)Ds5GetProperty(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &transport, sizeof(transport));
    CFStringRef uidForLog = NULL;
    NSString *uidText = Ds5GetProperty(device, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, &uidForLog, sizeof(uidForLog)) && uidForLog != NULL
        ? CFBridgingRelease(uidForLog) : @"?";
    Log(LOG_I, @"[ds5-haptics] Core Audio endpoint ready: %@ (48 kHz, 4-channel float) uid=%@ id=%u outputChannels=%u transport=%c%c%c%c nominalRate=%.0f",
        name, uidText, (unsigned)device, (unsigned)Ds5OutputChannelCount(device),
        (char)(transport >> 24), (char)(transport >> 16), (char)(transport >> 8), (char)transport, actualRate);
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
    (void)alk_ds5_core_clear(_core);
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

// `speaker` is the pad's speaker pair of the same frames (left, right per frame) or NULL: it fills channels 1
// and 2 of the endpoint next to the haptics on 3 and 4, so an application playing to the endpoint sounds on the pad.
- (BOOL)enqueueFrame:(const LI_DS5_HAPTICS_PCM_FRAME *)frame speaker:(const int16_t *)speaker {
    if (![self openIfNeeded] || _queue == NULL) {
        return NO;
    }

    [_lock lock];
    if (_freeBuffers.count == 0 ||
        _queuedFrames + frame->frameCount > 2400 /* 50 ms at 48 kHz */) {
        _framesRefused += frame->frameCount;
        [self logEndpointWindowLocked];
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
        if (speaker != NULL) {
            float channel1 = 0.0f, channel2 = 0.0f;
            ds5_pad_mix_frame(&_mix, _headsetRoute, (float)speaker[index * 2] / 32768.0f, (float)speaker[index * 2 + 1] / 32768.0f, &channel1, &channel2);
            samples[index * kDs5EndpointChannels] = channel1;
            samples[index * kDs5EndpointChannels + 1] = channel2;
        }
    }
    buffer->mAudioDataByteSize = frame->frameCount * kDs5EndpointChannels * sizeof(float);
    for (UInt16 index = 0; index < frame->frameCount; index++) {
        for (UInt32 channel = 0; channel < kDs5EndpointChannels; channel++) {
            const float magnitude = fabsf(samples[index * kDs5EndpointChannels + channel]);
            if (magnitude > _peak[channel]) _peak[channel] = magnitude;
        }
    }
    _framesWritten += frame->frameCount;
    _chunks++;
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
        Log(LOG_I, @"[ds5-haptics] Core Audio queue started on %@ after %u frames", _deviceName, (unsigned)_queuedFrames);
    }
    [self logEndpointWindowLocked];
    [_lock unlock];
    return YES;
}

// Called with _lock held: one line every five seconds while audio is written to the pad.
- (void)logEndpointWindowLocked {
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (_lastLog == 0) _lastLog = now;
    if (now - _lastLog < 5.0 || (_framesWritten == 0 && _framesRefused == 0)) return;
    _lastLog = now;
    Log(LOG_I, @"[ds5-haptics] endpoint %@ 5 s: frames written=%u in %u chunks, refused=%u, queue started=%d queued=%u, peak per channel (1-2 speaker, 3-4 haptics) = %.3f %.3f %.3f %.3f",
        _deviceName, _framesWritten, _chunks, _framesRefused, _started ? 1 : 0, (unsigned)_queuedFrames,
        _peak[0], _peak[1], _peak[2], _peak[3]);
    _framesWritten = _framesRefused = _chunks = 0;
    memset(_peak, 0, sizeof(_peak));
}

- (BOOL)playSpeaker:(const int16_t *)speaker haptics:(const int16_t *)haptics frames:(UInt16)frames {
    if (speaker == NULL || haptics == NULL || frames == 0 || frames > 480) return NO;
    LI_DS5_HAPTICS_PCM_FRAME output = {
        .flags = LI_DS5_HAPTICS_PCM_FLAG_STREAM_START,
        .sampleRate = 48000u, .frameCount = frames,
        .channelCount = 2u, .bitsPerSample = 16u,
        .pcmData = (const uint8_t *)haptics,
        .pcmDataLength = (uint32_t)frames * 4u};
    return [self enqueueFrame:&output speaker:speaker];
}

- (BOOL)prepareDeviceForPadAudio {
    if (![self openIfNeeded] || _device == kAudioObjectUnknown) return NO;
    Ds5LogDeviceAudioState(_device, _deviceName, YES, &_saved);
    return YES;
}

- (void)restoreDeviceState {
    if (_device == kAudioObjectUnknown) return;
    for (UInt32 element = 0; element < 5; element++) {
        if (_saved.volumeChanged & (1u << element)) {
            AudioObjectPropertyAddress volume = {kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element};
            Float32 original = _saved.volume[element];
            const OSStatus status = AudioObjectSetPropertyData(_device, &volume, 0, NULL, sizeof(original), &original);
            Log(LOG_I, @"[ds5-haptics] device %@ element %u volume put back to %.3f (status %d)", _deviceName, (unsigned)element, original, (int)status);
        }
        if (_saved.muteChanged & (1u << element)) {
            AudioObjectPropertyAddress mute = {kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, element};
            UInt32 original = _saved.mute[element];
            AudioObjectSetPropertyData(_device, &mute, 0, NULL, sizeof(original), &original);
        }
    }
    memset(&_saved, 0, sizeof(_saved));
}

- (BOOL)drainCoreAudio:(AlkDs5Core *)core {
    if (core == NULL) return NO;
    BOOL drained = NO;
    for (;;) {
        int16_t samples[480u * 4u] = {0};
        AlkDs5AudioFrame frame = {
            .struct_size = sizeof(frame), .abi = ALK_DS5_CORE_ABI_VERSION,
            .device_index = 0, .sample_rate_hz = 48000u, .bits_per_sample = 16u,
            .channel_count = 4u, .frame_count = 480u, .output_samples = samples};
        AlkDs5Error result = alk_ds5_core_audio_read(core, &frame);
        if (result == ALK_DS5_ERROR_NOT_FOUND) {
            // Speaker audio stops after a chunk of 240 frames: take it rather than leave it for the next sound.
            frame.frame_count = 240u;
            result = alk_ds5_core_audio_read(core, &frame);
            if (result == ALK_DS5_ERROR_NOT_FOUND) break;
        }
        if (result != ALK_DS5_OK) return NO;
        int16_t stereo[480u * 2u] = {0};
        int16_t speaker[480u * 2u] = {0};
        for (uint32_t index = 0; index < frame.frame_count; index++) {
            stereo[index * 2u] = samples[index * 4u + 2u];
            stereo[index * 2u + 1u] = samples[index * 4u + 3u];
            speaker[index * 2u] = samples[index * 4u];
            speaker[index * 2u + 1u] = samples[index * 4u + 1u];
        }
        LI_DS5_HAPTICS_PCM_FRAME output = {
            .flags = LI_DS5_HAPTICS_PCM_FLAG_STREAM_START,
            .sampleRate = 48000u, .frameCount = (uint16_t)frame.frame_count,
            .channelCount = 2u, .bitsPerSample = 16u,
            .pcmData = (const uint8_t *)stereo,
            .pcmDataLength = frame.frame_count * 4u};
        if (! [self enqueueFrame:&output speaker:speaker]) return NO;
        drained = YES;
    }
    return drained;
}

@end

#else

@implementation Ds5HapticsAudioRenderer
+ (void)startWatchingPhysicalEndpoint {}
+ (BOOL)hasPhysicalEndpoint { return NO; }
+ (BOOL)usbPcmRequested { return NO; }
+ (BOOL)padSpeakerEnabled { return NO; }
- (void)restoreDeviceState {}
- (BOOL)drainCoreAudio:(AlkDs5Core *)core { (void)core; return NO; }
- (void)reset {}
@end

#endif
