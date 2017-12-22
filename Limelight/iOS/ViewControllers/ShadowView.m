//
//  ShadowView.m
//  Moonlight
//
//  Created by Michael Kenny on 10/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "ShadowView.h"

@implementation ShadowView

- (void)setBounds:(CGRect)bounds {
    [super setBounds:bounds];
    
    [self addShadowToThumbnail];
}

- (void)updateShadow {
    [self addShadowToThumbnail];
}

- (void)addShadowToThumbnail {
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOpacity = self.shadowOpacity;
    self.layer.shadowRadius = self.shadowRadius;
    self.layer.shadowOffset = self.shadowOffset;
    
    CGRect shadowRect = CGRectOffset(self.bounds, self.shadowOffset.width, self.shadowOffset.height);
    
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:shadowRect cornerRadius:self.shadowCornerRadius];
    
    if (self.layer.shadowPath != nil) {
        CABasicAnimation *shadowAnimation = [CABasicAnimation animationWithKeyPath:@"shadowPath"];
        shadowAnimation.duration = [UIView inheritedAnimationDuration];
        shadowAnimation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        shadowAnimation.fromValue = (id)self.layer.shadowPath;
        
        [self.layer addAnimation:shadowAnimation forKey:@"shadowPath"];
    }
    
    self.layer.shadowPath = path.CGPath;
}

@end
