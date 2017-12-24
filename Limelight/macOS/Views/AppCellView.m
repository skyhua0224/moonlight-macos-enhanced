//
//  AppCellView.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 24/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "AppCellView.h"

@implementation AppCellView

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    
    [self.backgroundColor setFill];
    NSRectFill(dirtyRect);
}

@end
