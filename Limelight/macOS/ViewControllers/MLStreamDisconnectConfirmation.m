#import "MLStreamDisconnectConfirmation.h"

BOOL MLStreamDisconnectUsesSheet(NSWindowStyleMask style, NSInteger level) {
  // apple-appkit-alert-sheet (Discussion) and apple-appkit-window-level (Discussion).
  return (style & NSWindowStyleMaskTitled) != 0 && level == NSNormalWindowLevel;
}

@interface MLStreamDisconnectConfirmation ()
@property(nonatomic, strong) NSAlert *alert;
@property(nonatomic, weak) NSWindow *host;
@property(nonatomic) BOOL usesSheet;
@property(nonatomic, strong) id eventMonitor;
@property(nonatomic, copy) void (^completion)(NSModalResponse);
@end

@implementation MLStreamDisconnectConfirmation

- (instancetype)initWithAlert:(NSAlert *)alert host:(NSWindow *)host {
  self = [super init];
  if (self) {
    _alert = alert;
    _host = host;
    _usesSheet = MLStreamDisconnectUsesSheet(host.styleMask, host.level);
  }
  return self;
}

- (void)presentWithShortcutMatcher:(BOOL (^)(NSEvent *))matchesShortcut
                        completion:(void (^)(NSModalResponse))completion {
  self.completion = completion;
  NSWindow *host = self.host;
  __weak typeof(self) weakSelf = self;
  // apple-appkit-local-monitor (Discussion). Only handle events for this confirmation and its stream.
  NSEventMask mask =
      NSEventMaskKeyDown | NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown;
  NSEvent * (^handleEvent)(NSEvent *) = ^NSEvent *(NSEvent *event) {
    __strong typeof(weakSelf) confirmation = weakSelf;
    if (!confirmation) {
      return event;
    }
    NSWindow *prompt = confirmation.alert.window;
    NSWindow *target = event.window;
    BOOL targetsHost = target != nil && target == confirmation.host;
    if (target != prompt && !targetsHost) {
      return event;
    }
    if (event.type == NSEventTypeKeyDown && matchesShortcut(event)) {
      if (!event.isARepeat) {
        [confirmation chooseDisconnect];
      }
      return nil;
    }
    if (!confirmation.usesSheet && targetsHost) {
      // Keep clicks on the stream from taking the key window away from the panel.
      [prompt makeKeyAndOrderFront:nil];
      return nil;
    }
    return event;
  };
  self.eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:handleEvent];

  if (self.usesSheet) {
    [self.alert beginSheetModalForWindow:host
                       completionHandler:^(NSModalResponse response) {
                         [weakSelf completeWithResponse:response];
                       }];
    return;
  }

  // Keep AppKit's localized alert layout and use normal target/action outside the sheet session.
  // apple-appkit-alert-layout (Discussion), apple-appkit-alert-add-button (Discussion),
  // apple-appkit-button-target and apple-appkit-button-action (Discussion).
  [self.alert layout]; // apple-appkit-alert-window (Overview) exposes the native panel.
  NSInteger response = NSAlertFirstButtonReturn;
  for (NSButton *button in self.alert.buttons) {
    button.tag = response++;
    button.target = self;
    button.action = @selector(panelButtonPressed:);
  }
  self.alert.buttons.lastObject.keyEquivalent = @"\x1b"; // apple-appkit-button-key (Overview).

  // apple-appkit-child-window (Discussion), apple-appkit-window-key-front (Overview) and
  // apple-appkit-window-fullscreen-auxiliary (Overview).
  NSWindow *panel = self.alert.window;
  panel.collectionBehavior |= NSWindowCollectionBehaviorFullScreenAuxiliary;
  NSRect frame = host.frame;
  [panel
      setFrameOrigin:NSMakePoint(NSMidX(frame) - NSWidth(panel.frame) / 2, NSMidY(frame) - NSHeight(panel.frame) / 2)];
  [host addChildWindow:panel ordered:NSWindowAbove];
  panel.level = MAX(NSFloatingWindowLevel, host.level + 1);
  [panel makeKeyAndOrderFront:nil];
}

- (void)panelButtonPressed:(NSButton *)sender {
  [self completeWithResponse:sender.tag];
}

- (void)chooseDisconnect {
  NSWindow *host = self.host;
  if (self.usesSheet && host.attachedSheet == self.alert.window) {
    // apple-appkit-window-end-sheet (Discussion).
    [host endSheet:self.alert.window returnCode:NSAlertFirstButtonReturn];
  } else if (!self.usesSheet) {
    [self completeWithResponse:NSAlertFirstButtonReturn];
  }
}

- (void)removeEventMonitor {
  if (self.eventMonitor) {
    [NSEvent removeMonitor:self.eventMonitor];
    self.eventMonitor = nil;
  }
}

- (void)completeWithResponse:(NSModalResponse)response {
  void (^completion)(NSModalResponse) = self.completion;
  if (!completion) {
    return;
  }
  self.completion = nil;
  [self removeEventMonitor];
  if (!self.usesSheet) {
    // apple-appkit-window-order-out (Discussion) detaches the child and restores key window ordering.
    [self.alert.window orderOut:nil];
  }
  completion(response);
}

- (void)dismiss {
  self.completion = nil;
  [self removeEventMonitor];
  if (!self.usesSheet) {
    [self.alert.window orderOut:nil];
  } else if (self.host.attachedSheet == self.alert.window) {
    [self.host endSheet:self.alert.window returnCode:NSModalResponseCancel];
  }
}

@end
