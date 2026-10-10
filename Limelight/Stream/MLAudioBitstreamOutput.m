//
//  MLAudioBitstreamOutput.m
//  Moonlight for macOS
//
//  The sequence follows what mpv (ao_coreaudio_exclusive), VLC (auhal) and
//  Kodi (AESinkDARWINOSX) do for digital output:
//    hog the device -> disable mixing -> remember and switch the physical format
//    -> wait until the change is visible -> create the IOProc -> start,
//  and the reverse on the way out. Kodi documents that hog mode has to be taken
//  before the non-mixable format is set (the other order can deadlock in the HAL).
//

#import "MLAudioBitstreamOutput.h"
#import "Logger.h"

#include <math.h>
#include <stdatomic.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "MLIEC61937.h"

NSErrorDomain const MLAudioBitstreamErrorDomain = @"MLAudioBitstreamOutputErrorDomain";

// 'cec3' is the IEC 61937 E-AC-3 carrier (4x the base rate, 6144 frames per
// burst). The SDK only names the AC3 one (kAudioFormat60958AC3), so define it.
static const UInt32 kMLAudioFormatIEC61937EAC3 = 0x63656333;

static const double kMLAc3CarrierRate = 48000.0;
static const double kMLEac3CarrierRate = 192000.0;
static const UInt32 kMLAc3CarrierFramesPerBurst = 1536;
static const UInt32 kMLEac3CarrierFramesPerBurst = 6144;

static const NSTimeInterval kMLFormatChangeTimeoutSeconds = 2.0;
static const int64_t kMLFormatChangePollMs = 100;

// Ring of whole bursts. Capacity must be a power of two: the indices are
// free-running 32-bit counters.
#define ML_RING_CAPACITY 8u
// Bursts to collect before the first real burst after start (about 3 x 32 ms
// of jitter absorption) and after an underrun (kept short: every extra burst
// is audio delay, but 1 would ping-pong between pause and data).
#define ML_START_PREFILL 3u
#define ML_RECOVER_PREFILL 2u
// The host and the TV clocks differ by some ppm, so the queue slowly grows.
// Beyond ML_TRIM_ABOVE bursts the device thread drops the oldest down to ML_TRIM_TO.
#define ML_TRIM_ABOVE 5u
#define ML_TRIM_TO 4u

static NSString *const kMLLeftoverDefaultsKey = @"audio.bitstream.leftoverDeviceFormat";

// Instances currently holding a device. restoreLeftoverDeviceFormatIfNeeded
// must not touch a device that is legitimately in an encoded format.
static _Atomic int sActiveInstances = 0;

typedef struct {
    // Allocated once per instance and kept until dealloc, so a producer that
    // races with stop still touches valid memory.
    uint8_t *slots;   // ML_RING_CAPACITY bursts
    uint8_t *pause;   // one pause burst, read-only after start
    uint8_t *scratch; // producer side: where bursts are built when the ring is full
    size_t burstBytes;
    uint32_t streamIndex;
    int codec;

    _Atomic bool active;
    _Atomic uint32_t writeIndex; // producer owned
    _Atomic uint32_t readIndex;  // consumer (IOProc) owned

    // IOProc only.
    const uint8_t *current;
    size_t offset;
    bool holdingSlot;
    bool waitingForPrefill;
    uint32_t prefillTarget;

    _Atomic uint64_t enqueued;
    _Atomic uint64_t played;
    _Atomic uint64_t pauses;
    _Atomic uint64_t dropped;
    _Atomic uint64_t invalid;
    _Atomic int lastInvalidCode;

    // Producer only.
    ml_iec61937_eac3_state eac3;
} MLBitstreamState;

#pragma mark - CoreAudio helpers

static AudioObjectPropertyAddress MLAddress(AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = {selector, scope, kAudioObjectPropertyElementMain};
    return address;
}

static AudioDeviceID MLDefaultOutputDeviceID(void) {
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address = MLAddress(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device) != noErr) {
        return kAudioObjectUnknown;
    }
    return device;
}

static NSString *MLCopyStringProperty(AudioObjectID object, AudioObjectPropertySelector selector) {
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    AudioObjectPropertyAddress address = MLAddress(selector, kAudioObjectPropertyScopeGlobal);
    if (AudioObjectGetPropertyData(object, &address, 0, NULL, &size, &value) != noErr || value == NULL) {
        return nil;
    }
    return CFBridgingRelease(value);
}

static BOOL MLDeviceIsAlive(AudioDeviceID device) {
    UInt32 alive = 1;
    UInt32 size = sizeof(alive);
    AudioObjectPropertyAddress address = MLAddress(kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal);
    OSStatus status = AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &alive);
    // A device that cannot answer is as good as gone.
    return status == noErr && alive != 0;
}

static AudioDeviceID MLDeviceForUID(NSString *uid) {
    CFStringRef cfUid = (__bridge CFStringRef)uid;
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address = MLAddress(kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, sizeof(cfUid), &cfUid, &size, &device) != noErr) {
        return kAudioObjectUnknown;
    }
    return device;
}

static NSArray<NSNumber *> *MLOutputStreams(AudioDeviceID device) {
    AudioObjectPropertyAddress address = MLAddress(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) != noErr || size < sizeof(AudioStreamID)) {
        return @[];
    }
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, data.mutableBytes) != noErr) {
        return @[];
    }
    const AudioStreamID *ids = data.bytes;
    NSMutableArray<NSNumber *> *streams = [NSMutableArray array];
    for (UInt32 i = 0; i < size / sizeof(AudioStreamID); i++) {
        [streams addObject:@(ids[i])];
    }
    return streams;
}

// Copy of the stream's AvailablePhysicalFormats; empty when the query fails.
static NSData *MLAvailablePhysicalFormats(AudioStreamID stream) {
    AudioObjectPropertyAddress address = MLAddress(kAudioStreamPropertyAvailablePhysicalFormats, kAudioObjectPropertyScopeGlobal);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(stream, &address, 0, NULL, &size) != noErr || size < sizeof(AudioStreamRangedDescription)) {
        return [NSData data];
    }
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(stream, &address, 0, NULL, &size, data.mutableBytes) != noErr) {
        return [NSData data];
    }
    data.length = size;
    return data;
}

static BOOL MLGetStreamFormat(AudioStreamID stream, AudioObjectPropertySelector selector, AudioStreamBasicDescription *out) {
    UInt32 size = sizeof(*out);
    AudioObjectPropertyAddress address = MLAddress(selector, kAudioObjectPropertyScopeGlobal);
    return AudioObjectGetPropertyData(stream, &address, 0, NULL, &size, out) == noErr;
}

static BOOL MLCodecIsSupported(int codec) {
    return codec == MLAudioBitstreamCodecAc3 || codec == MLAudioBitstreamCodecEac3;
}

static UInt32 MLCarrierFormatID(int codec) {
    return codec == MLAudioBitstreamCodecEac3 ? kMLAudioFormatIEC61937EAC3 : kAudioFormat60958AC3;
}

static double MLCarrierRate(int codec) {
    return codec == MLAudioBitstreamCodecEac3 ? kMLEac3CarrierRate : kMLAc3CarrierRate;
}

static UInt32 MLCarrierFramesPerBurst(int codec) {
    return codec == MLAudioBitstreamCodecEac3 ? kMLEac3CarrierFramesPerBurst : kMLAc3CarrierFramesPerBurst;
}

static size_t MLBurstBytes(int codec) {
    return codec == MLAudioBitstreamCodecEac3 ? ML_IEC61937_EAC3_BURST_BYTES : ML_IEC61937_AC3_BURST_BYTES;
}

// The encoded format the framer's output is valid for: right carrier id and
// rate, 16-bit stereo, little endian (the framer writes LE words), and a burst
// length equal to the framer's.
static BOOL MLFindEncodedFormat(AudioStreamID stream, int codec, AudioStreamBasicDescription *out) {
    NSData *formats = MLAvailablePhysicalFormats(stream);
    const AudioStreamRangedDescription *list = formats.bytes;
    const NSUInteger count = formats.length / sizeof(AudioStreamRangedDescription);
    const double rate = MLCarrierRate(codec);
    for (NSUInteger i = 0; i < count; i++) {
        const AudioStreamBasicDescription *f = &list[i].mFormat;
        if (f->mFormatID != MLCarrierFormatID(codec)) {
            continue;
        }
        const BOOL rateMatches = (f->mSampleRate == rate) ||
            (f->mSampleRate == 0 && list[i].mSampleRateRange.mMinimum <= rate && rate <= list[i].mSampleRateRange.mMaximum);
        if (!rateMatches || f->mChannelsPerFrame != 2) {
            continue;
        }
        if (f->mBitsPerChannel != 16 || (f->mFormatFlags & kAudioFormatFlagIsBigEndian)) {
            continue;
        }
        if (f->mFramesPerPacket != 0 && f->mFramesPerPacket != MLCarrierFramesPerBurst(codec)) {
            continue;
        }
        if (f->mBytesPerPacket != 0 && f->mBytesPerPacket != MLBurstBytes(codec)) {
            continue;
        }
        *out = *f;
        out->mSampleRate = rate;
        return YES;
    }
    return NO;
}

// Where to put the stream back afterwards. The saved format is normally PCM;
// if the stream was already in an encoded format (a leftover of someone else),
// pick a plain stereo PCM format instead of restoring that.
static BOOL MLPickPCMRestoreFormat(AudioStreamID stream, const AudioStreamBasicDescription *original, AudioStreamBasicDescription *out) {
    if (original->mFormatID == kAudioFormatLinearPCM) {
        *out = *original;
        return YES;
    }
    NSData *formats = MLAvailablePhysicalFormats(stream);
    const AudioStreamRangedDescription *list = formats.bytes;
    const NSUInteger count = formats.length / sizeof(AudioStreamRangedDescription);
    BOOL found = NO;
    for (NSUInteger i = 0; i < count; i++) {
        const AudioStreamBasicDescription *f = &list[i].mFormat;
        if (f->mFormatID != kAudioFormatLinearPCM || f->mChannelsPerFrame != 2 || f->mSampleRate != 48000.0 ||
            f->mBitsPerChannel > 24) {
            continue;
        }
        if (!found || f->mBitsPerChannel > out->mBitsPerChannel) {
            *out = *f;
            found = YES;
        }
    }
    return found;
}

static BOOL MLFormatsMatch(const AudioStreamBasicDescription *a, const AudioStreamBasicDescription *b) {
    return a->mFormatID == b->mFormatID && fabs(a->mSampleRate - b->mSampleRate) < 0.5 &&
           a->mChannelsPerFrame == b->mChannelsPerFrame && a->mBitsPerChannel == b->mBitsPerChannel &&
           a->mFramesPerPacket == b->mFramesPerPacket;
}

static NSString *MLFourCC(UInt32 value) {
    char c[5] = {(char)(value >> 24), (char)(value >> 16), (char)(value >> 8), (char)value, 0};
    for (int i = 0; i < 4; i++) {
        if (c[i] < 32 || c[i] > 126) {
            return [NSString stringWithFormat:@"0x%08X", (unsigned)value];
        }
    }
    return [NSString stringWithUTF8String:c];
}

static NSString *MLDescribeFormat(const AudioStreamBasicDescription *f) {
    return [NSString stringWithFormat:@"%@ %.0f Hz %uch %ubit flags=0x%X bytesPerPacket=%u framesPerPacket=%u",
            MLFourCC(f->mFormatID), f->mSampleRate, (unsigned)f->mChannelsPerFrame, (unsigned)f->mBitsPerChannel,
            (unsigned)f->mFormatFlags, (unsigned)f->mBytesPerPacket, (unsigned)f->mFramesPerPacket];
}

// Sets the physical format and waits (bounded) until the stream reports it.
// Setting is asynchronous and not atomic; some drivers also end up in a broken
// state, in which case the previous format is put back. Must not be called on a
// queue the listener below needs, so it uses a global queue of its own.
static BOOL MLChangePhysicalFormat(AudioStreamID stream, const AudioStreamBasicDescription *target, NSString **failure) {
    AudioStreamBasicDescription previous = {0};
    if (!MLGetStreamFormat(stream, kAudioStreamPropertyPhysicalFormat, &previous)) {
        if (failure) *failure = @"cannot read the current physical format";
        return NO;
    }

    AudioObjectPropertyAddress address = MLAddress(kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal);
    dispatch_semaphore_t changed = dispatch_semaphore_create(0);
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    AudioObjectPropertyListenerBlock listener = ^(UInt32 count, const AudioObjectPropertyAddress addresses[]) {
        dispatch_semaphore_signal(changed);
    };
    OSStatus status = AudioObjectAddPropertyListenerBlock(stream, &address, queue, listener);
    if (status != noErr) {
        if (failure) *failure = [NSString stringWithFormat:@"cannot observe the physical format (status %d)", (int)status];
        return NO;
    }

    BOOL applied = NO;
    AudioStreamBasicDescription desired = *target;
    status = AudioObjectSetPropertyData(stream, &address, 0, NULL, sizeof(desired), &desired);
    if (status != noErr) {
        if (failure) *failure = [NSString stringWithFormat:@"setting the physical format failed (status %d)", (int)status];
    } else {
        const uint64_t deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + (uint64_t)(kMLFormatChangeTimeoutSeconds * NSEC_PER_SEC);
        for (;;) {
            AudioStreamBasicDescription actual = {0};
            if (MLGetStreamFormat(stream, kAudioStreamPropertyPhysicalFormat, &actual) && MLFormatsMatch(&actual, &desired)) {
                applied = YES;
                break;
            }
            // The notification is not always delivered, so poll as well.
            if (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) >= deadline) {
                break;
            }
            dispatch_semaphore_wait(changed, dispatch_time(DISPATCH_TIME_NOW, kMLFormatChangePollMs * NSEC_PER_MSEC));
        }
        if (!applied && failure) {
            *failure = [NSString stringWithFormat:@"the stream did not switch to %@ within %.0f s",
                        MLDescribeFormat(&desired), kMLFormatChangeTimeoutSeconds];
        }
    }

    if (!applied && previous.mFormatID != 0) {
        AudioObjectSetPropertyData(stream, &address, 0, NULL, sizeof(previous), &previous);
    }
    AudioObjectRemovePropertyListenerBlock(stream, &address, queue, listener);
    return applied;
}

#pragma mark - Persisted leftover

static NSDictionary *MLLeftoverRecord(NSString *uid, uint32_t streamIndex, const AudioStreamBasicDescription *f) {
    return @{
        @"uid": uid,
        @"streamIndex": @(streamIndex),
        @"sampleRate": @(f->mSampleRate),
        @"formatID": @(f->mFormatID),
        @"formatFlags": @(f->mFormatFlags),
        @"bytesPerPacket": @(f->mBytesPerPacket),
        @"framesPerPacket": @(f->mFramesPerPacket),
        @"bytesPerFrame": @(f->mBytesPerFrame),
        @"channels": @(f->mChannelsPerFrame),
        @"bits": @(f->mBitsPerChannel),
        @"pid": @(getpid()),
    };
}

static AudioStreamBasicDescription MLFormatFromRecord(NSDictionary *record) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = [record[@"sampleRate"] doubleValue];
    f.mFormatID = [record[@"formatID"] unsignedIntValue];
    f.mFormatFlags = [record[@"formatFlags"] unsignedIntValue];
    f.mBytesPerPacket = [record[@"bytesPerPacket"] unsignedIntValue];
    f.mFramesPerPacket = [record[@"framesPerPacket"] unsignedIntValue];
    f.mBytesPerFrame = [record[@"bytesPerFrame"] unsignedIntValue];
    f.mChannelsPerFrame = [record[@"channels"] unsignedIntValue];
    f.mBitsPerChannel = [record[@"bits"] unsignedIntValue];
    return f;
}

#pragma mark - Real-time side

// Called by CoreAudio on its real-time thread. No locks, no allocation, no ObjC
// messaging, no logging: only the ring indices and memcpy.
static void MLBitstreamSelectNext(MLBitstreamState *s) {
    uint32_t read = atomic_load_explicit(&s->readIndex, memory_order_relaxed);
    if (s->holdingSlot) {
        // The finished burst's slot may be overwritten from now on.
        read++;
        atomic_store_explicit(&s->readIndex, read, memory_order_release);
        s->holdingSlot = false;
    }
    const uint32_t write = atomic_load_explicit(&s->writeIndex, memory_order_acquire);
    uint32_t depth = write - read;

    if (s->waitingForPrefill && depth >= s->prefillTarget) {
        s->waitingForPrefill = false;
    }
    if (!s->waitingForPrefill && depth == 0) {
        s->waitingForPrefill = true;
        s->prefillTarget = ML_RECOVER_PREFILL;
    }

    if (!s->waitingForPrefill) {
        if (depth > ML_TRIM_ABOVE) {
            const uint32_t drop = depth - ML_TRIM_TO;
            read += drop;
            atomic_store_explicit(&s->readIndex, read, memory_order_release);
            atomic_fetch_add_explicit(&s->dropped, drop, memory_order_relaxed);
        }
        s->current = s->slots + (size_t)(read % ML_RING_CAPACITY) * s->burstBytes;
        s->holdingSlot = true;
        atomic_fetch_add_explicit(&s->played, 1, memory_order_relaxed);
    } else {
        s->current = s->pause;
        atomic_fetch_add_explicit(&s->pauses, 1, memory_order_relaxed);
    }
    s->offset = 0;
}

static OSStatus MLBitstreamIOProc(AudioObjectID device,
                                  const AudioTimeStamp *now,
                                  const AudioBufferList *inputData,
                                  const AudioTimeStamp *inputTime,
                                  AudioBufferList *outputData,
                                  const AudioTimeStamp *outputTime,
                                  void *clientData) {
    MLBitstreamState *s = (MLBitstreamState *)clientData;
    if (outputData == NULL) {
        return noErr;
    }
    // Only the buffer of our stream carries the bitstream; any other output
    // stream of the device must stay silent, not stale.
    for (UInt32 i = 0; i < outputData->mNumberBuffers; i++) {
        if (i != s->streamIndex && outputData->mBuffers[i].mData != NULL) {
            memset(outputData->mBuffers[i].mData, 0, outputData->mBuffers[i].mDataByteSize);
        }
    }
    if (s->streamIndex >= outputData->mNumberBuffers) {
        return noErr;
    }
    AudioBuffer *buffer = &outputData->mBuffers[s->streamIndex];
    uint8_t *dst = (uint8_t *)buffer->mData;
    size_t remaining = buffer->mDataByteSize;
    if (dst == NULL) {
        return noErr;
    }

    // The device asks for whatever buffer size it likes, not a multiple of a burst.
    while (remaining > 0) {
        if (s->current == NULL || s->offset >= s->burstBytes) {
            MLBitstreamSelectNext(s);
        }
        size_t chunk = s->burstBytes - s->offset;
        if (chunk > remaining) {
            chunk = remaining;
        }
        memcpy(dst, s->current + s->offset, chunk);
        dst += chunk;
        remaining -= chunk;
        s->offset += chunk;
    }
    return noErr;
}

#pragma mark - Support query

@interface MLAudioBitstreamSupport ()
@property(nonatomic, readwrite) BOOL available;
@property(nonatomic, readwrite) AudioDeviceID deviceID;
@property(nonatomic, readwrite, copy) NSString *deviceName;
@property(nonatomic, readwrite, copy) NSString *deviceUID;
@end

@implementation MLAudioBitstreamSupport
- (NSString *)description {
    return [NSString stringWithFormat:@"<MLAudioBitstreamSupport %@ available=%d>", self.deviceName, self.available];
}
@end

#pragma mark - Output

@implementation MLAudioBitstreamOutput {
    NSLock *_lock;
    dispatch_queue_t _eventQueue;
    MLBitstreamState *_state;

    BOOL _followsDefault;
    AudioDeviceID _deviceID;
    NSString *_deviceName;
    NSString *_deviceUID;
    int _codec;

    // What start did, so that stop (or a failed start) can undo exactly that.
    _Atomic bool _running;  // also read on the event queue
    _Atomic bool _stopping; // ditto
    BOOL _didHog;
    BOOL _didChangeMixing;
    UInt32 _originalMixing;
    AudioStreamID _stream;
    BOOL _didSwitchFormat;
    AudioStreamBasicDescription _encodedFormat;
    AudioStreamBasicDescription _restoreFormat;
    AudioDeviceIOProcID _procID;
    BOOL _deviceStarted;
    BOOL _countedActive;
    NSMutableArray *_listeners;
    _Atomic bool _eventReported;
}

+ (MLAudioBitstreamSupport *)supportForCodec:(int)codec onDevice:(AudioDeviceID)device {
    MLAudioBitstreamSupport *support = [[MLAudioBitstreamSupport alloc] init];
    support.deviceID = device;
    support.deviceName = @"Unknown Output";
    support.deviceUID = @"";
    support.available = NO;
    if (device == kAudioObjectUnknown) {
        return support;
    }
    support.deviceName = MLCopyStringProperty(device, kAudioObjectPropertyName) ?: @"Unknown Output";
    support.deviceUID = MLCopyStringProperty(device, kAudioDevicePropertyDeviceUID) ?: @"";
    if (!MLCodecIsSupported(codec) || !MLDeviceIsAlive(device)) {
        return support;
    }
    for (NSNumber *streamId in MLOutputStreams(device)) {
        AudioStreamBasicDescription format;
        if (MLFindEncodedFormat((AudioStreamID)streamId.unsignedIntValue, codec, &format)) {
            support.available = YES;
            break;
        }
    }
    return support;
}

+ (MLAudioBitstreamSupport *)supportForCodecOnDefaultDevice:(int)codec {
    return [self supportForCodec:codec onDevice:MLDefaultOutputDeviceID()];
}

+ (void)restoreLeftoverDeviceFormatIfNeeded {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *record = [defaults dictionaryForKey:kMLLeftoverDefaultsKey];
    if (record == nil) {
        return;
    }
    if (atomic_load(&sActiveInstances) > 0) {
        return;
    }

    NSString *uid = record[@"uid"];
    const NSUInteger streamIndex = [record[@"streamIndex"] unsignedIntegerValue];
    AudioStreamBasicDescription target = MLFormatFromRecord(record);
    AudioDeviceID device = [uid isKindOfClass:[NSString class]] ? MLDeviceForUID(uid) : kAudioObjectUnknown;
    if (device == kAudioObjectUnknown) {
        // Unplugged devices reset themselves; keep the record in case it is a
        // device that comes back in the state we left it.
        Log(LOG_W, @"[audio] bitstream: leftover format for device %@ is pending but the device is not present", uid ?: @"?");
        return;
    }
    NSArray<NSNumber *> *streams = MLOutputStreams(device);
    if (streamIndex >= streams.count || target.mFormatID != kAudioFormatLinearPCM) {
        [defaults removeObjectForKey:kMLLeftoverDefaultsKey];
        return;
    }

    const AudioStreamID stream = (AudioStreamID)streams[streamIndex].unsignedIntValue;
    AudioStreamBasicDescription current = {0};
    if (MLGetStreamFormat(stream, kAudioStreamPropertyPhysicalFormat, &current) && current.mFormatID == kAudioFormatLinearPCM) {
        // Already PCM (the system or the user changed it); nothing to undo.
        [defaults removeObjectForKey:kMLLeftoverDefaultsKey];
        return;
    }

    NSString *failure = nil;
    if (MLChangePhysicalFormat(stream, &target, &failure)) {
        Log(LOG_I, @"[audio] bitstream: restored %@ to %@ after an earlier session ended without cleanup",
            MLCopyStringProperty(device, kAudioObjectPropertyName) ?: uid, MLDescribeFormat(&target));
        [defaults removeObjectForKey:kMLLeftoverDefaultsKey];
    } else {
        Log(LOG_E, @"[audio] bitstream: could not restore the leftover format of %@: %@", uid, failure ?: @"unknown");
    }
}

- (instancetype)initWithCodec:(int)codec device:(AudioDeviceID)device {
    self = [super init];
    if (self) {
        _codec = codec;
        _followsDefault = (device == kAudioObjectUnknown);
        _deviceID = _followsDefault ? MLDefaultOutputDeviceID() : device;
        _deviceName = MLCopyStringProperty(_deviceID, kAudioObjectPropertyName) ?: @"Unknown Output";
        _deviceUID = MLCopyStringProperty(_deviceID, kAudioDevicePropertyDeviceUID) ?: @"";
        _lock = [[NSLock alloc] init];
        _eventQueue = dispatch_queue_create("com.moonlight.audio.bitstream.events", DISPATCH_QUEUE_SERIAL);
        // Lets removeListeners tell whether it runs inside an event callback.
        dispatch_queue_set_specific(_eventQueue, (__bridge const void *)self, (__bridge void *)self, NULL);
        _listeners = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    [self stop];
    if (_state != NULL) {
        free(_state->slots);
        free(_state->pause);
        free(_state->scratch);
        free(_state);
        _state = NULL;
    }
}

- (int)codec {
    return _codec;
}

- (AudioDeviceID)deviceID {
    return _deviceID;
}

- (NSString *)deviceName {
    return _deviceName;
}

- (BOOL)running {
    return atomic_load(&_running);
}

#pragma mark Start

- (BOOL)failStep:(NSString *)step detail:(NSString *)detail error:(NSError **)error {
    Log(LOG_E, @"[audio] bitstream: start failed at %@ on %@: %@", step, _deviceName, detail);
    if (error != NULL) {
        *error = [NSError errorWithDomain:MLAudioBitstreamErrorDomain code:1
                                 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", step, detail],
                                            @"step": step}];
    }
    [self teardownLocked];
    return NO;
}

- (BOOL)allocateStateIfNeeded {
    if (_state != NULL) {
        return YES;
    }
    MLBitstreamState *state = calloc(1, sizeof(MLBitstreamState));
    if (state == NULL) {
        return NO;
    }
    state->burstBytes = MLBurstBytes(_codec);
    state->slots = calloc(ML_RING_CAPACITY, state->burstBytes);
    state->pause = calloc(1, state->burstBytes);
    state->scratch = calloc(1, state->burstBytes);
    state->codec = _codec;
    if (state->slots == NULL || state->pause == NULL || state->scratch == NULL ||
        ml_iec61937_build_pause(state->pause, state->burstBytes, state->burstBytes, state->burstBytes) != ML_IEC61937_OK) {
        free(state->slots);
        free(state->pause);
        free(state->scratch);
        free(state);
        return NO;
    }
    _state = state;
    return YES;
}

- (BOOL)start:(NSError **)error {
    [_lock lock];
    @try {
        if (atomic_load(&_running)) {
            return YES;
        }
        atomic_store(&_stopping, false);
        atomic_store(&_eventReported, false);

        if (!MLCodecIsSupported(_codec)) {
            return [self failStep:@"codec" detail:@"only AC3 and E-AC3 can be passed through" error:error];
        }
        if (_followsDefault) {
            _deviceID = MLDefaultOutputDeviceID();
            _deviceName = MLCopyStringProperty(_deviceID, kAudioObjectPropertyName) ?: @"Unknown Output";
            _deviceUID = MLCopyStringProperty(_deviceID, kAudioDevicePropertyDeviceUID) ?: @"";
        }
        if (_deviceID == kAudioObjectUnknown || !MLDeviceIsAlive(_deviceID)) {
            return [self failStep:@"device" detail:@"there is no live output device" error:error];
        }
        if (![self allocateStateIfNeeded]) {
            return [self failStep:@"allocation" detail:@"out of memory" error:error];
        }

        // Pick the stream first: it needs nothing changed on the device.
        NSArray<NSNumber *> *streams = MLOutputStreams(_deviceID);
        NSUInteger streamIndex = NSNotFound;
        for (NSUInteger i = 0; i < streams.count; i++) {
            AudioStreamID candidate = (AudioStreamID)streams[i].unsignedIntValue;
            if (MLFindEncodedFormat(candidate, _codec, &_encodedFormat)) {
                _stream = candidate;
                streamIndex = i;
                break;
            }
        }
        if (streamIndex == NSNotFound) {
            return [self failStep:@"stream" detail:@"no output stream offers the encoded format" error:error];
        }
        _state->streamIndex = (uint32_t)streamIndex;

        // Hog mode first: Kodi documents that taking it after the non-mixable
        // format is set can deadlock. Setting it is a toggle, so read it back.
        AudioObjectPropertyAddress hogAddress = MLAddress(kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal);
        pid_t hogPid = -1;
        UInt32 size = sizeof(hogPid);
        if (AudioObjectGetPropertyData(_deviceID, &hogAddress, 0, NULL, &size, &hogPid) == noErr &&
            hogPid != -1 && hogPid != getpid()) {
            return [self failStep:@"hog" detail:[NSString stringWithFormat:@"the device is in exclusive use by process %d", (int)hogPid] error:error];
        }
        pid_t ourPid = getpid();
        OSStatus status = AudioObjectSetPropertyData(_deviceID, &hogAddress, 0, NULL, sizeof(ourPid), &ourPid);
        hogPid = -1;
        size = sizeof(hogPid);
        AudioObjectGetPropertyData(_deviceID, &hogAddress, 0, NULL, &size, &hogPid);
        if (status != noErr || hogPid != getpid()) {
            return [self failStep:@"hog" detail:[NSString stringWithFormat:@"could not take exclusive access (status %d, owner %d)", (int)status, (int)hogPid] error:error];
        }
        _didHog = YES;

        // A mixing device converts to its mixing format, which an encoded stream
        // cannot survive. Not every device has the property; those do not mix.
        AudioObjectPropertyAddress mixAddress = MLAddress(kAudioDevicePropertySupportsMixing, kAudioObjectPropertyScopeGlobal);
        Boolean mixSettable = false;
        if (AudioObjectHasProperty(_deviceID, &mixAddress) &&
            AudioObjectIsPropertySettable(_deviceID, &mixAddress, &mixSettable) == noErr && mixSettable) {
            UInt32 mixing = 1;
            size = sizeof(mixing);
            if (AudioObjectGetPropertyData(_deviceID, &mixAddress, 0, NULL, &size, &mixing) == noErr && mixing != 0) {
                UInt32 off = 0;
                status = AudioObjectSetPropertyData(_deviceID, &mixAddress, 0, NULL, sizeof(off), &off);
                if (status == noErr) {
                    _originalMixing = mixing;
                    _didChangeMixing = YES;
                } else {
                    Log(LOG_W, @"[audio] bitstream: could not disable mixing on %@ (status %d); continuing", _deviceName, (int)status);
                }
            }
        }

        AudioStreamBasicDescription original = {0};
        if (!MLGetStreamFormat(_stream, kAudioStreamPropertyPhysicalFormat, &original)) {
            return [self failStep:@"format-save" detail:@"cannot read the stream's current physical format" error:error];
        }
        if (!MLPickPCMRestoreFormat(_stream, &original, &_restoreFormat)) {
            return [self failStep:@"format-save" detail:[NSString stringWithFormat:@"the stream is in %@ and offers no stereo PCM to return to", MLDescribeFormat(&original)] error:error];
        }
        // Persist before touching the format: a crash from here on must be recoverable.
        [[NSUserDefaults standardUserDefaults] setObject:MLLeftoverRecord(_deviceUID, (uint32_t)streamIndex, &_restoreFormat)
                                                  forKey:kMLLeftoverDefaultsKey];

        NSString *failure = nil;
        _didSwitchFormat = YES; // even a failed attempt may leave the driver half way
        if (!MLChangePhysicalFormat(_stream, &_encodedFormat, &failure)) {
            return [self failStep:@"format-switch" detail:failure ?: @"unknown" error:error];
        }

        // The IOProc's buffer is in the stream's virtual format. It has to be the
        // same encoded format or 16-bit little-endian stereo, or the bytes would be converted.
        AudioStreamBasicDescription virtualFormat = {0};
        if (!MLGetStreamFormat(_stream, kAudioStreamPropertyVirtualFormat, &virtualFormat)) {
            return [self failStep:@"virtual-format" detail:@"cannot read the stream's virtual format" error:error];
        }
        const BOOL virtualIsEncoded = virtualFormat.mFormatID == _encodedFormat.mFormatID;
        const BOOL virtualIsRawPcm16 = virtualFormat.mFormatID == kAudioFormatLinearPCM && virtualFormat.mChannelsPerFrame == 2 &&
            virtualFormat.mBitsPerChannel == 16 && !(virtualFormat.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian));
        if (!virtualIsEncoded && !virtualIsRawPcm16) {
            return [self failStep:@"virtual-format" detail:[NSString stringWithFormat:@"the virtual format %@ would convert the bitstream", MLDescribeFormat(&virtualFormat)] error:error];
        }
        Log(LOG_I, @"[audio] bitstream: %@ physical=%@ virtual=%@ stream=%lu/%lu",
            _deviceName, MLDescribeFormat(&_encodedFormat), MLDescribeFormat(&virtualFormat),
            (unsigned long)streamIndex, (unsigned long)streams.count);

        // Fresh ring and counters.
        MLBitstreamState *s = _state;
        atomic_store(&s->active, false);
        atomic_store(&s->writeIndex, 0);
        atomic_store(&s->readIndex, 0);
        s->current = NULL;
        s->offset = 0;
        s->holdingSlot = false;
        s->waitingForPrefill = true;
        s->prefillTarget = ML_START_PREFILL;
        atomic_store(&s->enqueued, 0);
        atomic_store(&s->played, 0);
        atomic_store(&s->pauses, 0);
        atomic_store(&s->dropped, 0);
        atomic_store(&s->invalid, 0);
        atomic_store(&s->lastInvalidCode, ML_IEC61937_OK);
        ml_iec61937_eac3_reset(&s->eac3);

        status = AudioDeviceCreateIOProcID(_deviceID, MLBitstreamIOProc, s, &_procID);
        if (status != noErr || _procID == NULL) {
            _procID = NULL;
            return [self failStep:@"ioproc" detail:[NSString stringWithFormat:@"AudioDeviceCreateIOProcID status %d", (int)status] error:error];
        }
        status = AudioDeviceStart(_deviceID, _procID);
        if (status != noErr) {
            return [self failStep:@"device-start" detail:[NSString stringWithFormat:@"AudioDeviceStart status %d", (int)status] error:error];
        }
        _deviceStarted = YES;
        atomic_store(&s->active, true);
        atomic_fetch_add(&sActiveInstances, 1);
        _countedActive = YES;
        atomic_store(&_running, true);

        [self installListeners];
        return YES;
    } @finally {
        [_lock unlock];
    }
}

#pragma mark Stop

- (void)stop {
    [_lock lock];
    [self teardownLocked];
    [_lock unlock];
}

// Undoes whatever start did. Safe on a never-started instance and idempotent.
// Never waits for the event queue, so it may run on it.
- (void)teardownLocked {
    atomic_store(&_stopping, true);
    if (_state != NULL) {
        atomic_store(&_state->active, false);
    }
    [self removeListeners];

    if (_deviceStarted) {
        OSStatus status = AudioDeviceStop(_deviceID, _procID);
        if (status != noErr) {
            Log(LOG_W, @"[audio] bitstream: AudioDeviceStop on %@ returned %d", _deviceName, (int)status);
        }
        _deviceStarted = NO;
    }
    if (_procID != NULL) {
        OSStatus status = AudioDeviceDestroyIOProcID(_deviceID, _procID);
        if (status != noErr) {
            Log(LOG_W, @"[audio] bitstream: AudioDeviceDestroyIOProcID on %@ returned %d", _deviceName, (int)status);
        }
        _procID = NULL;
    }

    if (_didSwitchFormat) {
        if (!MLDeviceIsAlive(_deviceID)) {
            // Nothing left to restore; a returning device starts from its own defaults.
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:kMLLeftoverDefaultsKey];
        } else {
            NSString *failure = nil;
            if (MLChangePhysicalFormat(_stream, &_restoreFormat, &failure)) {
                [[NSUserDefaults standardUserDefaults] removeObjectForKey:kMLLeftoverDefaultsKey];
            } else {
                // The persisted record stays so the next launch or stream retries.
                Log(LOG_E, @"[audio] bitstream: could not restore the device format of %@: %@", _deviceName, failure ?: @"unknown");
            }
        }
        _didSwitchFormat = NO;
    }
    if (_didChangeMixing) {
        AudioObjectPropertyAddress mixAddress = MLAddress(kAudioDevicePropertySupportsMixing, kAudioObjectPropertyScopeGlobal);
        UInt32 mixing = _originalMixing;
        AudioObjectSetPropertyData(_deviceID, &mixAddress, 0, NULL, sizeof(mixing), &mixing);
        _didChangeMixing = NO;
    }
    if (_didHog) {
        AudioObjectPropertyAddress hogAddress = MLAddress(kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal);
        pid_t nobody = -1;
        OSStatus status = AudioObjectSetPropertyData(_deviceID, &hogAddress, 0, NULL, sizeof(nobody), &nobody);
        if (status != noErr) {
            Log(LOG_W, @"[audio] bitstream: releasing exclusive access to %@ returned %d", _deviceName, (int)status);
        }
        _didHog = NO;
    }
    if (_countedActive) {
        atomic_fetch_sub(&sActiveInstances, 1);
        _countedActive = NO;
    }
    _stream = 0;
    atomic_store(&_running, false);
}

#pragma mark Events

- (void)addListenerOn:(AudioObjectID)object selector:(AudioObjectPropertySelector)selector {
    AudioObjectPropertyAddress address = MLAddress(selector, kAudioObjectPropertyScopeGlobal);
    __weak MLAudioBitstreamOutput *weakSelf = self;
    AudioObjectPropertyListenerBlock block = ^(UInt32 count, const AudioObjectPropertyAddress addresses[]) {
        [weakSelf propertyChanged:selector];
    };
    // Blocks run on our own serial queue: never on a real-time thread, and
    // never on the thread that is inside start or stop.
    OSStatus status = AudioObjectAddPropertyListenerBlock(object, &address, _eventQueue, block);
    if (status != noErr) {
        Log(LOG_W, @"[audio] bitstream: cannot observe property %@ (status %d)", MLFourCC(selector), (int)status);
        return;
    }
    [_listeners addObject:@[@(object), @(selector), block]];
}

- (void)installListeners {
    [self addListenerOn:_deviceID selector:kAudioDevicePropertyDeviceIsAlive];
    [self addListenerOn:_deviceID selector:kAudioDevicePropertyHogMode];
    [self addListenerOn:_stream selector:kAudioStreamPropertyPhysicalFormat];
    [self addListenerOn:kAudioObjectSystemObject selector:kAudioHardwarePropertyDefaultOutputDevice];
}

- (void)removeListeners {
    NSArray *listeners = [_listeners copy];
    [_listeners removeAllObjects];
    if (listeners.count == 0) {
        return;
    }
    dispatch_queue_t queue = _eventQueue;
    void (^remove)(void) = ^{
        for (NSArray *entry in listeners) {
            AudioObjectPropertyAddress address = MLAddress([entry[1] unsignedIntValue], kAudioObjectPropertyScopeGlobal);
            AudioObjectRemovePropertyListenerBlock((AudioObjectID)[entry[0] unsignedIntValue], &address, queue, entry[2]);
        }
    };
    // Removing a listener may wait for a callback that is still running. If we
    // are that callback (the handler called stop), waiting would never end.
    if (dispatch_get_specific((__bridge const void *)self) != NULL) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), remove);
    } else {
        remove();
    }
}

- (void)propertyChanged:(AudioObjectPropertySelector)selector {
    if (atomic_load(&_stopping) || !atomic_load(&_running) || atomic_load(&_eventReported)) {
        return;
    }
    MLAudioBitstreamEvent event = 0;
    NSString *detail = nil;
    if (selector == kAudioDevicePropertyDeviceIsAlive) {
        if (!MLDeviceIsAlive(_deviceID)) {
            event = MLAudioBitstreamEventDeviceLost;
            detail = @"the output device is gone";
        }
    } else if (selector == kAudioDevicePropertyHogMode) {
        pid_t pid = -1;
        UInt32 size = sizeof(pid);
        AudioObjectPropertyAddress address = MLAddress(kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal);
        if (AudioObjectGetPropertyData(_deviceID, &address, 0, NULL, &size, &pid) == noErr && pid != getpid()) {
            event = MLAudioBitstreamEventHogLost;
            detail = [NSString stringWithFormat:@"exclusive access moved to process %d", (int)pid];
        }
    } else if (selector == kAudioStreamPropertyPhysicalFormat) {
        AudioStreamBasicDescription current = {0};
        if (!MLGetStreamFormat(_stream, kAudioStreamPropertyPhysicalFormat, &current) || !MLFormatsMatch(&current, &_encodedFormat)) {
            event = MLAudioBitstreamEventFormatChanged;
            detail = [NSString stringWithFormat:@"the stream format changed to %@", MLDescribeFormat(&current)];
        }
    } else if (selector == kAudioHardwarePropertyDefaultOutputDevice) {
        if (MLDefaultOutputDeviceID() != _deviceID) {
            event = MLAudioBitstreamEventDefaultDeviceChanged;
            detail = @"the default output device changed";
        }
    }
    if (event == 0) {
        return;
    }
    bool expected = false;
    if (!atomic_compare_exchange_strong(&_eventReported, &expected, true)) {
        return;
    }
    Log(LOG_W, @"[audio] bitstream: %@ on %@", detail, _deviceName);
    void (^handler)(MLAudioBitstreamEvent, NSString *) = self.eventHandler;
    if (handler != nil) {
        handler(event, detail);
    }
}

#pragma mark Producer

- (BOOL)enqueueFrame:(const void *)frame length:(size_t)length {
    MLBitstreamState *s = _state;
    if (s == NULL || !atomic_load_explicit(&s->active, memory_order_acquire)) {
        return NO;
    }
    const uint32_t write = atomic_load_explicit(&s->writeIndex, memory_order_relaxed);
    const uint32_t read = atomic_load_explicit(&s->readIndex, memory_order_acquire);
    const BOOL full = (write - read) >= ML_RING_CAPACITY;
    // When full the burst is still built, so an E-AC3 group does not lose a
    // frame in the middle; it is only not published.
    uint8_t *dst = full ? s->scratch : s->slots + (size_t)(write % ML_RING_CAPACITY) * s->burstBytes;

    size_t burstLength = 0;
    int status;
    if (s->codec == MLAudioBitstreamCodecEac3) {
        status = ml_iec61937_eac3_push(&s->eac3, (const uint8_t *)frame, length, dst, s->burstBytes, &burstLength);
    } else {
        status = ml_iec61937_build_ac3_burst((const uint8_t *)frame, length, dst, s->burstBytes, &burstLength);
    }
    if (status != ML_IEC61937_OK) {
        atomic_fetch_add_explicit(&s->invalid, 1, memory_order_relaxed);
        atomic_store_explicit(&s->lastInvalidCode, status, memory_order_relaxed);
        return NO;
    }
    if (burstLength == 0) {
        return YES; // part of an E-AC3 group
    }
    if (full) {
        // The ring only fills up while the device is not consuming; the device
        // side trims the oldest bursts once it runs again, so the ring is never
        // modified from two threads.
        atomic_fetch_add_explicit(&s->dropped, 1, memory_order_relaxed);
        return YES;
    }
    atomic_store_explicit(&s->writeIndex, write + 1, memory_order_release);
    atomic_fetch_add_explicit(&s->enqueued, 1, memory_order_relaxed);
    return YES;
}

- (MLAudioBitstreamStats)stats {
    MLAudioBitstreamStats stats = {0};
    MLBitstreamState *s = _state;
    if (s == NULL) {
        return stats;
    }
    stats.burstsEnqueued = atomic_load_explicit(&s->enqueued, memory_order_relaxed);
    stats.burstsPlayed = atomic_load_explicit(&s->played, memory_order_relaxed);
    stats.pauseBursts = atomic_load_explicit(&s->pauses, memory_order_relaxed);
    stats.droppedBursts = atomic_load_explicit(&s->dropped, memory_order_relaxed);
    stats.invalidFrames = atomic_load_explicit(&s->invalid, memory_order_relaxed);
    const uint32_t write = atomic_load_explicit(&s->writeIndex, memory_order_acquire);
    const uint32_t read = atomic_load_explicit(&s->readIndex, memory_order_acquire);
    stats.queuedBursts = write - read;
    return stats;
}

- (NSString *)lastInvalidReason {
    MLBitstreamState *s = _state;
    if (s == NULL) {
        return @"";
    }
    return [NSString stringWithUTF8String:ml_iec61937_strerror(atomic_load_explicit(&s->lastInvalidCode, memory_order_relaxed))];
}

@end
