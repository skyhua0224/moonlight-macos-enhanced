// The Core Haptics half of ds5_pad_tone (--haptics): the pad's two handles played through GameController, as the client's
// HapticContext does, so that they can run next to the audio output of the tone.
#import <Foundation/Foundation.h>
@import CoreHaptics;
@import GameController;

static CHHapticEngine *sEngines[2];
static id<CHHapticPatternPlayer> sPlayers[2];
static BOOL sPlaying[2];

int ds5_haptics_start(void) {
  @autoreleasepool {
    for (int i = 0; i < 20 && GCController.controllers.count == 0; i++) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    GCController *pad = nil;
    for (GCController *c in GCController.controllers) if ([c.vendorName containsString:@"DualSense"] || c.extendedGamepad != nil) { pad = c; break; }
    if (pad == nil || pad.haptics == nil) { printf("haptics: no GameController pad with haptics (%lu controllers)\n", (unsigned long)GCController.controllers.count); return 0; }
    NSArray *localities = @[GCHapticsLocalityLeftHandle, GCHapticsLocalityRightHandle];
    int ok = 0;
    for (int i = 0; i < 2; i++) {
      if (![pad.haptics.supportedLocalities containsObject:localities[i]]) { printf("haptics: locality %d unsupported\n", i); continue; }
      sEngines[i] = [pad.haptics createEngineWithLocality:localities[i]];
      NSError *error = nil;
      if (sEngines[i] == nil || ![sEngines[i] startAndReturnError:&error]) { printf("haptics: engine %d failed: %s\n", i, error.description.UTF8String); sEngines[i] = nil; continue; }
      CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
          parameters:@[[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1],
                       [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5f]]
          relativeTime:0 duration:GCHapticDurationInfinite];
      CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event]
          parameters:@[[[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:0 relativeTime:0]] error:&error];
      sPlayers[i] = pattern != nil ? [sEngines[i] createPlayerWithPattern:pattern error:&error] : nil;
      if (sPlayers[i] == nil) { printf("haptics: player %d failed: %s\n", i, error.description.UTF8String); continue; }
      ok++;
    }
    printf("haptics: %d of 2 handles ready on %s\n", ok, pad.vendorName.UTF8String);
    return ok;
  }
}

void ds5_haptics_set(float intensity) {
  @autoreleasepool {
    for (int i = 0; i < 2; i++) {
      if (sPlayers[i] == nil) continue;
      NSError *error = nil;
      if (![sPlayers[i] sendParameters:@[[[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:intensity relativeTime:0]]
                              atTime:CHHapticTimeImmediate error:&error]) printf("haptics: send failed: %s\n", error.description.UTF8String);
      if (!sPlaying[i] && intensity > 0 && [sPlayers[i] startAtTime:CHHapticTimeImmediate error:&error]) sPlaying[i] = YES;
    }
  }
}

void ds5_haptics_stop(void) {
  for (int i = 0; i < 2; i++) {
    if (sPlayers[i] != nil) [sPlayers[i] cancelAndReturnError:nil];
    if (sEngines[i] != nil) [sEngines[i] stopWithCompletionHandler:nil];
    sPlayers[i] = nil; sEngines[i] = nil; sPlaying[i] = NO;
  }
}
