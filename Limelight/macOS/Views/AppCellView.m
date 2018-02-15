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
@property (nonatomic) BOOL currentlyHovered;

@end

@implementation AppCellView

- (void)createTrackingArea {
    int opts = (NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways);
    self.trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds options:opts owner:self userInfo:nil];
    [self addTrackingArea:self.trackingArea];
    
    NSPoint mouseLocation = self.window.mouseLocationOutsideOfEventStream;
    mouseLocation = [self convertPoint:mouseLocation fromView:nil];
    
    if (NSPointInRect(mouseLocation, self.bounds)) {
        if (!self.currentlyHovered) {
            [self mouseEntered:self.window.currentEvent];
        }
    } else {
        if (self.currentlyHovered) {
            [self mouseExited:self.window.currentEvent];
        }
    }
}

- (void)updateTrackingAreas {
    [self removeTrackingArea:self.trackingArea];
    [self createTrackingArea];
    [super updateTrackingAreas];
}

- (void)mouseEntered:(NSEvent *)event {
    self.currentlyHovered = YES;
    [super mouseEntered:event];
}

- (void)mouseExited:(NSEvent *)event {
    self.currentlyHovered = NO;
    [super mouseExited:event];
}

- (void)menuWillOpen:(NSMenu *)menu {
    [self.delegate menuWillOpen:menu];
}

@end
