//
//  NSView+Moonlight.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 8/1/2022.
//  Copyright © 2022 Moonlight Game Streaming Project. All rights reserved.
//

#import "NSView+Moonlight.h"

#import <QuartzCore/QuartzCore.h>

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

- (void)moonlight_fadeToAlpha:(CGFloat)alpha duration:(NSTimeInterval)duration completion:(void (^)(void))completion {
    self.wantsLayer = YES;
    CALayer *layer = self.layer;
    CALayer *shown = layer.presentationLayer;
    float from = shown != nil ? shown.opacity : layer.opacity;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [CATransaction setCompletionBlock:completion];
    self.alphaValue = alpha;
    layer.opacity = (float)alpha;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @(from);
    fade.toValue = @((float)alpha);
    fade.duration = duration;
    fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    if (@available(macOS 12.0, *)) {
        fade.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
    }
    [layer addAnimation:fade forKey:@"moonlightFade"];
    [CATransaction commit];
}

@end
