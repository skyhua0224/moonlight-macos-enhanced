//
//  StreamViewMac.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 27/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "StreamViewMac.h"
#import "MoonlightEnhanced-Swift.h"

@interface StreamViewMac ()
@property (nonatomic, strong) NSView *startupOverlay;

@end

@implementation StreamViewMac

- (NSCursor *)preferredLocalCursor {
    if (!self.prefersHiddenLocalCursor) {
        return [NSCursor arrowCursor];
    }

    static NSCursor *hiddenCursor;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSImage *cursorImage = [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
        [cursorImage lockFocus];
        [[NSColor clearColor] setFill];
        NSRectFill(NSMakeRect(0, 0, cursorImage.size.width, cursorImage.size.height));
        [cursorImage unlockFocus];
        hiddenCursor = [[NSCursor alloc] initWithImage:cursorImage hotSpot:NSZeroPoint];
    });

    return hiddenCursor;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self installStartupOverlay];
    }
    return self;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) [self installStartupOverlay];
    return self;
}

- (void)installStartupOverlay {
    if (self.startupOverlay != nil) return;
    self.startupOverlay = [StreamingStartupOverlayFactory makeView];
    self.startupOverlay.frame = self.bounds;
    self.startupOverlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.startupOverlay.wantsLayer = YES;
    self.startupOverlay.layer.zPosition = 1000;
    [self addSubview:self.startupOverlay positioned:NSWindowAbove relativeTo:nil];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self refreshPreferredLocalCursor];
}

- (void)setPrefersHiddenLocalCursor:(BOOL)prefersHiddenLocalCursor {
    if (_prefersHiddenLocalCursor == prefersHiddenLocalCursor) {
        return;
    }

    _prefersHiddenLocalCursor = prefersHiddenLocalCursor;
    [self refreshPreferredLocalCursor];
}

- (void)refreshPreferredLocalCursor {
    if (self.window != nil) {
        [self.window invalidateCursorRectsForView:self];
    }

    [[self preferredLocalCursor] set];
}

- (void)setStatusText:(NSString *)statusText {
    if (![NSThread isMainThread]) {
        NSString *text = [statusText copy];
        dispatch_async(dispatch_get_main_queue(), ^{ self.statusText = text; });
        return;
    }
    _statusText = [statusText copy];
    [self installStartupOverlay];
    self.startupOverlay.hidden = statusText == nil;
    if (statusText == nil) {
        self.window.title = self.appName;
    } else {
        [self addSubview:self.startupOverlay positioned:NSWindowAbove relativeTo:nil];
        self.window.title = [[self.appName stringByAppendingString:@" - "] stringByAppendingString:statusText];
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    
    [[NSColor blackColor] setFill];
    NSRectFill(dirtyRect);
}

- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.bounds cursor:[self preferredLocalCursor]];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    (void)event;
    return YES;
}

- (BOOL)mouseDownCanMoveWindow {
    return NO;
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    return [self.keyboardNotifiable onKeyboardEquivalent:event];
}

@end
