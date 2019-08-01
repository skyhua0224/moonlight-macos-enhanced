//
//  AppCell.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 24/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "AppCell.h"
#import "AppCellView.h"
#import "NSApplication+Moonlight.h"

#import <QuartzCore/QuartzCore.h>

@interface AppCell () <NSMenuDelegate>
@property (nonatomic) BOOL hovered;
@property (nonatomic) BOOL previousHovered;
@property (nonatomic) BOOL previousSelected;
@end

@implementation AppCell

- (void)viewDidLoad {
    [super viewDidLoad];
    
    NSShadow *runningShadow = [[NSShadow alloc] init];
    [runningShadow setShadowColor:[NSColor colorWithRed:0.06 green:0.204 blue:0.5 alpha:0.75]];
    [runningShadow setShadowOffset:NSMakeSize(0, -2)];
    [runningShadow setShadowBlurRadius:2];
    self.runningIcon.shadow = runningShadow;
    
    self.appCoverArt.wantsLayer = YES;
    self.appCoverArt.layer.masksToBounds = YES;
    self.appCoverArt.layer.cornerRadius = 10;
    
    self.appNameContainer.wantsLayer = YES;
    self.appNameContainer.layer.masksToBounds = YES;
    self.appNameContainer.layer.cornerRadius = 4;

    ((AppCellView *)self.view).delegate = self;
    
    [self updateSelectedState:NO];
}

- (CATransform3D)translationTransform {
    return CATransform3DMakeTranslation(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 0);
}

- (CGFloat)scaleForSelected:(BOOL)selected hovered:(BOOL)hovered {
    CGFloat scale = 1;
    if (hovered || selected) {
        scale *= 1.1;
    }
    return scale;
}

- (void)animateSelectedAndHoveredState {
    CGFloat oldScale = [self scaleForSelected:self.previousSelected hovered:self.previousHovered];
    CGFloat newScale = [self scaleForSelected:self.selected hovered:self.hovered];
    if (fabs(oldScale - newScale) < 0.0001) {
        return;
    }

    self.view.layer.anchorPoint = CGPointMake(0.5, 0.5);
    CATransform3D oldTransform = CATransform3DScale([self translationTransform], oldScale, oldScale, 1);
    CATransform3D newTransform = CATransform3DScale([self translationTransform], newScale, newScale, 1);
    
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"transform"];
    animation.fromValue = [NSValue valueWithCATransform3D:oldTransform];
    animation.toValue = [NSValue valueWithCATransform3D:newTransform];
    animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    animation.duration = 0.2;
    animation.beginTime = 0.0;
    
    [self.view.layer addAnimation:animation forKey:nil];
    self.view.layer.transform = newTransform;
    
    [NSAnimationContext beginGrouping];
    [NSAnimationContext currentContext].duration = 0.4;
    self.appCoverArt.superview.animator.alphaValue = [self appCoverArtAlphaWithHovered:self.hovered];
    [NSAnimationContext endGrouping];
    
    self.previousSelected = self.selected;
    self.previousHovered = self.hovered;
}

- (CGFloat)shadowAlphaWithSelected:(BOOL)selected {
//    if (selected) {
//        return [NSApplication moonlight_isDarkAppearance] ? 0.75 : 0.64;
//    } else {
        return [NSApplication moonlight_isDarkAppearance] ? 0.7 : 0.33;
//    }
}

- (CGFloat)appCoverArtAlphaWithHovered:(BOOL)hovered {
    if (self.selected) {
        return 1;
    } else {
        if (hovered) {
            return [NSApplication moonlight_isDarkAppearance] ? 1 : 1;
        } else {
            return [NSApplication moonlight_isDarkAppearance] ? 0.75 : 0.85;
        }
    }
}

- (void)updateSelectedState:(BOOL)selected {
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:[self shadowAlphaWithSelected:selected]];
    shadow.shadowOffset = NSMakeSize(0, -5);
    shadow.shadowBlurRadius = 5;

    self.appNameContainer.backgroundColor = selected ? [NSColor alternateSelectedControlColor] : [NSColor clearColor];
    self.appName.textColor = selected ? [NSColor alternateSelectedControlTextColor] : [NSColor textColor];

    [NSAnimationContext beginGrouping];
    [NSAnimationContext currentContext].duration = 0.4;
    self.appCoverArt.superview.animator.shadow = shadow;
    self.appCoverArt.superview.animator.alphaValue = [self appCoverArtAlphaWithHovered:NO];
    [NSAnimationContext endGrouping];

    [self animateSelectedAndHoveredState];
}

- (void)setSelected:(BOOL)selected {
    BOOL previousState = self.selected;
    [super setSelected:selected];
    
    if (previousState != selected) {
        [self updateSelectedState:selected];
    }
}

- (void)mouseEntered:(NSEvent *)event {
    self.hovered = YES;
    [self animateSelectedAndHoveredState];
}

- (void)mouseExited:(NSEvent *)event {
    self.hovered = NO;
    [self animateSelectedAndHoveredState];
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
