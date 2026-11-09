#import "Ds5BluetoothAudioRenderer.h"

#import "DS5BluetoothPcm.h"
#import "DS5RawHIDBridge.h"
#import "Limelight-internal.h"

#include <string.h>

typedef struct Ds5BluetoothAudioState {
    DS5BtStream stream;
    uint8_t hapticCounter;
} Ds5BluetoothAudioState;

@interface Ds5BluetoothAudioRenderer () {
    __weak DS5RawHIDBridge *_bridge;
    Ds5BluetoothAudioState _states[16];
}
@end

@implementation Ds5BluetoothAudioRenderer

- (instancetype)initWithBridge:(DS5RawHIDBridge *)bridge {
    self = [super init];
    if (self != nil) {
        _bridge = bridge;
    }
    return self;
}

- (void)dealloc {
    [self reset];
}

- (BOOL)sendHaptics:(const DS5BtPeriod *)period
                 state:(Ds5BluetoothAudioState *)state
        playerIdentity:(NSString *)identity {
    DS5RawHIDBridge *bridge = _bridge;
    uint8_t report[DS5_BT_REPORT_0x32_BYTES];
    if (period->kind != DS5_BT_PERIOD_HAPTICS) return NO;
    ds5_bt_pack_0x32(report, state->hapticCounter, period->haptics);
    state->hapticCounter++;
    return bridge != nil && [bridge sendBluetoothAudioReport:report
                                                       length:DS5_BT_REPORT_0x32_BYTES
                                              playerIdentity:identity];
}

- (BOOL)enqueueSpeaker:(const int16_t *)speaker
               haptics:(const int16_t *)haptics
                frames:(UInt16)frames
       playerIdentity:(NSString *)identity
         headsetRoute:(BOOL)headsetRoute
               player:(NSUInteger)player {
    (void)speaker;
    (void)headsetRoute;
    // Speaker samples are ignored. The pad speaker stays on USB.
    if (haptics == NULL || identity.length == 0 || player >= 16u || frames == 0u || frames > 480u) {
        return NO;
    }
    Ds5BluetoothAudioState *state = &_states[player];
    DS5BtPeriod period;
    if (!ds5_bt_stream_push(&state->stream, NULL, haptics, frames, &period)) return YES;
    return [self sendHaptics:&period state:state playerIdentity:identity];
}

- (void)resetPlayer:(NSUInteger)player {
    if (player >= 16u) return;
    memset(&_states[player], 0, sizeof(_states[player]));
}

- (void)reset {
    memset(_states, 0, sizeof(_states));
}

@end
