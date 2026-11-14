//
//  HostCellView.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 4/11/19.
//  Copyright © 2019 Moonlight Game Streaming Project. All rights reserved.
//

#import "HostCellView.h"
#import "MLTouchMenuSupport.h"

@implementation HostCellView

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window != nil) [MLTouchMenuSupport installLongPressMenuOnView:self];
}

- (void)menuWillOpen:(NSMenu *)menu {
    [self.delegate menuWillOpen:menu];
}

@end
