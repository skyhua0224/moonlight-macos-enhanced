//
//  MLDualSenseTouchpad.h
//  Moonlight for macOS
//
//  Sends a DualSense touchpad to the host as a Windows precision touchpad
//  (the same touchpad frames the Mac trackpad uses) instead of as controller
//  touch input or pointer events.
//

#import <Foundation/Foundation.h>
#include "Limelight.h"
#include "Limelight-internal.h"

NS_ASSUME_NONNULL_BEGIN

@interface MLDualSenseTouchpad : NSObject

/// Returns the current input context, or NULL while input must not be sent.
@property (nonatomic, copy, nullable) PML_INPUT_STREAM_CONTEXT (^contextProvider)(void);
/// Mirrors the user setting. Turning it off releases every contact the host still holds.
@property (nonatomic) BOOL enabled;

/// YES when the controller's touchpad is handled here (setting on and the host supports touchpad input),
/// so the caller must not also send it as controller touch input or pointer events.
- (BOOL)claimsTouchpad;
/// Records a finger (0 primary, 1 secondary). x and y are GameController touchpad values, -1...1 with y up.
/// Contacts are sent as one frame after the current batch of callbacks.
- (void)setContact:(NSUInteger)finger active:(BOOL)active x:(float)x y:(float)y player:(NSInteger)player;
/// The pad's physical click.
- (void)setButtonPressed:(BOOL)pressed player:(NSInteger)player;
/// Lifts everything the given controller holds (disconnect, input paused).
- (void)releasePlayer:(NSInteger)player;
/// Lifts everything, whichever controller holds it.
- (void)releaseAll;

@end

NS_ASSUME_NONNULL_END
