//
//  NSView+Moonlight.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 8/1/2022.
//  Copyright © 2022 Moonlight Game Streaming Project. All rights reserved.
//

#import "NSView+Moonlight.h"

@implementation NSView (Moonlight)

- (void)setBackgroundColor:(NSColor *)backgroundColor {
    self.wantsLayer = YES;
    self.layer.backgroundColor = backgroundColor.CGColor;
}

- (NSColor *)backgroundColor {
    return [NSColor colorWithCGColor:self.layer.backgroundColor];
}

- (void)smoothRoundCornersWithCornerRadius:(CGFloat)cornerRadius {
    self.wantsLayer = YES;
    self.layer.masksToBounds = YES;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.cornerRadius = cornerRadius;
}

@end
