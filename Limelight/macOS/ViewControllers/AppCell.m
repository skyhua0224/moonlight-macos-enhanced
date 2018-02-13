//
//  AppCell.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 24/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "AppCell.h"
#import "BackgroundColorView.h"
#import "AppCellView.h"

#import <QuartzCore/QuartzCore.h>

@interface AppCell () <NSMenuDelegate>

@end

@implementation AppCell

- (void)viewDidLoad {
    [super viewDidLoad];
    
    NSShadow *shadow = [[NSShadow alloc] init];
    [shadow setShadowColor:[NSColor colorWithWhite:0 alpha:0.55]];
    [shadow setShadowOffset:NSMakeSize(0, -4)];
    [shadow setShadowBlurRadius:4];
    self.appCoverArt.superview.shadow = shadow;

    self.appCoverArt.wantsLayer = YES;
    self.appCoverArt.layer.masksToBounds = YES;
    self.appCoverArt.layer.cornerRadius = 6;
    
    self.resumeIcon.alphaValue = 0.9;
    
    self.view.layer.anchorPoint = CGPointMake(0.5, 0.5);
    self.view.layer.transform = [self translationTransform];

    ((AppCellView *)self.view).delegate = self;
    
    [self updateSelectedState:NO];
}

- (CATransform3D)translationTransform {
    return CATransform3DMakeTranslation(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 0);
}

- (void)updateSelectedState:(BOOL)selected {
    self.appName.textColor = selected ? [NSColor alternateSelectedControlColor] : [NSColor textColor];

    self.view.layer.anchorPoint = CGPointMake(0.5, 0.5);
    CATransform3D oldTransform = selected ? [self translationTransform] : CATransform3DScale([self translationTransform], 1.2, 1.2, 1);
    CATransform3D newTransform = selected ? CATransform3DScale([self translationTransform], 1.2, 1.2, 1) : [self translationTransform];

    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"transform"];
    animation.fromValue = [NSValue valueWithCATransform3D:oldTransform];
    animation.toValue = [NSValue valueWithCATransform3D:newTransform];
    animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    animation.duration = 0.2;
    animation.beginTime = 0.0;
    
    [self.view.layer addAnimation:animation forKey:nil];
    self.view.layer.transform = newTransform;
}

- (void)setSelected:(BOOL)selected {
    BOOL previousState = self.selected;
    [super setSelected:selected];
    
    if (previousState != selected) {
        [self updateSelectedState:selected];
    }
}

- (void)hoverStateChanged:(BOOL)hovered {
    self.view.layer.anchorPoint = CGPointMake(0.5, 0.5);
    CATransform3D oldTransform = hovered ? [self translationTransform] : CATransform3DScale([self translationTransform], 1.1, 1.1, 1);
    CATransform3D newTransform = hovered ? CATransform3DScale([self translationTransform], 1.1, 1.1, 1) : [self translationTransform];
    
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"transform"];
    animation.fromValue = [NSValue valueWithCATransform3D:oldTransform];
    animation.toValue = [NSValue valueWithCATransform3D:newTransform];
    animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    animation.duration = 0.2;
    animation.beginTime = 0.0;
    
    [self.view.layer addAnimation:animation forKey:nil];
    self.view.layer.transform = newTransform;
}

- (void)mouseEntered:(NSEvent *)event {
    [self hoverStateChanged:YES];
}

- (void)mouseExited:(NSEvent *)event {
    [self hoverStateChanged:NO];
}

- (void)mouseDown:(NSEvent *)theEvent {
    if ([theEvent clickCount] == 2) {
        [self.delegate openApp:self.app];
    } else {
        [super mouseDown:theEvent];
    }
}

- (void)menuWillOpen:(NSMenu *)menu {
    [self.delegate didOpenContextMenu:menu forApp:self.app];
}

@end
