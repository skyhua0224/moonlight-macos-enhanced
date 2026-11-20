#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import "KeyboardRouting.h"

#include "shortcut_modifiers.inc"

#define Log(...) ((void)0)
#define LOCAL_ACTION(name) static NSString *const MLShortcutAction##name = @ #name;
LOCAL_ACTION(ShowDisconnectOptions)
LOCAL_ACTION(DisconnectStream)
LOCAL_ACTION(CloseAndQuitApp)
LOCAL_ACTION(ReconnectStream)
LOCAL_ACTION(ToggleMouseMode)
LOCAL_ACTION(ToggleFullscreenControlBall)
LOCAL_ACTION(OpenControlCenter)
LOCAL_ACTION(TypeClipboardText)
#undef LOCAL_ACTION

enum { KeyboardCompatibilityModeSwapOptionAndCommand = 1 };
enum { KeyboardTranslationOutputKindRemoteShortcut, KeyboardTranslationOutputKindLocalAction };

@interface StreamShortcut : NSObject
@property NSInteger keyCode;
@property NSEventModifierFlags modifierFlags;
@property BOOL modifierOnly;
@property BOOL hasKeyCode;
@end
@implementation StreamShortcut
@end

@interface KeyboardTranslationRule : NSObject
@property(strong) StreamShortcut *trigger;
@property(strong) StreamShortcut *outputShortcut;
@property NSInteger outputKind;
@property(strong) NSString *localAction;
@end
@implementation KeyboardTranslationRule
@end

@interface SettingsClass : NSObject
@end
static NSArray<KeyboardTranslationRule *> *translationRules;
static NSInteger compatibilityMode;
@implementation SettingsClass
+ (NSArray<KeyboardTranslationRule *> *)keyboardTranslationRulesFor:(NSString *)uuid {
  return translationRules;
}
+ (NSInteger)keyboardCompatibilityModeFor:(NSString *)uuid {
  return compatibilityMode;
}
@end

@interface TestHost : NSObject
@property(strong) TestHost *host;
@property(strong) NSString *uuid;
@end
@implementation TestHost
@end

@interface TestView : NSObject
@property(strong) NSWindow *window;
@end
@implementation TestView
@end

@interface RecordingHID : NSObject
@property BOOL shouldSendInputEvents;
@property(strong) NSMutableString *sequence;
@property(strong) StreamShortcut *translatedShortcut;
@end
@implementation RecordingHID
- (void)keyDown:(NSEvent *)event {
  if (self.shouldSendInputEvents) {
    [self.sequence appendString:event.isARepeat ? @"r" : @"d"];
  }
}
- (void)keyUp:(NSEvent *)event {
  if (self.shouldSendInputEvents) {
    [self.sequence appendString:@"u"];
  }
}
- (void)releaseAllModifierKeys {
}
- (void)sendSyntheticRemoteShortcut:(StreamShortcut *)shortcut {
  self.translatedShortcut = shortcut;
}
@end

@interface StreamViewController : NSObject
@property(strong) RecordingHID *hidSupport;
@property(strong) TestHost *app;
@property(strong) TestView *view;
@property(strong) NSMutableSet<NSNumber *> *heldKeyEquivalentCodes;
@property(strong) NSMutableSet<NSNumber *> *windowsHeldKeyEquivalentCodes;
@property NSUInteger pendingOptionUncaptureToken;
@end
@implementation StreamViewController
- (void)resolveDeferredCommandModifierWithoutRemoteTapWithReason:(NSString *)reason event:(NSEvent *)event {
}
- (BOOL)routeKeyDownToInputMethod:(NSEvent *)event {
  return NO;
}
- (BOOL)shouldSwallowKeyUpForInputMethod:(NSEvent *)event {
  return NO;
}
- (BOOL)keyboardTranslationLocalActionReleasesHeldModifiers:(NSString *)action {
  return NO;
}
- (BOOL)performKeyboardTranslationLocalAction:(NSString *)action {
  return NO;
}
- (StreamShortcut *)streamShortcutForAction:(NSString *)action {
  return nil;
}
- (BOOL)event:(NSEvent *)event matchesShortcut:(StreamShortcut *)shortcut {
  return NO;
}
- (BOOL)isWindowFullscreen {
  return NO;
}
- (void)performClose:(id)sender {
}
- (void)requestStreamCloseWithSource:(NSString *)source {
}
- (void)performCloseAndQuitApp:(id)sender {
}
- (void)reconnectFromMenu:(id)sender {
}
- (BOOL)handleOverlayShortcutForEvent:(NSEvent *)event route:(NSString *)route {
  return NO;
}
- (void)toggleMouseMode {
}
- (void)toggleFullscreenControlBallVisibility {
}
- (void)presentControlCenterFromShortcut {
}
- (void)typeClipboardTextFromMenu:(id)sender {
}
#include "keyboard_routes.inc"
@end

typedef struct {
  const char *name;
  unsigned short code;
  unichar character;
} TestKey;

static NSEvent *keyEvent(TestKey key, NSEventType type, NSEventModifierFlags flags, BOOL repeat) {
  NSString *characters = key.character ? [NSString stringWithCharacters:&key.character length:1] : @"";
  return [NSEvent keyEventWithType:type
                          location:NSZeroPoint
                     modifierFlags:flags
                         timestamp:0
                      windowNumber:0
                           context:nil
                        characters:characters
       charactersIgnoringModifiers:characters
                         isARepeat:repeat
                           keyCode:key.code];
}

static StreamViewController *stream(void) {
  StreamViewController *controller = [StreamViewController new];
  controller.hidSupport = [RecordingHID new];
  controller.hidSupport.shouldSendInputEvents = YES;
  controller.hidSupport.sequence = [NSMutableString string];
  controller.app = [TestHost new];
  controller.app.host = [TestHost new];
  controller.app.host.uuid = @"test-host";
  controller.view = [TestView new];
  controller.view.window = (NSWindow *)[NSObject new];
  return controller;
}

static int failures;
static void check(const char *name, BOOL passed, NSString *sequence) {
  printf("%s %s (%s)\n", passed ? "PASS" : "FAIL", name, sequence.UTF8String);
  failures += !passed;
}

// See macos-apple-nsresponder-keydown-20261120, macos-apple-nsresponder-keyup-20261120,
// and macos-apple-nsevent-repeat-20261120 (Discussion).
// The observable edge order follows w3c-ui-events-keyboard-order-20261120, §3.5.5.
static void checkHold(TestKey key, NSEventModifierFlags flags, BOOL equivalent, BOOL monitorShouldConsume) {
  StreamViewController *controller = stream();
  BOOL handled = YES;
  for (int index = 0; index < 4; ++index) {
    NSEvent *event = keyEvent(key, NSEventTypeKeyDown, flags, index != 0);
    if (equivalent) {
      handled &= [controller onKeyboardEquivalent:event];
    } else {
      [controller keyDown:event];
    }
  }
  NSString *sequence = controller.hidSupport.sequence;
  BOOL heldThroughout = [sequence isEqualToString:@"drrr"];
  // Physical key-up can arrive with different modifier flags.
  NSEvent *release = keyEvent(key, NSEventTypeKeyUp, 0, NO);
  NSEvent *remainingEvent = [controller monitorKeyUp:release];
  if (remainingEvent != nil) {
    [controller keyUp:remainingEvent];
  }
  check(key.name,
        handled && heldThroughout && (remainingEvent == nil) == monitorShouldConsume &&
            [sequence isEqualToString:@"drrru"],
        sequence);
}

int main(void) {
  @autoreleasepool {
    const TestKey functionKeys[] = {
        {"Up", kVK_UpArrow, NSUpArrowFunctionKey},
        {"Down", kVK_DownArrow, NSDownArrowFunctionKey},
        {"Left", kVK_LeftArrow, NSLeftArrowFunctionKey},
        {"Right", kVK_RightArrow, NSRightArrowFunctionKey},
        {"Insert", kVK_Help, NSInsertFunctionKey},
        {"Help (Insert mapping)", kVK_Help, NSHelpFunctionKey},
        {"Forward Delete", kVK_ForwardDelete, NSDeleteFunctionKey},
        {"Home", kVK_Home, NSHomeFunctionKey},
        {"End", kVK_End, NSEndFunctionKey},
        {"Page Up", kVK_PageUp, NSPageUpFunctionKey},
        {"Page Down", kVK_PageDown, NSPageDownFunctionKey},
        {"F1", kVK_F1, NSF1FunctionKey},
        {"F2", kVK_F2, NSF2FunctionKey},
        {"F3", kVK_F3, NSF3FunctionKey},
        {"F4", kVK_F4, NSF4FunctionKey},
        {"F5", kVK_F5, NSF5FunctionKey},
        {"F6", kVK_F6, NSF6FunctionKey},
        {"F7", kVK_F7, NSF7FunctionKey},
        {"F8", kVK_F8, NSF8FunctionKey},
        {"F9", kVK_F9, NSF9FunctionKey},
        {"F10", kVK_F10, NSF10FunctionKey},
        {"F11", kVK_F11, NSF11FunctionKey},
        {"F12", kVK_F12, NSF12FunctionKey},
    };
    for (size_t i = 0; i < sizeof(functionKeys) / sizeof(functionKeys[0]); ++i) {
      checkHold(functionKeys[i], NSEventModifierFlagFunction, YES, YES);
    }
    checkHold((TestKey){"Plain A", kVK_ANSI_A, 'a'}, 0, NO, NO);
    checkHold((TestKey){"Control+W", kVK_ANSI_W, 'w'}, NSEventModifierFlagControl, YES, NO);
    compatibilityMode = KeyboardCompatibilityModeSwapOptionAndCommand;
    checkHold((TestKey){"Windows-order Command+Tab", kVK_Tab, '\t'}, NSEventModifierFlagCommand, YES, YES);
    compatibilityMode = 0;

    StreamViewController *controller = stream();
    [controller onKeyboardEquivalent:keyEvent((TestKey){"Caps Lock", kVK_CapsLock, 0}, NSEventTypeKeyDown,
                                              NSEventModifierFlagCapsLock, NO)];
    check("Synthetic Caps Lock tap", [controller.hidSupport.sequence isEqualToString:@"du"],
          controller.hidSupport.sequence);
    controller = stream();
    [controller onKeyboardEquivalent:keyEvent((TestKey){"Fn+A", kVK_ANSI_A, 'a'}, NSEventTypeKeyDown,
                                              NSEventModifierFlagFunction, NO)];
    check("Fn with printable key retains equivalent tap", [controller.hidSupport.sequence isEqualToString:@"du"],
          controller.hidSupport.sequence);

    KeyboardTranslationRule *rule = [KeyboardTranslationRule new];
    rule.trigger = [StreamShortcut new];
    rule.trigger.keyCode = kVK_F1;
    rule.trigger.modifierFlags = NSEventModifierFlagFunction;
    rule.trigger.hasKeyCode = YES;
    rule.outputShortcut = [StreamShortcut new];
    rule.outputShortcut.keyCode = kVK_ANSI_A;
    rule.outputShortcut.modifierFlags = NSEventModifierFlagControl;
    translationRules = @[ rule ];
    controller = stream();
    BOOL handled = [controller onKeyboardEquivalent:keyEvent((TestKey){"F1", kVK_F1, NSF1FunctionKey},
                                                             NSEventTypeKeyDown, NSEventModifierFlagFunction, NO)];
    check("F1 translation dispatches the configured remote shortcut",
          handled && controller.hidSupport.translatedShortcut == rule.outputShortcut &&
              controller.hidSupport.sequence.length == 0,
          @"F1 -> Control+A");
  }
  return failures != 0;
}
