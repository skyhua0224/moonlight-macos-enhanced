//
//  StreamViewController+Input.m
//  Moonlight for macOS
//
//  Precision touchpad wiring and Mac input method (IME) text input.
//

#import "StreamViewController_Internal.h"

static const NSUInteger MLMaxImeCommitLength = 4096;

@implementation StreamViewController (InputExtensions)

#pragma mark - Precision touchpad

- (void)configurePrecisionTouchpadInput {
    BOOL enabled = [SettingsClass hostPrecisionTouchpadFor:self.app.host.uuid];
    [self.hidSupport refreshPrecisionTouchpadConfiguration];

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
