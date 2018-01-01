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

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
}

- (void)updateTrackingAreas {
    if (self.trackingArea != nil) {
        [self removeTrackingArea:self.trackingArea];
    }

    int opts = (NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways);
    self.trackingArea = [ [NSTrackingArea alloc] initWithRect:[self bounds] options:opts owner:self userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}

//- (void)mouseEntered:(NSEvent *)event {
//    self.layer.transform = CATransform3DMakeScale(1.1, 1.1, 1);
//}
//
//- (void)mouseExited:(NSEvent *)event {
//    self.layer.transform = CATransform3DIdentity;
//}

- (void)menuWillOpen:(NSMenu *)menu {
    [self.delegate menuWillOpen:menu];
}

@end
