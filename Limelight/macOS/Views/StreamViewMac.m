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

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        self.spinner = [[NSProgressIndicator alloc] init];
        self.spinner.style = NSProgressIndicatorStyleSpinning;
        if (@available(macOS 10.14, *)) {
        } else {
            self.spinner.appearance = [NSAppearance appearanceNamed:@"WhiteSpinner"];
        }
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

@end
