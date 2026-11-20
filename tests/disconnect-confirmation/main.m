#import "MLStreamDisconnectConfirmation.h"

#import <Carbon/Carbon.h>

static int failures;

static void check(BOOL result, const char *name) {
  printf("%s %s\n", result ? "ok" : "FAIL", name);
  if (!result) {
    failures++;
  }
}

static void checkWindowPolicy(void) {
  NSWindowStyleMask titled = NSWindowStyleMaskTitled | NSWindowStyleMaskResizable;
  check(MLStreamDisconnectUsesSheet(titled, NSNormalWindowLevel), "normal titled window uses a sheet");
  check(MLStreamDisconnectUsesSheet(titled | NSWindowStyleMaskFullScreen, NSNormalWindowLevel),
        "native fullscreen titled window uses a sheet");
  check(!MLStreamDisconnectUsesSheet(NSWindowStyleMaskBorderless, NSMainMenuWindowLevel + 1),
        "raised borderless Free Window uses a panel");
  check(!MLStreamDisconnectUsesSheet(NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable, NSNormalWindowLevel),
        "untitled resizable window uses a panel");
  check(!MLStreamDisconnectUsesSheet(titled, NSFloatingWindowLevel), "titled floating window uses a panel");
  check(!MLStreamDisconnectUsesSheet(NSWindowStyleMaskBorderless, NSFloatingWindowLevel),
        "borderless floating window uses a panel");
}

@interface TestStreamWindow : NSWindow
@end

@implementation TestStreamWindow
- (BOOL)canBecomeKeyWindow {
  return YES;
}
- (BOOL)canBecomeMainWindow {
  return YES;
}
@end

static void postClick(NSWindow *window, NSPoint location) {
  for (NSEventType type = NSEventTypeLeftMouseDown; type <= NSEventTypeLeftMouseUp; type++) {
    NSEvent *event = [NSEvent mouseEventWithType:type
                                        location:location
                                   modifierFlags:0
                                       timestamp:NSProcessInfo.processInfo.systemUptime
                                    windowNumber:window.windowNumber
                                         context:nil
                                     eventNumber:0
                                      clickCount:1
                                        pressure:type == NSEventTypeLeftMouseDown ? 1 : 0];
    [NSApp postEvent:event atStart:NO];
  }
}

static void postCloseShortcut(NSWindow *window, BOOL repeat) {
  NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                    location:NSZeroPoint
                               modifierFlags:NSEventModifierFlagCommand
                                   timestamp:NSProcessInfo.processInfo.systemUptime
                                windowNumber:window.windowNumber
                                     context:nil
                                  characters:@"w"
                 charactersIgnoringModifiers:@"w"
                                   isARepeat:repeat
                                     keyCode:kVK_ANSI_W];
  [NSApp postEvent:event atStart:NO];
}

static void runPanelCases(NSUInteger index, TestStreamWindow *host) {
  static const struct {
    const char *name;
    NSModalResponse response;
  } cases[] = {
      {"click Disconnect", NSAlertFirstButtonReturn},
      {"click Close and Quit", NSAlertSecondButtonReturn},
      {"click Cancel", NSAlertThirdButtonReturn},
      {"press Command-W again", NSAlertFirstButtonReturn},
  };
  if (index == sizeof(cases) / sizeof(cases[0])) {
    [host close];
    printf("%d failed\n", failures);
    exit(failures ? EXIT_FAILURE : EXIT_SUCCESS);
  }

  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Disconnect options";
  [alert addButtonWithTitle:@"Disconnect from Stream"];
  [alert addButtonWithTitle:@"Close and Quit App"];
  [alert addButtonWithTitle:@"Cancel"];
  MLStreamDisconnectConfirmation *confirmation = [[MLStreamDisconnectConfirmation alloc] initWithAlert:alert host:host];
  __block NSUInteger responses = 0;
  __block NSModalResponse result = 0;
  [confirmation
      presentWithShortcutMatcher:^BOOL(NSEvent *event) {
        return event.keyCode == kVK_ANSI_W && (event.modifierFlags & NSEventModifierFlagCommand) != 0;
      }
      completion:^(NSModalResponse response) {
        responses++;
        result = response;
      }];
  NSWindow *panel = alert.window;
  BOOL isRaisedChild = panel.level > host.level && panel.parentWindow == host && host.attachedSheet == nil;
  if (!isRaisedChild) {
    printf("panel level=%ld host level=%ld child=%d attached sheet=%d\n", (long)panel.level, (long)host.level,
           panel.parentWindow == host, host.attachedSheet != nil);
  }
  check(isRaisedChild, "borderless: prompt is a raised child panel");

  // Exercise actual AppKit dispatch after returning to the main run loop.
  postClick(host, NSMakePoint(20, 20));
  postCloseShortcut(panel, YES);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    check(panel.keyWindow && responses == 0, "borderless: stream click and repeated key leave prompt key");
    if (index < 3) {
      NSButton *button = alert.buttons[index];
      NSPoint center = NSMakePoint(NSMidX(button.bounds), NSMidY(button.bounds));
      postClick(panel, [button convertPoint:center toView:nil]);
    } else {
      postCloseShortcut(panel, NO);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      check(responses == 1 && result == cases[index].response, cases[index].name);
      check(!panel.visible && panel.parentWindow == nil, "borderless: response removes the child panel");
      [confirmation dismiss];
      check(responses == 1, "borderless: cleanup delivers no extra response");
      runPanelCases(index + 1, host);
    });
  });
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    checkWindowPolicy();
    if (argc == 2 && strcmp(argv[1], "--gui") == 0) {
      [NSApplication sharedApplication];
      [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
      dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp activateIgnoringOtherApps:YES];
        TestStreamWindow *host = [[TestStreamWindow alloc] initWithContentRect:NSMakeRect(0, 0, 680, 460)
                                                                     styleMask:NSWindowStyleMaskBorderless
                                                                       backing:NSBackingStoreBuffered
                                                                         defer:NO];
        host.releasedWhenClosed = NO;
        host.level = NSMainMenuWindowLevel + 1;
        [host center];
        [host makeKeyAndOrderFront:nil];
        runPanelCases(0, host);
      });
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        fprintf(stderr, "GUI confirmation test timed out\n");
        exit(EXIT_FAILURE);
      });
      [NSApp run];
    }
    printf("%d failed\n", failures);
    return failures ? EXIT_FAILURE : EXIT_SUCCESS;
  }
}
