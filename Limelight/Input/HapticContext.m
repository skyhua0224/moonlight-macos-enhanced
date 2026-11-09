// HapticContext is the GPL application's Game Controller integration.
// Original interface: Copyright (c) 2020 Moonlight Stream.
// Reimplemented engine lifecycle uses Apple's public API contracts:
// https://developer.apple.com/documentation/gamecontroller/gcdevicehaptics
// https://developer.apple.com/documentation/corehaptics/chhapticengine
// This file is not a license-cleared private Platform module.
// Native controller actuators, using GCDeviceHaptics supportedLocalities.
#import "HapticContext.h"
#import <math.h>
@import CoreHaptics;
@import GameController;

@implementation HapticContext {
    GCControllerPlayerIndex _playerIndex;
    CHHapticEngine *_hapticEngine;
    id<CHHapticPatternPlayer> _hapticPlayer;
    BOOL _playing;
    BOOL _needsRestart;
    BOOL _closed;
    // The continuous event is not stopped between two ticks: stopping and starting it for each tick puts the
    // player's start latency in front of every short tick. Intensity zero is sent as the dynamic parameter and
    // the player stops only after kIdleStopSeconds without a nonzero value.
    NSUInteger _idleGeneration;
}

static const NSTimeInterval kIdleStopSeconds = 3.0;

- (BOOL)available {
    @synchronized(self) { return !_closed && _hapticEngine != nil; }
}

- (void)cleanup {
    @synchronized(self) {
        _closed = YES;
        _hapticEngine.stoppedHandler = nil;
        _hapticEngine.resetHandler = nil;
        [_hapticPlayer cancelAndReturnError:nil];
        [_hapticEngine stopWithCompletionHandler:nil];
        _hapticPlayer = nil;
        _hapticEngine = nil;
        _playing = NO;
    }
}

- (void)setMotorAmplitude:(unsigned short)amplitude {
    [self setIntensity:amplitude / 65535.0f sharpness:0.5f];
}

- (BOOL)setIntensity:(float)intensity sharpness:(float)sharpness {
    @synchronized(self) {
        if (_closed || _hapticEngine == nil || !isfinite(intensity) || !isfinite(sharpness)) return NO;
        NSError *error = nil;
        if (intensity <= 0) {
            if (!_playing || _hapticPlayer == nil) {
                _playing = NO;
                return YES;
            }
            // Park the running player at zero, and stop it once nothing came for a while.
            [_hapticPlayer sendParameters:@[[[CHHapticDynamicParameter alloc]
                initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:0 relativeTime:0]]
                atTime:CHHapticTimeImmediate error:&error];
            if (error != nil) {
                Log(LOG_W, @"[controller-haptics] Park failed player=%ld: %@", (long)_playerIndex, error);
                [_hapticPlayer cancelAndReturnError:nil];
                _hapticPlayer = nil;
                _playing = NO;
                return NO;
            }
            const NSUInteger generation = ++_idleGeneration;
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kIdleStopSeconds * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                HapticContext *me = weakSelf;
                if (me == nil) return;
                @synchronized(me) {
                    if (me->_idleGeneration != generation || me->_closed || !me->_playing) return;
                    [me->_hapticPlayer stopAtTime:CHHapticTimeImmediate error:nil];
                    me->_playing = NO;
                }
            });
            return YES;
        }
        _idleGeneration++;
        if (_needsRestart) {
            if (![_hapticEngine startAndReturnError:&error]) {
                Log(LOG_W, @"[controller-haptics] Restart failed player=%ld: %@", (long)_playerIndex, error);
                return NO;
            }
            _needsRestart = NO;
        }
        if (_hapticPlayer == nil) {
            CHHapticEvent *event = [[CHHapticEvent alloc]
                initWithEventType:CHHapticEventTypeHapticContinuous
                parameters:@[
                    [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1],
                    [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5f]]
                relativeTime:0 duration:GCHapticDurationInfinite];
            CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event]
                parameters:@[[[CHHapticDynamicParameter alloc]
                    initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:0 relativeTime:0]] error:&error];
            if (pattern != nil) _hapticPlayer = [_hapticEngine createPlayerWithPattern:pattern error:&error];
            if (_hapticPlayer == nil) {
                Log(LOG_W, @"[controller-haptics] Player creation failed player=%ld: %@", (long)_playerIndex, error);
                return NO;
            }
        }
        NSArray *parameters = @[
            [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl
                value:fminf(1, fmaxf(0, intensity)) relativeTime:0],
            [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl
                value:fminf(1, fmaxf(0, sharpness)) - 0.5f relativeTime:0]];
        if (![_hapticPlayer sendParameters:parameters atTime:CHHapticTimeImmediate error:&error] ||
            (!_playing && ![_hapticPlayer startAtTime:CHHapticTimeImmediate error:&error])) {
            Log(LOG_W, @"[controller-haptics] Output failed player=%ld: %@", (long)_playerIndex, error);
            [_hapticPlayer cancelAndReturnError:nil];
            _hapticPlayer = nil;
            _playing = NO;
            _needsRestart = YES;
            return NO;
        }
        _playing = YES;
        return YES;
    }
}

- (id)initWithGamepad:(GCController *)gamepad locality:(GCHapticsLocality)locality {
    self = [super init];
    if (!self) return nil;
    GCDeviceHaptics *haptics = gamepad.haptics;
    if (![haptics.supportedLocalities containsObject:locality]) {
        Log(LOG_W, @"[controller-haptics] Unsupported locality=%@ player=%ld available=%@",
            locality, (long)gamepad.playerIndex, haptics.supportedLocalities);
        return nil;
    }
    _playerIndex = gamepad.playerIndex;
    _hapticEngine = [haptics createEngineWithLocality:locality];
    _hapticEngine.playsHapticsOnly = YES;
    NSError *error = nil;
    if (_hapticEngine == nil || ![_hapticEngine startAndReturnError:&error]) {
        Log(LOG_W, @"[controller-haptics] Engine unavailable player=%ld locality=%@: %@",
            (long)_playerIndex, locality, error);
        return nil;
    }
    __weak typeof(self) weakSelf = self;
    _hapticEngine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
        HapticContext *me = weakSelf;
        if (!me) return;
        @synchronized(me) {
            me->_needsRestart = YES;
            me->_hapticPlayer = nil;
            me->_playing = NO;
        }
        Log(LOG_I, @"[controller-haptics] Engine stopped player=%ld reason=%ld", (long)me->_playerIndex, (long)reason);
    };
    _hapticEngine.resetHandler = ^{
        HapticContext *me = weakSelf;
        if (!me) return;
        @synchronized(me) {
            me->_needsRestart = YES;
            me->_hapticPlayer = nil;
            me->_playing = NO;
        }
    };
    Log(LOG_I, @"[controller-haptics] Native actuator ready player=%ld locality=%@", (long)_playerIndex, locality);
    return self;
}

+ (HapticContext *)createContextForHighFreqMotor:(GCController *)gamepad {
    return [[self alloc] initWithGamepad:gamepad locality:GCHapticsLocalityRightHandle];
}
+ (HapticContext *)createContextForLowFreqMotor:(GCController *)gamepad {
    return [[self alloc] initWithGamepad:gamepad locality:GCHapticsLocalityLeftHandle];
}
#if TARGET_OS_IPHONE
+ (HapticContext *)createContext {
    HapticContext *context = [[self alloc] init];
    context->_hapticEngine = [[CHHapticEngine alloc] initAndReturnError:nil];
    context->_needsRestart = YES;
    return context;
}
#endif
@end
