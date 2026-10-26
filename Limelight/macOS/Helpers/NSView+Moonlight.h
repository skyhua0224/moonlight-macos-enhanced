//
//  NSView+Moonlight.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 8/1/2022.
//  Copyright © 2022 Moonlight Game Streaming Project. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@interface NSView (Moonlight)
@property (nonatomic, strong) NSColor *backgroundColor;

- (void)smoothRoundCornersWithCornerRadius:(CGFloat)cornerRadius;

/// Fades the view's opacity with a Core Animation animation, which the render server runs at
/// the display's refresh rate (up to 120 Hz on ProMotion) whatever the main thread is doing.
/// Starts from what is on screen, so a fade can reverse one under way. The completion runs on
/// the main thread when the fade ends.
- (void)moonlight_fadeToAlpha:(CGFloat)alpha duration:(NSTimeInterval)duration completion:(void (^)(void))completion;

@end
