//
//  HostCellView.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 22/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "HostCellView.h"

@implementation HostCellView

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    
    [[NSColor colorWithWhite:0.9 alpha:1] setFill];
    NSRectFill(dirtyRect);
}

@end
