//
//  ContainerViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 23/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "ContainerViewController.h"
#import "NSWindow+Moonlight.h"
#import "BackgroundColorView.h"

@interface ContainerViewController () <NSToolbarDelegate>
@property (weak) IBOutlet BackgroundColorView *titleContainer;

@end

@implementation ContainerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.wantsLayer = YES;
    
    NSViewController *hostsVC = [self.storyboard instantiateControllerWithIdentifier:@"hostsVC"];
    [self addChildViewController:hostsVC];

    if (@available(macOS 11.0, *)) {
        [self.view addSubview:hostsVC.view];
    } else {
        [self.view addSubview:hostsVC.view positioned:NSWindowBelow relativeTo:self.titleContainer];
    }
    
    hostsVC.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    hostsVC.view.frame = self.view.bounds;
    
    if (@available(macOS 11.0, *)) {
    } else {
        self.titleContainer.backgroundColor = [NSColor selectedTextBackgroundColor];
        self.titleContainer.wantsLayer = YES;
        self.titleContainer.layer.masksToBounds = YES;
        self.titleContainer.layer.cornerRadius = self.titleContainer.frame.size.height / 2;
    }
}

- (void)viewDidAppear {
    [super viewDidAppear];

    NSWindow *window = self.view.window;

    window.frameAutosaveName = @"Main Window";
    [window moonlight_centerWindowOnFirstRun];

    if (@available(macOS 11.0, *)) {
        [window setTitleVisibility:NSWindowTitleVisible];
    }

    NSToolbar *toolbar = window.toolbar;
    toolbar.delegate = self;
    
    if (@available(macOS 11.0, *)) {
        NSToolbarItem *preferencesToolbarItem = [window moonlight_toolbarItemForIdentifier:@"PreferencesToolbarItem"];
        preferencesToolbarItem.image = [NSImage imageWithSystemSymbolName:@"gear" accessibilityDescription:nil];
    }
}

- (void)setTitle:(NSString *)title {
    if (@available(macOS 11.0, *)) {
    } else {
        ((NSTextField *)self.titleContainer.subviews.firstObject).stringValue = title;
    }
    self.view.window.title = title;
}

@end
