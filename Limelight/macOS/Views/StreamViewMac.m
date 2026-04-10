//
//  StreamViewMac.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 27/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "StreamViewMac.h"

@interface StreamViewMac ()
@property (nonatomic, strong) NSProgressIndicator *spinner;

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
        self.spinner = [[NSProgressIndicator alloc] init];
        self.spinner.style = NSProgressIndicatorStyleSpinning;
        [self.spinner startAnimation:self];
        [self addSubview:self.spinner];
        self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.centerXAnchor].active = YES;
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.centerYAnchor].active = YES;
        [self.spinner.widthAnchor constraintEqualToConstant:32].active = YES;
        [self.spinner.heightAnchor constraintEqualToConstant:32].active = YES;
    }
    return self;
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
    if (statusText == nil) {
        [self.spinner stopAnimation:self];
        self.spinner.hidden = YES;
        self.window.title = self.appName;
    } else {
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
