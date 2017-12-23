//
//  HostCell.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 22/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "HostCell.h"
#import "HostCellView.h"

@interface HostCell ()

@end

@implementation HostCell

- (void)viewDidLoad {
    [super viewDidLoad];
    
    [self updateSelectedState:NO];
}

- (void)updateSelectedState:(BOOL)selected {
    HostCellView *cellView = (HostCellView *)self.view;
    cellView.backgroundColor = selected ? [NSColor selectedTextBackgroundColor] : [NSColor colorWithWhite:0.9 alpha:1];
    [cellView setNeedsDisplay:YES];
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    
    [self updateSelectedState:selected];
}

- (void)mouseDown:(NSEvent *)theEvent {
    if ([theEvent clickCount] == 2) {
        [self.delegate openHost:self.host];
    } else {
        [super mouseDown:theEvent];
    }
}

@end
