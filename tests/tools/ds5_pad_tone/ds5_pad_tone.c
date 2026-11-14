// ds5_pad_tone: a plain multichannel CoreAudio output to one device (the DualSense's four-channel USB audio device), to
// compare with what the client's renderer (Ds5HapticsAudioRenderer.m) does. It prints the device's formats, channel layout,
// per-channel volume and mute, and plays a test tone on one channel at a time (the order of a system speaker test: 1, 2, 3,
// 4) and then on all channels, through one of four paths:
//
//   queue         AudioQueue, float32 interleaved packed, no channel layout, 480-frame buffers, started after 720 frames:
//                 what the renderer does.
//   queue-layout  the same with the device's channel layout set on the queue.
//   ioproc        the HAL IOProc of the device in the device's own virtual format.
//   auhal         AUHAL (kAudioUnitSubType_HALOutput) bound to the device: what Audio MIDI Setup and most players use.
//
// Usage:
//   ds5_pad_tone --list
//   ds5_pad_tone --describe [--device NAME]
//   ds5_pad_tone --play --api queue|queue-layout|ioproc|auhal [--device NAME] [--volume keep|unity] [--step SECONDS]
//                [--hz 440] [--amp 0.25] --listener-present [--force]
//   --route speaker|headset  before playing, sends the ordinary USB output report 0x02 to the pad over IOHID that selects the
//                            output path (flag0 0x20+0x80, plus 0x10 for the headset; path 0x30 speaker / 0x00 headset in byte 8;
//                            speaker volume 0x64 in byte 6; headset volume 0x58 in byte 5; pre-amp 2 in byte 38 with flag1 0x80 for
//                            the speaker), repeats it once a second while playing (in case gamecontrollerd overwrites it) and
//                            writes the headset path back at exit. USB only: a Bluetooth pad is refused. Nothing else is set:
//                            no rumble, lights or triggers. Report ids 0x32 to 0x35 are never sent.
//   --map-test               interactive: announces each channel, waits for Enter, plays that channel alone, asks where it was heard
//                            (with --route: the speaker or the headset) and prints which device channel goes where, with the defaults
//                            keys that correct the client's mixdown (ds5PadSpeakerMix, ds5PadHeadsetMix). Use with --api auhal.
//   --haptics                also plays the pad's two Core Haptics handles (a short buzz at the start of every step), through
//                            GameController, to see that the audio output and Core Haptics run together.
// Plays nothing unless --listener-present is given, and refuses while MoonlightEnhanced is running.
// Build: clang -O1 -Wall -o ds5_pad_tone ds5_pad_tone.c -framework CoreAudio -framework AudioToolbox -framework AudioUnit -framework CoreFoundation -framework IOKit
//        plus ds5_pad_haptics.m: clang -fobjc-arc -c ds5_pad_haptics.m, linked with -framework GameController -framework CoreHaptics -framework Foundation

#include <AudioToolbox/AudioToolbox.h>
#include <AudioUnit/AudioUnit.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDManager.h>
#include <pthread.h>
#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_CH 8

typedef struct {
  double rate;
  UInt32 channels;
  double hz, amp, stepSeconds, gapSeconds;
  _Atomic uint64_t frame;
  uint64_t totalFrames;
  int stepCount;
} Gen;

static Gen g;
static int gOnly = -1;   // --map-test: the one channel (0-based) that plays in step 0

static int stepAt(uint64_t frame, int *within) {
  const uint64_t stepFrames = (uint64_t)(g.stepSeconds * g.rate), gapFrames = (uint64_t)(g.gapSeconds * g.rate);
  const uint64_t slot = stepFrames + gapFrames;
  const int step = (int)(frame / slot);
  *within = (frame % slot) < stepFrames;
  return step;
}

// Fills interleaved float frames. Steps 0..channels-1: that channel alone; step channels: all channels; then silence.
static void fillInterleaved(float *out, UInt32 frames, UInt32 channels) {
  uint64_t frame = atomic_load(&g.frame);
  for (UInt32 i = 0; i < frames; i++, frame++) {
    int within = 0;
    const int step = stepAt(frame, &within);
    const float v = within ? (float)(g.amp * sin(2.0 * M_PI * g.hz * (double)frame / g.rate)) : 0.0f;
    for (UInt32 c = 0; c < channels; c++) {
      const bool on = gOnly >= 0 ? (step == 0 && (UInt32)gOnly == c) : (step < (int)g.channels ? (UInt32)step == c : (step == (int)g.channels));
      out[i * channels + c] = on ? v : 0.0f;
    }
  }
  atomic_store(&g.frame, frame);
}

static void fourcc(UInt32 v, char out[5]) { out[0] = (char)(v >> 24); out[1] = (char)(v >> 16); out[2] = (char)(v >> 8); out[3] = (char)v; out[4] = 0; }

static bool getData(AudioObjectID o, AudioObjectPropertySelector s, AudioObjectPropertyScope sc, UInt32 el, void *data, UInt32 size) {
  AudioObjectPropertyAddress a = {s, sc, el};
  return AudioObjectGetPropertyData(o, &a, 0, NULL, &size, data) == noErr;
}

static UInt32 outputChannels(AudioObjectID device) {
  AudioObjectPropertyAddress a = {kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput, 0};
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(device, &a, 0, NULL, &size) != noErr || size == 0) return 0;
  AudioBufferList *list = calloc(1, size);
  UInt32 total = 0;
  if (AudioObjectGetPropertyData(device, &a, 0, NULL, &size, list) == noErr)
    for (UInt32 i = 0; i < list->mNumberBuffers; i++) total += list->mBuffers[i].mNumberChannels;
  free(list);
  return total;
}

static void cfToC(CFStringRef s, char *out, size_t n) {
  out[0] = 0;
  if (s != NULL) { CFStringGetCString(s, out, (CFIndex)n, kCFStringEncodingUTF8); CFRelease(s); }
}

static void deviceName(AudioObjectID d, char *out, size_t n) {
  CFStringRef s = NULL;
  getData(d, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, 0, &s, sizeof(s));
  cfToC(s, out, n);
}
static void deviceUID(AudioObjectID d, char *out, size_t n) {
  CFStringRef s = NULL;
  getData(d, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, 0, &s, sizeof(s));
  cfToC(s, out, n);
}

static AudioObjectID *allDevices(UInt32 *count) {
  AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  *count = 0;
  if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size) != noErr || size == 0) return NULL;
  AudioObjectID *ids = calloc(1, size);
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, ids) != noErr) { free(ids); return NULL; }
  *count = size / sizeof(AudioObjectID);
  return ids;
}

static void listDevices(void) {
  UInt32 n = 0;
  AudioObjectID *ids = allDevices(&n);
  for (UInt32 i = 0; i < n; i++) {
    const UInt32 ch = outputChannels(ids[i]);
    if (ch == 0) continue;
    char name[256], uid[256], t[5];
    UInt32 transport = 0;
    Float64 rate = 0;
    deviceName(ids[i], name, sizeof name);
    deviceUID(ids[i], uid, sizeof uid);
    getData(ids[i], kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, 0, &transport, sizeof(transport));
    getData(ids[i], kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0, &rate, sizeof(rate));
    fourcc(transport, t);
    printf("id=%u output-channels=%u rate=%.0f transport=%s name=\"%s\" uid=%s\n", ids[i], ch, rate, t, name, uid);
  }
  free(ids);
}

static AudioObjectID findDevice(const char *needle) {
  UInt32 n = 0;
  AudioObjectID *ids = allDevices(&n), found = kAudioObjectUnknown;
  for (UInt32 i = 0; i < n && found == kAudioObjectUnknown; i++) {
    char name[256];
    if (outputChannels(ids[i]) < 2) continue;
    deviceName(ids[i], name, sizeof name);
    if (strstr(name, needle) != NULL) found = ids[i];
  }
  free(ids);
  return found;
}

static void printFormat(const char *label, const AudioStreamBasicDescription *f) {
  char id[5];
  fourcc(f->mFormatID, id);
  printf("    %s: %.0f Hz, %u ch, %u bits, id=%s flags=0x%x (%s%s%s%s) bytes/frame=%u\n", label, f->mSampleRate,
         (unsigned)f->mChannelsPerFrame, (unsigned)f->mBitsPerChannel, id, (unsigned)f->mFormatFlags,
         (f->mFormatFlags & kAudioFormatFlagIsFloat) ? "float " : "int ", (f->mFormatFlags & kAudioFormatFlagIsSignedInteger) ? "signed " : "",
         (f->mFormatFlags & kAudioFormatFlagIsPacked) ? "packed " : "", (f->mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? "non-interleaved" : "interleaved",
         (unsigned)f->mBytesPerFrame);
}

static void describe(AudioObjectID d) {
  char name[256], uid[256], t[5];
  UInt32 transport = 0, bufferFrames = 0, latency = 0, safety = 0, running = 0;
  pid_t hog = -1;
  Float64 rate = 0;
  deviceName(d, name, sizeof name);
  deviceUID(d, uid, sizeof uid);
  getData(d, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, 0, &transport, sizeof(transport));
  getData(d, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0, &rate, sizeof(rate));
  getData(d, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, 0, &bufferFrames, sizeof(bufferFrames));
  getData(d, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, 0, &latency, sizeof(latency));
  getData(d, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, 0, &safety, sizeof(safety));
  getData(d, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, 0, &running, sizeof(running));
  getData(d, kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal, 0, &hog, sizeof(hog));
  fourcc(transport, t);
  printf("device id=%u name=\"%s\" uid=%s transport=%s output-channels=%u rate=%.0f\n", d, name, uid, t, outputChannels(d), rate);
  printf("  buffer frames=%u latency=%u safety-offset=%u running-somewhere=%u hog-pid=%d\n", bufferFrames, latency, safety, running, (int)hog);
  AudioObjectPropertyAddress br = {kAudioDevicePropertyBufferFrameSizeRange, kAudioObjectPropertyScopeGlobal, 0};
  AudioValueRange range = {0, 0};
  UInt32 rs = sizeof(range);
  if (AudioObjectGetPropertyData(d, &br, 0, NULL, &rs, &range) == noErr) printf("  buffer frame range %.0f..%.0f\n", range.mMinimum, range.mMaximum);
  for (UInt32 el = 0; el <= outputChannels(d); el++) {
    Float32 vol = -1, db = 0;
    UInt32 mute = 0;
    AudioObjectPropertyAddress va = {kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, el};
    AudioObjectPropertyAddress ma = {kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, el};
    AudioObjectPropertyAddress da = {kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyScopeOutput, el};
    Boolean settable = false;
    if (AudioObjectHasProperty(d, &va)) {
      getData(d, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, el, &vol, sizeof(vol));
      AudioObjectIsPropertySettable(d, &va, &settable);
      if (AudioObjectHasProperty(d, &da)) getData(d, kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyScopeOutput, el, &db, sizeof(db));
      printf("  element %u: volume=%.3f (%.1f dB, settable=%d)\n", el, vol, db, (int)settable);
    }
    if (AudioObjectHasProperty(d, &ma)) {
      getData(d, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, el, &mute, sizeof(mute));
      printf("  element %u: mute=%u\n", el, mute);
    }
  }
  AudioObjectPropertyAddress sa = {kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, 0};
  UInt32 ssize = 0;
  if (AudioObjectGetPropertyDataSize(d, &sa, 0, NULL, &ssize) == noErr) {
    AudioStreamID streams[8] = {0};
    if (ssize > sizeof(streams)) ssize = sizeof(streams);
    AudioObjectGetPropertyData(d, &sa, 0, NULL, &ssize, streams);
    for (UInt32 i = 0; i < ssize / sizeof(AudioStreamID); i++) {
      AudioStreamBasicDescription f;
      UInt32 start = 0;
      printf("  stream %u (id %u):\n", i, streams[i]);
      getData(streams[i], kAudioStreamPropertyStartingChannel, kAudioObjectPropertyScopeGlobal, 0, &start, sizeof(start));
      if (getData(streams[i], kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, 0, &f, sizeof(f))) printFormat("virtual ", &f);
      if (getData(streams[i], kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, 0, &f, sizeof(f))) printFormat("physical", &f);
      printf("    starting channel %u\n", start);
      AudioObjectPropertyAddress av = {kAudioStreamPropertyAvailableVirtualFormats, kAudioObjectPropertyScopeGlobal, 0};
      UInt32 asz = 0;
      if (AudioObjectGetPropertyDataSize(streams[i], &av, 0, NULL, &asz) == noErr && asz > 0) {
        AudioStreamRangedDescription *rd = calloc(1, asz);
        if (AudioObjectGetPropertyData(streams[i], &av, 0, NULL, &asz, rd) == noErr)
          for (UInt32 k = 0; k < asz / sizeof(*rd) && k < 8; k++) printFormat("available virtual", &rd[k].mFormat);
        free(rd);
      }
    }
  }
  AudioObjectPropertyAddress la = {kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeOutput, 0};
  UInt32 lsz = 0;
  if (AudioObjectGetPropertyDataSize(d, &la, 0, NULL, &lsz) == noErr && lsz >= sizeof(AudioChannelLayout)) {
    AudioChannelLayout *layout = calloc(1, lsz);
    if (AudioObjectGetPropertyData(d, &la, 0, NULL, &lsz, layout) == noErr) {
      printf("  preferred channel layout: tag=0x%x bitmap=0x%x descriptions=%u\n", (unsigned)layout->mChannelLayoutTag, (unsigned)layout->mChannelBitmap, (unsigned)layout->mNumberChannelDescriptions);
      for (UInt32 i = 0; layout->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions && i < layout->mNumberChannelDescriptions && i < 8; i++)
        printf("    channel %u label=%u\n", i + 1, (unsigned)layout->mChannelDescriptions[i].mChannelLabel);
    }
    free(layout);
  }
  for (UInt32 el = 1; el <= outputChannels(d) && el <= MAX_CH; el++) {
    CFStringRef s = NULL;
    char text[128];
    if (getData(d, kAudioObjectPropertyElementName, kAudioObjectPropertyScopeOutput, el, &s, sizeof(s))) {
      cfToC(s, text, sizeof text);
      printf("  element %u name \"%s\"\n", el, text);
    }
  }
}

// ---- the four paths -------------------------------------------------------------------------------------------------

static AudioObjectID gDevice;
static UInt32 gChannels;

static void queueCallback(void *user, AudioQueueRef q, AudioQueueBufferRef b) {
  (void)user;
  const UInt32 frames = 480;
  fillInterleaved((float *)b->mAudioData, frames, gChannels);
  b->mAudioDataByteSize = frames * gChannels * (UInt32)sizeof(float);
  AudioQueueEnqueueBuffer(q, b, 0, NULL);
}

static OSStatus runQueue(bool withLayout) {
  AudioStreamBasicDescription f = {0};
  f.mSampleRate = g.rate;
  f.mFormatID = kAudioFormatLinearPCM;
  f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
  f.mChannelsPerFrame = gChannels;
  f.mBitsPerChannel = 32;
  f.mFramesPerPacket = 1;
  f.mBytesPerFrame = gChannels * 4;
  f.mBytesPerPacket = f.mBytesPerFrame;
  AudioQueueRef q = NULL;
  OSStatus st = AudioQueueNewOutput(&f, queueCallback, NULL, NULL, NULL, 0, &q);
  if (st != noErr) return st;
  char uidText[256];
  deviceUID(gDevice, uidText, sizeof uidText);
  CFStringRef uid = CFStringCreateWithCString(NULL, uidText, kCFStringEncodingUTF8);
  st = AudioQueueSetProperty(q, kAudioQueueProperty_CurrentDevice, &uid, sizeof(uid));
  CFRelease(uid);
  if (st != noErr) return st;
  if (withLayout) {
    AudioChannelLayout layout = {0};
    layout.mChannelLayoutTag = gChannels == 4 ? kAudioChannelLayoutTag_Quadraphonic : kAudioChannelLayoutTag_DiscreteInOrder | gChannels;
    st = AudioQueueSetProperty(q, kAudioQueueProperty_ChannelLayout, &layout, sizeof(layout));
    printf("queue channel layout tag 0x%x set: status %d\n", (unsigned)layout.mChannelLayoutTag, (int)st);
  }
  AudioQueueSetParameter(q, kAudioQueueParam_Volume, 1.0f);
  for (int i = 0; i < 3; i++) {
    AudioQueueBufferRef b = NULL;
    if (AudioQueueAllocateBuffer(q, 480 * gChannels * 4, &b) != noErr) break;
    queueCallback(NULL, q, b);   // 1440 frames queued, then started (the renderer starts after 720 and keeps up to 2400)
  }
  st = AudioQueueStart(q, NULL);
  if (st != noErr) return st;
  while (atomic_load(&g.frame) < g.totalFrames) usleep(20000);
  AudioQueueStop(q, true);
  AudioQueueDispose(q, true);
  return noErr;
}

static OSStatus ioProc(AudioObjectID dev, const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *it,
                       AudioBufferList *out, const AudioTimeStamp *ot, void *user) {
  (void)dev; (void)now; (void)in; (void)it; (void)ot; (void)user;
  for (UInt32 b = 0; b < out->mNumberBuffers; b++) {
    AudioBuffer *buf = &out->mBuffers[b];
    const UInt32 ch = buf->mNumberChannels;
    const UInt32 frames = buf->mDataByteSize / (ch * (UInt32)sizeof(float));
    fillInterleaved((float *)buf->mData, frames, ch);
  }
  return noErr;
}

static OSStatus runIOProc(void) {
  AudioDeviceIOProcID proc = NULL;
  OSStatus st = AudioDeviceCreateIOProcID(gDevice, ioProc, NULL, &proc);
  if (st != noErr) return st;
  st = AudioDeviceStart(gDevice, proc);
  if (st != noErr) return st;
  while (atomic_load(&g.frame) < g.totalFrames) usleep(20000);
  AudioDeviceStop(gDevice, proc);
  AudioDeviceDestroyIOProcID(gDevice, proc);
  return noErr;
}

static OSStatus auRender(void *user, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus, UInt32 frames, AudioBufferList *data) {
  (void)user; (void)flags; (void)ts; (void)bus;
  fillInterleaved((float *)data->mBuffers[0].mData, frames, gChannels);
  return noErr;
}

static OSStatus runAUHAL(void) {
  AudioComponentDescription desc = {kAudioUnitType_Output, kAudioUnitSubType_HALOutput, kAudioUnitManufacturer_Apple, 0, 0};
  AudioComponent comp = AudioComponentFindNext(NULL, &desc);
  AudioUnit unit = NULL;
  OSStatus st = AudioComponentInstanceNew(comp, &unit);
  if (st != noErr) return st;
  st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &gDevice, sizeof(gDevice));
  if (st != noErr) return st;
  AudioStreamBasicDescription f = {0};
  f.mSampleRate = g.rate;
  f.mFormatID = kAudioFormatLinearPCM;
  f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
  f.mChannelsPerFrame = gChannels;
  f.mBitsPerChannel = 32;
  f.mFramesPerPacket = 1;
  f.mBytesPerFrame = gChannels * 4;
  f.mBytesPerPacket = f.mBytesPerFrame;
  st = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof(f));
  if (st != noErr) return st;
  AURenderCallbackStruct cb = {auRender, NULL};
  st = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof(cb));
  if (st != noErr) return st;
  st = AudioUnitInitialize(unit);
  if (st != noErr) return st;
  st = AudioOutputUnitStart(unit);
  if (st != noErr) return st;
  while (atomic_load(&g.frame) < g.totalFrames) usleep(20000);
  AudioOutputUnitStop(unit);
  AudioUnitUninitialize(unit);
  AudioComponentInstanceDispose(unit);
  return noErr;
}

extern int ds5_haptics_start(void);
extern void ds5_haptics_set(float intensity);
extern void ds5_haptics_stop(void);
static bool gHaptics = false;

// ---- the output path report over IOHID (USB only) ---------------------------------------------------------------------

static IOHIDDeviceRef gPad = NULL;
static const char *gRoute = NULL;

static bool padOpenUSB(void) {
  IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
  int vid = 0x054c, pid = 0x0ce6;
  CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &vid), p = CFNumberCreate(NULL, kCFNumberIntType, &pid);
  const void *keys[2] = {CFSTR(kIOHIDVendorIDKey), CFSTR(kIOHIDProductIDKey)}, *values[2] = {v, p};
  CFDictionaryRef match = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  IOHIDManagerSetDeviceMatching(manager, match);
  IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
  CFSetRef set = IOHIDManagerCopyDevices(manager);
  bool sawBluetooth = false;
  if (set != NULL) {
    CFIndex n = CFSetGetCount(set);
    const void **devs = calloc((size_t)n, sizeof(void *));
    CFSetGetValues(set, devs);
    for (CFIndex i = 0; i < n && gPad == NULL; i++) {
      IOHIDDeviceRef d = (IOHIDDeviceRef)devs[i];
      char transport[32] = "";
      CFTypeRef t = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDTransportKey));
      if (t != NULL && CFGetTypeID(t) == CFStringGetTypeID()) CFStringGetCString(t, transport, sizeof transport, kCFStringEncodingUTF8);
      int page = 0, usage = 0;
      CFTypeRef up = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDPrimaryUsagePageKey)), uu = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDPrimaryUsageKey));
      if (up != NULL) CFNumberGetValue(up, kCFNumberIntType, &page);
      if (uu != NULL) CFNumberGetValue(uu, kCFNumberIntType, &usage);
      printf("hid device: transport=%s usage page %d usage %d\n", transport, page, usage);
      if (strcmp(transport, "USB") != 0) { sawBluetooth = true; continue; }
      if (page == 1 && usage == 5) gPad = (IOHIDDeviceRef)CFRetain(d);
    }
    free(devs);
    CFRelease(set);
  }
  if (gPad == NULL) {
    fprintf(stderr, sawBluetooth ? "the pad is on Bluetooth only: refusing, this tool writes the path report over USB only\n" : "no DualSense HID device found\n");
    return false;
  }
  IOReturn r = IOHIDDeviceOpen(gPad, kIOHIDOptionsTypeNone);
  if (r != kIOReturnSuccess) { fprintf(stderr, "IOHIDDeviceOpen failed: 0x%x\n", r); return false; }
  return true;
}

static bool writeRoute(const char *route, bool restore) {
  uint8_t report[48] = {0};
  report[0] = 0x02;   // the ordinary USB output report; the valid flags below say which fields count, the rest is ignored
  if (restore) {
    report[1] = 0x80;  report[2] = 0x80;  report[8] = 0x00;  report[38] = 0;
  } else if (!strcmp(route, "speaker")) {
    report[1] = 0x20 | 0x80;  report[2] = 0x80;  report[6] = 0x64;  report[8] = 0x30;  report[38] = 2;
  } else {
    report[1] = 0x10 | 0x20 | 0x80;  report[2] = 0x80;  report[5] = 0x58;  report[6] = 0x64;  report[8] = 0x00;  report[38] = 0;
  }
  IOReturn r = IOHIDDeviceSetReport(gPad, kIOHIDReportTypeOutput, report[0], report, sizeof(report));
  if (r != kIOReturnSuccess) { fprintf(stderr, "route write failed: 0x%x\n", r); return false; }
  return true;
}

static void *routeRepeater(void *unused) {
  (void)unused;
  unsigned writes = 0;
  while (atomic_load(&g.frame) < g.totalFrames) {
    for (int i = 0; i < 50 && atomic_load(&g.frame) < g.totalFrames; i++) usleep(20000);
    if (atomic_load(&g.frame) < g.totalFrames && writeRoute(gRoute, false)) writes++;
  }
  printf("route %s rewritten %u times during playback\n", gRoute, writes);
  return NULL;
}

static void *reporter(void *unused) {
  (void)unused;
  int last = -1;
  while (atomic_load(&g.frame) < g.totalFrames) {
    int within = 0;
    const int step = stepAt(atomic_load(&g.frame), &within);
    if (step != last && within && step <= (int)g.channels) {
      last = step;
      if (step < (int)g.channels) printf("[step %d] tone on channel %d only\n", step + 1, step + 1);
      else printf("[step %d] tone on all %u channels\n", step + 1, (unsigned)g.channels);
      fflush(stdout);
      if (gHaptics) { ds5_haptics_set(0.8f); usleep(300000); ds5_haptics_set(0.0f); }
    }
    usleep(20000);
  }
  return NULL;
}

typedef struct { int channel; char answer; } MapAnswer;

static OSStatus playOnce(const char *api) {
  atomic_store(&g.frame, 0);
  if (!strcmp(api, "queue")) return runQueue(false);
  if (!strcmp(api, "queue-layout")) return runQueue(true);
  if (!strcmp(api, "ioproc")) return runIOProc();
  return runAUHAL();
}

static int readAnswer(const char *prompt, const char *allowed) {
  for (;;) {
    printf("%s", prompt);
    fflush(stdout);
    char line[64];
    if (fgets(line, sizeof line, stdin) == NULL) return 0;
    for (const char *c = line; *c; c++) if (*c != ' ' && *c != '\t' && *c != '\n' && strchr(allowed, *c) != NULL) return *c;
    printf("  please answer with one of: %s\n", allowed);
  }
}

static int runMapTest(const char *api, bool headsetRoute) {
  MapAnswer answers[MAX_CH];
  g.stepSeconds = 1.5;
  g.gapSeconds = 0.3;
  g.totalFrames = (uint64_t)((g.stepSeconds + g.gapSeconds) * g.rate);
  printf("\nMAPPING TEST on the %s route, %u channels. Each channel is played alone for %.1f s.\n", headsetRoute ? "headset" : "speaker", gChannels, g.stepSeconds);
  for (UInt32 ch = 0; ch < gChannels; ch++) {
    printf("\n=== STEP %u of %u: the next tone is on channel %u ONLY (device element %u). ===\n", ch + 1, gChannels, ch + 1, ch + 1);
    printf("Press Enter, then listen.");
    fflush(stdout);
    char line[16];
    if (fgets(line, sizeof line, stdin) == NULL) return 1;
    gOnly = (int)ch;
    OSStatus st = playOnce(api);
    printf("(tone on channel %u finished, status %d)\n", ch + 1, (int)st);
    answers[ch].channel = (int)ch + 1;
    char prompt[256];
    snprintf(prompt, sizeof prompt, headsetRoute ?
        "Where did you hear channel %u? l = left ear, r = right ear, b = both ears, a = actuators/vibration only, n = nothing, ? = not sure: " :
        "Where did you hear channel %u? s = pad speaker, a = actuators/vibration only, n = nothing, ? = not sure: ", ch + 1);
    answers[ch].answer = (char)readAnswer(prompt, headsetRoute ? "lrban?" : "san?");
  }
  gOnly = -1;
  printf("\n=== RESULT (route %s) ===\n", headsetRoute ? "headset" : "speaker");
  for (UInt32 ch = 0; ch < gChannels; ch++) printf("  channel %u -> %c\n", ch + 1, answers[ch].answer);
  if (!headsetRoute) {
    const bool c1 = answers[0].answer == 's', c2 = gChannels > 1 && answers[1].answer == 's';
    if (c1 && c2) printf("  the speaker plays both channels: the default mix (ds5PadSpeakerMix both) is right, or ch1/ch2 would also do\n");
    else if (c1) printf("  the speaker plays channel 1 only: defaults write std.skyhua.MoonlightMacEnhanced ds5PadSpeakerMix ch1 (the default 'both' also works)\n");
    else if (c2) printf("  the speaker plays channel 2 only: defaults write std.skyhua.MoonlightMacEnhanced ds5PadSpeakerMix ch2 (the default 'both' also works)\n");
    else printf("  the speaker played neither channel: the route report did not take effect, or the volume is down\n");
  } else {
    const char a = answers[0].answer, b = gChannels > 1 ? answers[1].answer : '?';
    if (a == 'l' && b == 'r') printf("  stereo as is: ds5PadHeadsetMix stereo (the default)\n");
    else if (a == 'r' && b == 'l') printf("  swapped: defaults write std.skyhua.MoonlightMacEnhanced ds5PadHeadsetMix swap\n");
    else if ((a == 'b' || a == 'l' || a == 'r') && (b == 'n' || b == 'a')) printf("  only channel 1 reaches the headset: defaults write std.skyhua.MoonlightMacEnhanced ds5PadHeadsetMix mono\n");
    else if (a == 'b' && b == 'b') printf("  both channels play in both ears: ds5PadHeadsetMix mono is the closest\n");
    else printf("  no clear stereo mapping: keep the default and look at the answers above\n");
  }
  return 0;
}

int main(int argc, char **argv) {
  const char *needle = "DualSense", *api = "queue", *volume = "keep";
  bool list = false, doDescribe = false, play = false, listener = false, force = false, mapTest = false;
  g.hz = 440; g.amp = 0.25; g.stepSeconds = 1.2; g.gapSeconds = 0.5; g.rate = 48000;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--list")) list = true;
    else if (!strcmp(argv[i], "--describe")) doDescribe = true;
    else if (!strcmp(argv[i], "--play")) play = true;
    else if (!strcmp(argv[i], "--listener-present")) listener = true;
    else if (!strcmp(argv[i], "--force")) force = true;
    else if (!strcmp(argv[i], "--route") && i + 1 < argc) gRoute = argv[++i];
    else if (!strcmp(argv[i], "--haptics")) gHaptics = true;
    else if (!strcmp(argv[i], "--map-test")) mapTest = true;
    else if (!strcmp(argv[i], "--device") && i + 1 < argc) needle = argv[++i];
    else if (!strcmp(argv[i], "--api") && i + 1 < argc) api = argv[++i];
    else if (!strcmp(argv[i], "--volume") && i + 1 < argc) volume = argv[++i];
    else if (!strcmp(argv[i], "--step") && i + 1 < argc) g.stepSeconds = atof(argv[++i]);
    else if (!strcmp(argv[i], "--hz") && i + 1 < argc) g.hz = atof(argv[++i]);
    else if (!strcmp(argv[i], "--amp") && i + 1 < argc) g.amp = atof(argv[++i]);
    else { fprintf(stderr, "unknown argument %s\n", argv[i]); return 2; }
  }
  if (list) { listDevices(); return 0; }
  gDevice = findDevice(needle);
  if (gDevice == kAudioObjectUnknown) { fprintf(stderr, "no output device with \"%s\" in its name and 2+ output channels\n", needle); return 1; }
  if (mapTest) play = true;
  if (doDescribe || !play) { describe(gDevice); if (!play) return 0; }
  if (!listener) { fprintf(stderr, "refusing to play without --listener-present (someone must be there to listen)\n"); return 3; }
  if (!force && system("pgrep -q MoonlightEnhanced") == 0) { fprintf(stderr, "MoonlightEnhanced is running: refusing, so that no stream shares the device\n"); return 4; }
  gChannels = outputChannels(gDevice);
  if (gChannels > MAX_CH) gChannels = MAX_CH;
  g.channels = gChannels;
  g.stepCount = (int)gChannels + 1;
  g.totalFrames = (uint64_t)((g.stepSeconds + g.gapSeconds) * g.rate * (g.stepCount + 1));
  // The volume: keep what macOS has, or raise to unity for the run and restore afterwards.
  Float32 saved = -1;
  AudioObjectPropertyAddress va = {kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, 0};
  if (!strcmp(volume, "unity") && AudioObjectHasProperty(gDevice, &va)) {
    getData(gDevice, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, 0, &saved, sizeof(saved));
    Float32 one = 1.0f;
    AudioObjectSetPropertyData(gDevice, &va, 0, NULL, sizeof(one), &one);
    printf("device volume %.3f raised to 1.0 for the run\n", saved);
  }
  if (gRoute != NULL) {
    if (strcmp(gRoute, "speaker") != 0 && strcmp(gRoute, "headset") != 0) { fprintf(stderr, "--route is speaker or headset\n"); return 2; }
    if (!padOpenUSB()) return 1;
    if (!writeRoute(gRoute, false)) return 1;
    printf("output path report sent over USB: route %s\n", gRoute);
    usleep(300000);
  }
  if (mapTest) {
    if (gHaptics && ds5_haptics_start() == 0) gHaptics = false;
    int rc = runMapTest(api, gRoute != NULL && !strcmp(gRoute, "headset"));
    if (gRoute != NULL && writeRoute(gRoute, true)) printf("output path report written back (headset path, pre-amp 0 dB)\n");
    if (gHaptics) ds5_haptics_stop();
    if (saved >= 0) { AudioObjectSetPropertyData(gDevice, &va, 0, NULL, sizeof(saved), &saved); printf("device volume restored to %.3f\n", saved); }
    return rc;
  }
  if (gHaptics && ds5_haptics_start() == 0) gHaptics = false;
  printf("playing through the %s path to device %u, %u channels at %.0f Hz\n", api, gDevice, gChannels, g.rate);
  pthread_t thread, repeater;
  pthread_create(&thread, NULL, reporter, NULL);
  if (gRoute != NULL) pthread_create(&repeater, NULL, routeRepeater, NULL);
  OSStatus st = noErr;
  if (!strcmp(api, "queue")) st = runQueue(false);
  else if (!strcmp(api, "queue-layout")) st = runQueue(true);
  else if (!strcmp(api, "ioproc")) st = runIOProc();
  else if (!strcmp(api, "auhal")) st = runAUHAL();
  else { fprintf(stderr, "unknown --api %s\n", api); st = -1; }
  atomic_store(&g.frame, g.totalFrames);
  pthread_join(thread, NULL);
  if (gRoute != NULL) {
    pthread_join(repeater, NULL);
    if (writeRoute(gRoute, true)) printf("output path report written back (headset path, pre-amp 0 dB)\n");
  }
  if (gHaptics) ds5_haptics_stop();
  if (saved >= 0) { AudioObjectSetPropertyData(gDevice, &va, 0, NULL, sizeof(saved), &saved); printf("device volume restored to %.3f\n", saved); }
  printf("%s path finished, status %d\n", api, (int)st);
  return st == noErr ? 0 : 1;
}
