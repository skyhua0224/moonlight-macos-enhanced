//
//  BackgroundColorView.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 19/6/2024.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

#import "BackgroundColorView.h"

@interface BackgroundColorView ()
@property (nonatomic, assign) CGColorRef backgroundCGColor;
@end

@implementation BackgroundColorView

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        self.wantsLayer = YES;
        _clear = YES;
    }
    return self;
}

- (void)setClear:(BOOL)clear {
    _clear = clear;
    [self updateBackgroundColorWithClear:clear];
}

- (void)updateLayer {
    self.backgroundCGColor = [NSColor colorNamed:self.backgroundColorName].CGColor;
    [self updateBackgroundColorWithClear:self.clear];
}

- (void)updateBackgroundColorWithClear:(BOOL)clear {
    self.layer.backgroundColor = clear ? [NSColor clearColor].CGColor : self.backgroundCGColor;
}

@end
