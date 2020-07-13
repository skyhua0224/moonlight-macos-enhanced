//
//  AppCellView.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 30/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "AppCellView.h"

@interface AppCellView () <NSMenuDelegate>
@property (nonatomic, strong) NSTrackingArea *trackingArea;

@end

@implementation AppCellView

- (void)createTrackingArea {
    int opts = (NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways);
    self.trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds options:opts owner:self userInfo:nil];
    [self addTrackingArea:self.trackingArea];
    
    NSPoint mouseLocation = self.window.mouseLocationOutsideOfEventStream;
    mouseLocation = [self convertPoint:mouseLocation fromView:nil];
}

- (void)updateTrackingAreas {
    [self removeTrackingArea:self.trackingArea];
    [self createTrackingArea];
    [super updateTrackingAreas];
}

- (void)menuWillOpen:(NSMenu *)menu {
    [self.delegate menuWillOpen:menu];
}

@end
