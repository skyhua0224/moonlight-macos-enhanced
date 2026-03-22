//
//  ContainerViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 23/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "ContainerViewController.h"
#import "AppsWorkspaceViewController.h"
#import "NSWindow+Moonlight.h"
#import "Helpers.h"
#import "Moonlight-Swift.h"

@interface CustomSearchField : NSSearchField
@end

@implementation CustomSearchField

- (void)cancelOperation:(id)sender {
    [self makeVCFirstResponder];
}

- (void)textDidEndEditing:(NSNotification *)notification {
    [super textDidEndEditing:notification];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self makeVCFirstResponder];
    });
}

- (void)makeVCFirstResponder {
    NSArray<NSViewController *> *vcs = NSApplication.sharedApplication.mainWindow.contentViewController.childViewControllers;
    for (NSViewController *vc in vcs) {
        [self.window makeFirstResponder:vc];
    }
}

@end


@interface ContainerViewController () <NSToolbarDelegate>
@end

@implementation ContainerViewController

static NSString * const MoonlightSidebarToggleToolbarItemIdentifier = @"SidebarToggleToolbarItem";
static NSString * const MoonlightSearchToolbarItemIdentifier = @"NewSearchToolbarItem";

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.wantsLayer = YES;
    
    NSViewController *hostsVC = [self.storyboard instantiateControllerWithIdentifier:@"hostsVC"];
    [self addChildViewController:hostsVC];

    [self.view addSubview:hostsVC.view];
    
    hostsVC.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    hostsVC.view.frame = self.view.bounds;
    
    if (@available(macOS 13.0, *)) {
        self.view.window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleAutomatic;
    } else if (@available(macOS 11.0, *)) {
        self.view.window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleLine;
    }
}

- (void)viewWillAppear {
    [super viewWillAppear];
    
    NSWindow *window = [Helpers getMainWindow];
    NSToolbar *toolbar = window.toolbar;
    toolbar.delegate = self;

    if ([window moonlight_toolbarItemForIdentifier:MoonlightSidebarToggleToolbarItemIdentifier] == nil) {
        [toolbar insertItemWithItemIdentifier:MoonlightSidebarToggleToolbarItemIdentifier atIndex:1];
    }

    if (![toolbar.items.lastObject.itemIdentifier isEqualToString:MoonlightSearchToolbarItemIdentifier]) {
        [toolbar insertItemWithItemIdentifier:MoonlightSearchToolbarItemIdentifier atIndex:toolbar.items.count];
    }

    NSToolbarItem *sidebarItem = [window moonlight_toolbarItemForIdentifier:MoonlightSidebarToggleToolbarItemIdentifier];
    if (sidebarItem != nil) {
        sidebarItem.enabled = NO;
    }
}

- (void)viewDidAppear {
    [super viewDidAppear];

    NSWindow *window = self.view.window;

    window.frameAutosaveName = @"Main Window";
    [window moonlight_centerWindowOnFirstRunWithSize:CGSizeMake(852, 566)];

    [window setTitleVisibility:NSWindowTitleVisible];

    NSToolbarItem *preferencesToolbarItem = [window moonlight_toolbarItemForIdentifier:@"PreferencesToolbarItem"];
    NSButton *preferencesButton = (NSButton *)preferencesToolbarItem.view;
    
    if (preferencesButton != nil) {
        NSString *toolTipKey;
        if (@available(macOS 13.0, *)) {
            toolTipKey = @"Settings";
        } else {
            toolTipKey = @"Preferences";
        }
        preferencesButton.toolTip = [[LanguageManager shared] localize:toolTipKey];
    }
}

- (void)setTitle:(NSString *)title {
    self.view.window.title = title;
}


- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier willBeInsertedIntoToolbar:(BOOL)flag {
    if ([itemIdentifier isEqualToString:MoonlightSidebarToggleToolbarItemIdentifier]) {
        NSToolbarItem *sidebarItem = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
        sidebarItem.label = @"Toggle Sidebar";
        sidebarItem.paletteLabel = @"Toggle Sidebar";
        sidebarItem.toolTip = @"Toggle Sidebar";
        sidebarItem.target = self;
        sidebarItem.action = @selector(toggleSidebar:);
        sidebarItem.enabled = NO;
        if (@available(macOS 11.0, *)) {
            sidebarItem.navigational = YES;
        }

        NSImage *sidebarImage = [NSImage imageWithSystemSymbolName:@"sidebar.leading" accessibilityDescription:nil];
        if (sidebarImage == nil) {
            sidebarImage = [NSImage imageWithSystemSymbolName:@"sidebar.left" accessibilityDescription:nil];
        }

        NSButton *button = [NSButton buttonWithImage:sidebarImage target:self action:@selector(toggleSidebar:)];
        button.bezelStyle = NSBezelStyleTexturedRounded;
        button.imagePosition = NSImageOnly;
        button.toolTip = [[LanguageManager shared] localize:@"Toggle Sidebar"];
        sidebarItem.view = button;

        return sidebarItem;
    } else if ([itemIdentifier isEqualToString:MoonlightSearchToolbarItemIdentifier]) {
        NSSearchToolbarItem *newSearchItem = [[NSSearchToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
        newSearchItem.searchField = [[CustomSearchField alloc] init];
        return newSearchItem;
    } else {
        return nil;
    }
}

- (AppsWorkspaceViewController *)activeAppsWorkspaceViewControllerFrom:(NSViewController *)viewController {
    if (viewController == nil) {
        return nil;
    }

    if ([viewController isKindOfClass:[AppsWorkspaceViewController class]]) {
        return (AppsWorkspaceViewController *)viewController;
    }

    for (NSViewController *child in viewController.childViewControllers.reverseObjectEnumerator) {
        AppsWorkspaceViewController *workspace = [self activeAppsWorkspaceViewControllerFrom:child];
        if (workspace != nil) {
            return workspace;
        }
    }

    return nil;
}

- (IBAction)toggleSidebar:(id)sender {
    AppsWorkspaceViewController *workspace = [self activeAppsWorkspaceViewControllerFrom:self];
    if (workspace != nil) {
        [workspace toggleSidebar:sender];
    }
}

@end
