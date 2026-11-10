//
//  MLTouchMenuSupport.m
//  Moonlight for macOS
//

#import "MLTouchMenuSupport.h"

@interface MLTouchMenuPressRecognizer : NSPressGestureRecognizer
@end

@implementation MLTouchMenuPressRecognizer
@end

@implementation MLTouchMenuSupport

+ (void)installLongPressMenuOnView:(NSView *)view {
    if (@available(macOS 27.0, *)) {
        for (NSGestureRecognizer *existing in view.gestureRecognizers) {
            if ([existing isKindOfClass:[MLTouchMenuPressRecognizer class]]) return;
        }
        MLTouchMenuPressRecognizer *press = [[MLTouchMenuPressRecognizer alloc] initWithTarget:self action:@selector(pressed:)];
        press.buttonMask = 0;                                  // touches only: the mouse is unchanged
        press.allowedTouchTypes = NSTouchTypeMaskDirect;
        press.minimumPressDuration = 0.45;
        press.allowableMovement = 10;
        press.cancellableByScrollGesture = YES;                // a finger that starts scrolling is not a press
        [view addGestureRecognizer:press];
    }
}

+ (void)pressed:(NSPressGestureRecognizer *)recognizer {
    if (recognizer.state != NSGestureRecognizerStateBegan) return;
    NSView *view = recognizer.view;
    NSMenu *menu = view.menu;
    if (view == nil || menu == nil) return;
    [menu popUpMenuPositioningItem:nil atLocation:[recognizer locationInView:view] inView:view];
}

@end
