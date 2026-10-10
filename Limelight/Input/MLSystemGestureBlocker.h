//
//  MLSystemGestureBlocker.h
//  Moonlight for macOS
//
//  Swallows the macOS Dock gesture events (Mission Control, App Exposé, Spaces and
//  full-screen app swipes, Launchpad and Show Desktop pinches) while the precision
//  touchpad forwards every finger to the host. Only the Dock-bound gesture event
//  type is filtered; the touch events the stream view reads are left untouched.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface MLSystemGestureBlocker : NSObject

/// YES when the process may filter events (Accessibility permission).
+ (BOOL)isAccessibilityTrusted;

/// Shows the system Accessibility prompt when permission is missing. Returns the current trust state.
+ (BOOL)requestAccessibilityPermission;

/// Opens the Accessibility pane of System Settings.
+ (void)openAccessibilitySettings;

/// YES while the event tap is installed.
@property (nonatomic, readonly) BOOL installed;

/// Installs the tap on the main run loop. Returns NO (and logs) when permission is missing or the tap cannot be created.
- (BOOL)installWithReason:(NSString *)reason;

/// Removes the tap immediately. Safe to call when nothing is installed.
- (void)removeWithReason:(NSString *)reason;

@end

NS_ASSUME_NONNULL_END
