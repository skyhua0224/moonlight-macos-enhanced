//
//  ImageFader.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 25/1/21.
//  Copyright © 2021 Moonlight Game Streaming Project. All rights reserved.
//

#import "ImageFader.h"

@implementation ImageFader

+ (void)transitionImageViewWithOldImageView:(NSImageView *)oldImageView newImageViewBlock:(NSImageView *(^)(void))newImageViewBlock duration:(NSTimeInterval)duration image:(NSImage *)image {
    NSImageView *newImageView = newImageViewBlock();
    newImageView.image = image;
    
    NSView *containerView = oldImageView.superview;
    [containerView addSubview:newImageView positioned:NSWindowAbove relativeTo:oldImageView];
    
    newImageView.translatesAutoresizingMaskIntoConstraints = NO;
    [newImageView.topAnchor constraintEqualToAnchor:containerView.topAnchor].active = YES;
    [newImageView.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor].active = YES;
    [newImageView.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor].active = YES;
    [newImageView.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor].active = YES;

    newImageView.alphaValue = 0;
    oldImageView.alphaValue = 1;
    
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
        context.duration = duration;
        
        [newImageView animator].alphaValue = 1;
        [oldImageView animator].alphaValue = 0;
    } completionHandler:^{
        [oldImageView removeFromSuperview];
    }];
}

@end
