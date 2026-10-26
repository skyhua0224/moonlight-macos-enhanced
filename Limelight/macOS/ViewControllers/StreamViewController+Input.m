//
//  StreamViewController+Input.m
//  Moonlight for macOS
//
//  Precision touchpad wiring and Mac input method (IME) text input.
//

#import "StreamViewController_Internal.h"
#import "MLPrecisionTouchpad.h"

static const NSUInteger MLMaxImeCommitLength = 4096;

@implementation StreamViewController (InputExtensions)

#pragma mark - Precision touchpad

- (void)configurePrecisionTouchpadInput {
    NSInteger mode = [SettingsClass hostPrecisionTouchpadModeFor:self.app.host.uuid];
    BOOL enabled = mode == MLPrecisionTouchpadModeBlock || mode == MLPrecisionTouchpadModeBoth;
    [self.hidSupport refreshPrecisionTouchpadConfiguration];
    Log(LOG_I, @"[touchpad] mode=%@", !enabled ? @"off" : (mode == MLPrecisionTouchpadModeBoth ? @"both" : @"block"));

    self.precisionTouchpadModeForGestureBlock = enabled ? mode : MLPrecisionTouchpadModeOff;

    StreamViewMac *streamView = self.streamView;
    if (streamView == nil) {
        return;
    }
    if (enabled) {
        __weak typeof(self) weakSelf = self;
        __block BOOL loggedFirstTouch = NO;
        streamView.touchHandler = ^(NSEvent *event, NSView *view) {
            if (!loggedFirstTouch) {
                loggedFirstTouch = YES;
                Log(LOG_I, @"[touchpad] first trackpad touch event received");
            }
            [weakSelf.hidSupport handleTrackpadTouchesEvent:event inView:view];
        };
    } else {
        streamView.touchHandler = nil;
    }
    [streamView setIndirectTouchesEnabled:enabled];
    Log(LOG_I, @"[touchpad] stream view indirect touches %@", enabled ? @"enabled" : @"disabled");
    [self refreshSystemGestureBlockWithReason:@"touchpad-mode"];
}

#pragma mark - System gesture block

- (void)refreshSystemGestureBlockWithReason:(NSString *)reason {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshSystemGestureBlockWithReason:reason];
        });
        return;
    }
    // Same lifetime as the gesture block: only while the stream owns the input.
    [self refreshSystemShortcutCaptureWithReason:reason];

    NSInteger mode = self.precisionTouchpadModeForGestureBlock;
    NSWindow *window = self.view.window;
    BOOL wanted = (mode == MLPrecisionTouchpadModeBlock || mode == MLPrecisionTouchpadModeBoth) &&
                  self.isMouseCaptured &&
                  !self.stopStreamInProgress &&
                  !self.reconnectInProgress &&
                  !self.edgeMenuTemporaryReleaseActive &&
                  !self.edgeMenuMenuVisible &&
                  window != nil && window.isKeyWindow && NSApp.isActive;

    if (!wanted) {
        self.systemGestureBlockUnavailableLogged = NO;
        [self.systemGestureBlocker removeWithReason:reason];
        return;
    }
    if (self.systemGestureBlocker.installed) {
        return;
    }
    if (![MLSystemGestureBlocker isAccessibilityTrusted]) {
        // Block mode keeps working without the permission; only the local system gestures stay active.
        if (!self.systemGestureBlockUnavailableLogged) {
            self.systemGestureBlockUnavailableLogged = YES;
            Log(LOG_I, @"[gesture] block tap not installed reason=%@ accessibility=0", reason);
        }
        return;
    }
    if (self.systemGestureBlocker == nil) {
        self.systemGestureBlocker = [[MLSystemGestureBlocker alloc] init];
    }
    [self.systemGestureBlocker installWithReason:reason];
}

#pragma mark - System shortcut capture

- (BOOL)streamOwnsInputForSystemCapture {
    NSWindow *window = self.view.window;
    return self.isMouseCaptured &&
           !self.stopStreamInProgress &&
           !self.reconnectInProgress &&
           !self.edgeMenuTemporaryReleaseActive &&
           !self.edgeMenuMenuVisible &&
           window != nil && window.isKeyWindow && NSApp.isActive;
}

- (void)refreshSystemShortcutCaptureWithReason:(NSString *)reason {
    BOOL wanted = [SettingsClass captureSystemShortcutsFor:self.app.host.uuid] &&
                  [self streamOwnsInputForSystemCapture];
    if (!wanted) {
        self.systemShortcutCaptureUnavailableLogged = NO;
        [self.systemShortcutCapture removeWithReason:reason];
        return;
    }
    if (self.systemShortcutCapture.installed) {
        return;
    }
    if (![MLSystemGestureBlocker isAccessibilityTrusted]) {
        // Without the permission macOS keeps its shortcuts; everything else is unchanged.
        if (!self.systemShortcutCaptureUnavailableLogged) {
            self.systemShortcutCaptureUnavailableLogged = YES;
            Log(LOG_I, @"[keyboard] system shortcut tap not installed reason=%@ accessibility=0", reason);
        }
        return;
    }
    if (self.systemShortcutCapture == nil) {
        self.systemShortcutCapture = [[MLSystemShortcutCapture alloc] init];
    }
    [self.systemShortcutCapture installWithReason:reason];
}

#pragma mark - Input method text

- (BOOL)inputMethodIsComposing {
    // Only input modes (Pinyin, Zhuyin, Kana, ...) compose; plain keyboard layouts do not.
    TISInputSourceRef source = TISCopyCurrentKeyboardInputSource();
    if (source == NULL) {
        return NO;
    }
    CFStringRef type = (CFStringRef)TISGetInputSourceProperty(source, kTISPropertyInputSourceType);
    BOOL composing = type != NULL && !CFEqual(type, kTISTypeKeyboardLayout);
    CFRelease(source);
    return composing;
}

- (BOOL)remoteFieldIsPassword {
    if (self.imeRemoteTextContext.length != sizeof(LI_REMOTE_TEXT_CONTEXT)) {
        return NO;
    }
    const LI_REMOTE_TEXT_CONTEXT *context = (const LI_REMOTE_TEXT_CONTEXT *)self.imeRemoteTextContext.bytes;
    return (context->flags & LI_TEXT_CONTEXT_FLAG_ACTIVE) != 0 && (context->flags & LI_TEXT_CONTEXT_FLAG_PASSWORD) != 0;
}

- (void)refreshTextInputConfiguration {
    BOOL enabled = [SettingsClass imeTextInputFor:self.app.host.uuid];
    if (enabled == self.imeTextInputEnabled && (!enabled || self.imeInputContext != nil)) {
        return;
    }
    self.imeTextInputEnabled = enabled;
    if (enabled) {
        if (self.imeConsumedKeyCodes == nil) {
            self.imeConsumedKeyCodes = [NSMutableSet set];
        }
        if (self.imeInputContext == nil) {
            self.imeInputContext = [[NSTextInputContext alloc] initWithClient:self];
        }
        [self.imeInputContext activate];
        Log(LOG_I, @"[text] input method text enabled");
    } else {
        [self discardInputMethodComposition];
        [self.imeInputContext deactivate];
        self.imeInputContext = nil;
        [self.imeConsumedKeyCodes removeAllObjects];
        Log(LOG_I, @"[text] input method text disabled");
    }
}

- (NSTextInputContext *)inputContext {
    return self.imeTextInputEnabled ? self.imeInputContext : nil;
}

- (BOOL)imeShouldHandleKeyEvent:(NSEvent *)event {
    if (!self.imeTextInputEnabled || self.imeInputContext == nil || !self.hidSupport.shouldSendInputEvents) {
        return NO;
    }
    if ([self remoteFieldIsPassword]) {
        return NO;
    }
    // Shortcuts and control sequences always go to the host as key events.
    if ((event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) != 0) {
        return NO;
    }
    if (self.imeMarkedText.length > 0) {
        return YES;
    }
    return [self inputMethodIsComposing];
}

- (BOOL)routeKeyDownToInputMethod:(NSEvent *)event {
    if (![self imeShouldHandleKeyEvent:event]) {
        return NO;
    }

    BOOL hadMarkedText = self.imeMarkedText.length > 0;
    self.imeHandlingEvent = YES;
    self.imeEventProducedText = NO;
    BOOL handled = [self.imeInputContext handleEvent:event];
    self.imeHandlingEvent = NO;

    // Keys the input method did not turn into text or composition changes (backspace, arrows,
    // return with nothing composed) belong to the host as ordinary key events.
    if (!handled || (!self.imeEventProducedText && !hadMarkedText)) {
        return NO;
    }

    [self.imeConsumedKeyCodes addObject:@(event.keyCode)];
    return YES;
}

- (BOOL)shouldSwallowKeyUpForInputMethod:(NSEvent *)event {
    if (self.imeConsumedKeyCodes.count == 0) {
        return NO;
    }
    NSNumber *code = @(event.keyCode);
    if ([self.imeConsumedKeyCodes containsObject:code]) {
        [self.imeConsumedKeyCodes removeObject:code];
        return YES;
    }
    return NO;
}

- (void)routeFlagsChangedToInputMethod:(NSEvent *)event {
    // Input methods use modifier taps (for example Shift to switch language), so let them observe them.
    if (self.imeTextInputEnabled && self.imeInputContext != nil && self.hidSupport.shouldSendInputEvents) {
        [self.imeInputContext handleEvent:event];
    }
}

- (void)discardInputMethodComposition {
    if (self.imeMarkedText.length > 0) {
        self.imeMarkedText = nil;
        [self.imeInputContext discardMarkedText];
    }
    [self updateImeCompositionLabel];
}

- (void)remoteTextContextUpdated:(const LI_REMOTE_TEXT_CONTEXT *)context {
    if (context == NULL) {
        return;
    }
    NSData *snapshot = [NSData dataWithBytes:context length:sizeof(*context)];
    dispatch_async(dispatch_get_main_queue(), ^{
        const LI_REMOTE_TEXT_CONTEXT *context = (const LI_REMOTE_TEXT_CONTEXT *)snapshot.bytes;
        BOOL wasActive = NO;
        if (self.imeRemoteTextContext.length == sizeof(LI_REMOTE_TEXT_CONTEXT)) {
            wasActive = (((const LI_REMOTE_TEXT_CONTEXT *)self.imeRemoteTextContext.bytes)->flags & LI_TEXT_CONTEXT_FLAG_ACTIVE) != 0;
        }
        self.imeRemoteTextContext = snapshot;
        BOOL active = (context->flags & LI_TEXT_CONTEXT_FLAG_ACTIVE) != 0;
        if (active != wasActive) {
            Log(LOG_I, @"[text] host text field %@ (password=%d)", active ? @"focused" : @"unfocused",
                (context->flags & LI_TEXT_CONTEXT_FLAG_PASSWORD) ? 1 : 0);
        }
        if (!active) {
            [self discardInputMethodComposition];
        }
        [self.imeInputContext invalidateCharacterCoordinates];
    });
}

#pragma mark - Type clipboard text

- (void)typeClipboardTextFromMenu:(id)sender {
    // Typing works on any host, including ones without clipboard sync.
    static const NSUInteger maxTypedLength = 65536;
    NSString *text = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
    if (text.length == 0) {
        [self showNotification:MLString(@"No text in clipboard", nil)];
        return;
    }
    // CRLF would type two line breaks on the host.
    text = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    if (text.length > maxTypedLength) {
        text = [text substringToIndex:[text rangeOfComposedCharacterSequenceAtIndex:maxTypedLength].location];
        Log(LOG_W, @"[text] clipboard text truncated to %lu characters for typing", (unsigned long)text.length);
    }
    // The shortcut's modifiers are already down on the host; they must not
    // apply to the typed characters.
    [self.hidSupport releaseAllModifierKeys];
    BOOL sent = [self.hidSupport sendUtf8Text:text];
    Log(LOG_I, @"[text] typed clipboard text: %lu characters sent=%d", (unsigned long)text.length, sent ? 1 : 0);
    if (!sent) {
        [self showNotification:MLString(@"Clipboard text could not be typed", nil)];
    }
}

#pragma mark - Composition label

- (void)updateImeCompositionLabel {
    if (self.imeMarkedText.length == 0) {
        [self.imeCompositionLabel removeFromSuperview];
        self.imeCompositionLabel = nil;
        return;
    }
    if (self.imeCompositionLabel == nil) {
        NSTextField *label = [NSTextField labelWithString:@""];
        label.font = [NSFont systemFontOfSize:15];
        label.textColor = NSColor.labelColor;
        label.drawsBackground = YES;
        label.backgroundColor = [NSColor.windowBackgroundColor colorWithAlphaComponent:0.92];
        label.wantsLayer = YES;
        label.layer.cornerRadius = 5;
        label.layer.masksToBounds = YES;
        self.imeCompositionLabel = label;
        [self.view addSubview:label];
    }
    NSTextField *label = self.imeCompositionLabel;
    label.stringValue = [@" " stringByAppendingString:[self.imeMarkedText stringByAppendingString:@" "]];
    [label sizeToFit];
    NSRect caret = [self caretRectInViewCoordinates];
    NSRect frame = label.frame;
    frame.origin.x = MIN(MAX(NSMinX(caret), 8), MAX(8, NSWidth(self.view.bounds) - NSWidth(frame) - 8));
    frame.origin.y = MAX(8, NSMinY(caret) - NSHeight(frame) - 4);
    label.frame = frame;
}

// The host's caret in view coordinates; the video is aspect-fit inside the view.
- (NSRect)caretRectInViewCoordinates {
    NSRect bounds = self.view.bounds;
    NSRect fallback = NSMakeRect(NSMidX(bounds), NSMinY(bounds) + 60, 1, 20);
    if (self.imeRemoteTextContext.length != sizeof(LI_REMOTE_TEXT_CONTEXT)) {
        return fallback;
    }
    const LI_REMOTE_TEXT_CONTEXT *context = (const LI_REMOTE_TEXT_CONTEXT *)self.imeRemoteTextContext.bytes;
    if ((context->flags & LI_TEXT_CONTEXT_FLAG_ACTIVE) == 0 ||
        (context->flags & LI_TEXT_CONTEXT_FLAG_CARET_RECT) == 0 ||
        context->captureWidth == 0 || context->captureHeight == 0) {
        return fallback;
    }

    CGFloat scale = MIN(NSWidth(bounds) / context->captureWidth, NSHeight(bounds) / context->captureHeight);
    if (!isfinite(scale) || scale <= 0) {
        return fallback;
    }
    CGFloat offsetX = (NSWidth(bounds) - context->captureWidth * scale) / 2.0;
    CGFloat offsetY = (NSHeight(bounds) - context->captureHeight * scale) / 2.0;
    CGFloat left = offsetX + context->caretLeft * scale;
    CGFloat right = offsetX + context->caretRight * scale;
    // Capture coordinates grow downward, view coordinates grow upward.
    CGFloat top = offsetY + (context->captureHeight - context->caretTop) * scale;
    CGFloat bottom = offsetY + (context->captureHeight - context->caretBottom) * scale;
    return NSMakeRect(left, MIN(top, bottom), MAX(right - left, 1), MAX(fabs(top - bottom), 1));
}

#pragma mark - NSTextInputClient

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    NSString *text = [string isKindOfClass:[NSAttributedString class]] ? [(NSAttributedString *)string string] : (NSString *)string;
    self.imeMarkedText = nil;
    [self updateImeCompositionLabel];
    if (![text isKindOfClass:[NSString class]] || text.length == 0 || !self.imeTextInputEnabled) {
        return;
    }
    if (text.length > MLMaxImeCommitLength) {
        text = [text substringToIndex:MLMaxImeCommitLength];
    }
    self.imeEventProducedText = YES;
    BOOL sent = [self.hidSupport sendUtf8Text:text];
    Log(LOG_D, @"[text] committed %lu characters sent=%d", (unsigned long)text.length, sent ? 1 : 0);
    if (!sent) {
        Log(LOG_W, @"[text] committed text was not sent (input stream not ready)");
    }
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
    NSString *text = [string isKindOfClass:[NSAttributedString class]] ? [(NSAttributedString *)string string] : (NSString *)string;
    self.imeMarkedText = [text isKindOfClass:[NSString class]] && text.length > 0 ? text : nil;
    self.imeEventProducedText = YES;
    [self updateImeCompositionLabel];
}

- (void)unmarkText {
    self.imeMarkedText = nil;
    self.imeEventProducedText = YES;
    [self updateImeCompositionLabel];
}

- (NSRange)selectedRange {
    return NSMakeRange(NSNotFound, 0);
}

- (NSRange)markedRange {
    return self.imeMarkedText.length > 0 ? NSMakeRange(0, self.imeMarkedText.length) : NSMakeRange(NSNotFound, 0);
}

- (BOOL)hasMarkedText {
    return self.imeMarkedText.length > 0;
}

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    if (self.imeMarkedText.length == 0) {
        return nil;
    }
    NSRange clamped = NSIntersectionRange(range, NSMakeRange(0, self.imeMarkedText.length));
    if (actualRange != NULL) {
        *actualRange = clamped;
    }
    return [[NSAttributedString alloc] initWithString:[self.imeMarkedText substringWithRange:clamped]];
}

- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText {
    return @[];
}

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    NSRect caret = [self caretRectInViewCoordinates];
    NSRect inWindow = [self.view convertRect:caret toView:nil];
    return [self.view.window convertRectToScreen:inWindow];
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    return NSNotFound;
}

- (void)doCommandBySelector:(SEL)selector {
    // Commands such as deleteBackward: are replayed to the host as the original key event.
}

@end
