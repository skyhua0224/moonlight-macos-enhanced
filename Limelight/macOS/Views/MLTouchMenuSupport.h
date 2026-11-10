//
//  MLTouchMenuSupport.h
//  Moonlight for macOS
//
//  A long press with a finger (touchscreen Mac, Sidecar iPad; macOS 27) opens the same menu as the right
//  click, for the older AppKit cells that keep their menu in NSView.menu.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface MLTouchMenuSupport : NSObject
/// Adds a touch-only long-press recognizer to the view once. The menu is the view's `menu` at the moment of the
/// press, so its delegate (menuWillOpen:) runs as for a right click. Does nothing before macOS 27.
+ (void)installLongPressMenuOnView:(NSView *)view;
@end

NS_ASSUME_NONNULL_END
