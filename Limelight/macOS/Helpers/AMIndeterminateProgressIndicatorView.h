//
//  AMIndeterminateProgressIndicatorCell.h
//  IPICellTest
//
//  Created by Andreas on 23.01.07.
//  Copyright 2007 Andreas Mayer. All rights reserved.
//

#import <Cocoa/Cocoa.h>


@interface AMIndeterminateProgressIndicatorView : NSView
@property (nonatomic) NSTimeInterval animationDelay;
@property (nonatomic) BOOL displayedWhenStopped;
@property (nonatomic) BOOL spinning;
@property (nonatomic, strong) NSColor *color;

- (void)startAnimation;
- (void)stopAnimation;

@end
