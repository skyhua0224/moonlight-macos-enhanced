//
//  ContainerViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 23/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "ContainerViewController.h"
#import "NSWindow+Moonlight.h"
#import "Helpers.h"

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
    
    NSToolbar *toolbar = [Helpers getMainWindow].toolbar;
    toolbar.delegate = self;
    
    NSString *searchToolbarItemIdentifier = @"NewSearchToolbarItem";
    
    if (![toolbar.items.lastObject.itemIdentifier isEqualToString:searchToolbarItemIdentifier]) {
        [toolbar insertItemWithItemIdentifier:searchToolbarItemIdentifier atIndex:toolbar.items.count];
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
    
    if (@available(macOS 13.0, *)) {
        preferencesButton.toolTip = @"Settings";
    } else {
        preferencesButton.toolTip = @"Preferences";
    }
}

- (void)setTitle:(NSString *)title {
    self.view.window.title = title;
}


- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier willBeInsertedIntoToolbar:(BOOL)flag {
    if ([itemIdentifier isEqualToString:@"NewSearchToolbarItem"]) {
        NSSearchToolbarItem *newSearchItem = [[NSSearchToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
        newSearchItem.searchField = [[CustomSearchField alloc] init];
        return newSearchItem;
    } else {
        return nil;
    }
}

@end
