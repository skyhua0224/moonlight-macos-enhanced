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
@property (nonatomic, strong) NSTextField *statusLabel;

@end

@implementation StreamViewMac

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        self.spinner = [[NSProgressIndicator alloc] init];
        [self.spinner startAnimation:self];
        [self addSubview:self.spinner];
        self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.centerXAnchor].active = YES;
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.centerYAnchor].active = YES;
        [self.spinner.widthAnchor constraintEqualToConstant:32].active = YES;
        [self.spinner.heightAnchor constraintEqualToConstant:32].active = YES;
        
        self.statusLabel = [[NSTextField alloc] init];
        self.statusLabel.selectable = NO;
        self.statusLabel.bordered = NO;
        self.statusLabel.textColor = [NSColor whiteColor];
        self.statusLabel.backgroundColor = [NSColor clearColor];
        self.statusLabel.font = [NSFont systemFontOfSize:14];
        self.statusLabel.stringValue = @"Starting App";
        [self addSubview:self.statusLabel];
        self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.statusLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor].active = YES;
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-32].active = YES;
    }
    return self;
}

- (void)setStatusText:(NSString *)statusText {
    if (statusText == nil) {
        [self.spinner stopAnimation:self];
        self.spinner.hidden = YES;
    } else {
        self.statusLabel.stringValue = statusText;
        [self.statusLabel sizeToFit];
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    
    [[NSColor blackColor] setFill];
    NSRectFill(dirtyRect);
}

@end
