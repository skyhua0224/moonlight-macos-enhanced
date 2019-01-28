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
    
    NSShadow *shadow = [[NSShadow alloc] init];
    [shadow setShadowColor:[NSColor colorWithWhite:0 alpha:[self shadowAlphaWithSelected:NO]]];
    [shadow setShadowOffset:NSMakeSize(0, -4)];
    [shadow setShadowBlurRadius:4];
    self.appCoverArt.superview.shadow = shadow;

    self.appCoverArt.wantsLayer = YES;
    self.appCoverArt.layer.masksToBounds = YES;
    self.appCoverArt.layer.cornerRadius = 6;
    
    self.resumeIcon.alphaValue = 0.9;
    
    ((AppCellView *)self.view).delegate = self;
    
    [self updateSelectedState:NO];
}

- (CATransform3D)translationTransform {
    return CATransform3DMakeTranslation(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 0);
}

- (CGFloat)scaleForSelected:(BOOL)selected hovered:(BOOL)hovered {
    CGFloat scale = 1;
    if (selected) {
        scale *= 1.2;
    }
    if (hovered) {
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
    if (selected) {
        return [NSApplication moonlight_isDarkAppearance] ? 0.75 : 0.64;
    } else {
        return [NSApplication moonlight_isDarkAppearance] ? 0.7 : 0.55;
    }
}

- (CGFloat)appCoverArtAlphaWithHovered:(BOOL)hovered {
    if (self.selected) {
        return 1;
    } else {
        if (hovered) {
            return [NSApplication moonlight_isDarkAppearance] ? 0.9 : 0.9;
        } else {
            return [NSApplication moonlight_isDarkAppearance] ? 0.65 : 0.75;
        }
    }
}

- (void)updateSelectedState:(BOOL)selected {
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:[self shadowAlphaWithSelected:selected]];
    shadow.shadowOffset = NSMakeSize(0, selected ? -7 : -4);
    shadow.shadowBlurRadius = 4;

    [NSAnimationContext beginGrouping];
    [NSAnimationContext currentContext].duration = 0.8;
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
