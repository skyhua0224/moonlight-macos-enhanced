//
//  NavigatableAlertView.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 13/1/2022.
//  Copyright © 2022 Moonlight Game Streaming Project. All rights reserved.
//

#import "NavigatableAlertView.h"
#import "NSResponder+Moonlight.h"

#include <Carbon/Carbon.h>

@implementation NavigatableAlertView

- (void)controllerEvent:(MoonlightControllerEvent)event {
    switch (event.button) {
        case kMCE_LeftDpad:
            [self sendKey:kVK_Tab down:YES modifiers:kCGEventFlagMaskShift];
            break;
        case kMCE_RightDpad:
            [self sendKey:kVK_Tab down:YES modifiers:0];
            break;
        case kMCE_AButton:
            [self sendKey:kVK_Return down:YES modifiers:0];
            break;
        case kMCE_BButton:
            [self sendKey:kVK_Escape down:YES modifiers:0];
            break;
        case kMCE_XButton:
            [self sendKey:kVK_Space down:YES modifiers:0];
            break;

        case kMCE_Unknown:
            break;
    }
}

- (void)sendKey:(CGKeyCode)keyCode down:(BOOL)down modifiers:(CGEventFlags)modifierFlags {
    CGEventRef cgEvent = CGEventCreateKeyboardEvent(NULL, keyCode, down);
    CGEventSetFlags(cgEvent, modifierFlags);
    NSEvent *event = [NSEvent eventWithCGEvent:cgEvent];
    [self.responder keyDown:event];
}

@end
