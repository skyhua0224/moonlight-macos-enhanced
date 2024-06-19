//
//  HostCell.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 22/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "HostCell.h"
#import "BackgroundColorView.h"
#import "NSApplication+Moonlight.h"
#import "HostCellView.h"
#import "NSView+Moonlight.h"

@interface HostCell () <NSMenuDelegate>
@property (weak) IBOutlet BackgroundColorView *imageContainer;
@property (weak) IBOutlet NSView *labelContainer;

@end

@implementation HostCell

- (void)viewDidLoad {
    [super viewDidLoad];
    
    [self startUpdateLoop];
    
    self.imageContainer.backgroundColorName = @"HostSelectionBackgroundColor";
    
    self.imageContainer.wantsLayer = YES;
    self.imageContainer.layer.masksToBounds = YES;
    self.imageContainer.layer.cornerRadius = 10;
    self.labelContainer.wantsLayer = YES;
    self.labelContainer.layer.masksToBounds = YES;
    self.labelContainer.layer.cornerRadius = 4;
    
    self.statusLightView.wantsLayer = YES;
    self.statusLightView.layer.masksToBounds = YES;
    self.statusLightView.layer.cornerRadius = self.statusLightView.bounds.size.width / 2;
    self.statusLightView.backgroundColor = [NSColor systemGrayColor];
    self.statusLightView.alphaValue = 0.66;
    
    ((HostCellView *)self.view).delegate = self;
    
    [self updateSelectedState:NO];
}

- (void)updateSelectedState:(BOOL)selected {
    self.imageContainer.clear = !selected;
    
    self.labelContainer.backgroundColor = selected ? [NSColor selectedContentBackgroundColor] : [NSColor clearColor];
    self.hostName.textColor = selected ? [NSColor alternateSelectedControlTextColor] : [NSColor textColor];
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

- (void)menuWillOpen:(NSMenu *)menu {
    [self.delegate didOpenContextMenu:menu forHost:self.host];
}


#pragma mark - Host Updating

- (void)startUpdateLoop {
    [self performSelector:@selector(updateLoop) withObject:self afterDelay:2];
}

- (void)updateLoop {
    [self updateHostState];
    
    if (self != nil) {
        [self startUpdateLoop];
    }
}

- (void)updateHostState {
    NSColor *statusColor;
    NSString *toolTipText;
    
    switch (self.host.state) {
        case StateOnline:
            if (self.host.pairState == PairStateUnpaired) {
                statusColor = [NSColor systemOrangeColor];
                self.statusLabel.stringValue = @"Online, but not paired";
            } else {
                statusColor = [NSColor systemGreenColor];
                self.statusLabel.stringValue = @"Online, and paired";
            }
            break;
        case StateOffline:
            if (self.host.pairState == PairStateUnpaired) {
                statusColor = [NSColor systemGrayColor];
                self.statusLabel.stringValue = @"Offline, and not paired";
            } else {
                statusColor = [NSColor systemRedColor];
                self.statusLabel.stringValue = @"Offline, but paired";
            }
            break;
        case StateUnknown:
            statusColor = [NSColor systemGrayColor];
            toolTipText = @"Unknown";
            break;
    }

    
    self.statusLightView.backgroundColor = statusColor;
    self.statusLightView.toolTip = toolTipText;
}

@end
