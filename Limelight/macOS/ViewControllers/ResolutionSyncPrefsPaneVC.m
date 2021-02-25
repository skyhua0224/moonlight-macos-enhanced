//
//  ResolutionSyncPrefsPaneVC.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 25/2/21.
//  Copyright © 2021 Moonlight Game Streaming Project. All rights reserved.
//

#import "ResolutionSyncPrefsPaneVC.h"

#import "MASPreferences.h"

@interface ResolutionSyncPrefsPaneVC () <MASPreferencesViewController>

@end

@implementation ResolutionSyncPrefsPaneVC

- (id)init {
    return [super initWithNibName:@"ResolutionSyncPrefsPaneView" bundle:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do view setup here.
}


#pragma mark - MASPreferencesViewController

- (NSString *)viewIdentifier {
    return @"resolutionSyncPrefs";
}

- (NSImage *)toolbarItemImage {
    if (@available(macOS 11.0, *)) {
        return [NSImage imageWithSystemSymbolName:@"network" accessibilityDescription:nil];
    } else {
        return [NSImage imageNamed:NSImageNameNetwork];
    }
}

- (NSString *)toolbarItemLabel {
    return @"Resolution Sync";
}

@end
