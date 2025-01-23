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

- (void)dealloc {
    @try {
        [_host removeObserver:self forKeyPath:@"pairState"];
        [_host removeObserver:self forKeyPath:@"state"];
    } @catch (NSException *exception) {
        NSLog(@"Observer not registered: %@", exception);
    }
}

- (void)setHost:(TemporaryHost *)host {
    if (_host != host) {
        // Remove old observers
        @try {
            [_host removeObserver:self forKeyPath:@"pairState"];
            [_host removeObserver:self forKeyPath:@"state"];
        } @catch (NSException *exception) {
            NSLog(@"Observer not registered: %@", exception);
        }

        // Assign the new host
        _host = host;

        if (_host) {
            // Add observers for the new host
            [_host addObserver:self forKeyPath:@"pairState" options:NSKeyValueObservingOptionNew context:nil];
            [_host addObserver:self forKeyPath:@"state" options:NSKeyValueObservingOptionNew context:nil];
        }

        [self updateHostState];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    if ((object == self.host) && ([keyPath isEqualToString:@"pairState"] || [keyPath isEqualToString:@"state"])) {
//        NSLog(@"Coofdy: %@ changed state", self.host.name);
        [self updateHostState];
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)prepareForReuse {
    [super prepareForReuse];
    
    // Remove observers for the old host
    @try {
        [_host removeObserver:self forKeyPath:@"pairState"];
        [_host removeObserver:self forKeyPath:@"state"];
    } @catch (NSException *exception) {
        NSLog(@"Observer not registered: %@", exception);
    }

    _host = nil;
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

- (void)updateHostState {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateHostState];
        });
        return;
    }

    NSColor *statusColor;
    NSString *statusText;

    switch (self.host.state) {
        case StateOnline:
            if (self.host.pairState == PairStateUnpaired) {
                statusColor = [NSColor systemOrangeColor];
                statusText = @"Online, but not paired";
            } else {
                statusColor = [NSColor systemGreenColor];
                statusText = @"Online, and paired";
            }
            break;
        case StateOffline:
            if (self.host.pairState == PairStateUnpaired) {
                statusColor = [NSColor systemGrayColor];
                statusText = @"Offline, and not paired";
            } else {
                statusColor = [NSColor systemRedColor];
                statusText = @"Offline, but paired";
            }
            break;
        case StateUnknown:
        default:
            statusColor = [NSColor systemGrayColor];
            statusText = @"Unknown";
            break;
    }

    // Update UI elements
    self.statusLightView.backgroundColor = statusColor;
    self.statusLabel.stringValue = statusText;
}

@end
