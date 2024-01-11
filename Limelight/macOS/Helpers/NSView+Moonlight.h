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

@end
