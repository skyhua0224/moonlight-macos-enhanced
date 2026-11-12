//
//  ContainerViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 23/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "ContainerViewController.h"
#import "AppsWorkspaceViewController.h"
#import "HostsViewController.h"
#import "MLLaunchTrace.h"
#import "NSWindow+Moonlight.h"
#import "Helpers.h"
#import "MoonlightEnhanced-Swift.h"

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
    
    MLLaunchTrace(@"container viewDidLoad (window content)");
    [ContainerViewController installZoomMenuItems];
    self.view.wantsLayer = YES;
    [self applyPageBackground];

    MLLaunchTrace(@"variant=%@ (stored: %@)", [MLDeckVariant current], [[NSUserDefaults standardUserDefaults] stringForKey:@"MLConceptVariant"] ?: @"none");
    NSViewController *hostsVC;
    if ([MLDeckVariant isSidebarVariant]) {
        // Not from the storyboard: the old page's scene (collection view, cells) is never instantiated.
        hostsVC = [[HostsViewController alloc] initWithNibName:nil bundle:nil];
    } else {
        hostsVC = [self.storyboard instantiateControllerWithIdentifier:@"hostsVC"];
    }
    [self addChildViewController:hostsVC];

    if ([MLDeckVariant isSidebarVariant]) {
        // The new home is the first thing the window draws: the old host list is only the logic behind it
        // (discovery, pairing, wake) and its view is never installed.
        MLLaunchTrace(@"sidebar home: host logic loaded, its view will NOT be installed");
        [(HostsViewController *)hostsVC deckInstallHomeIntoContainer:self];
    } else {
        MLLaunchTrace(@"classic: installing HostsViewController view (old host list)");
        [self.view addSubview:hostsVC.view];
        hostsVC.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        hostsVC.view.frame = self.view.bounds;
    }
    
    if (@available(macOS 13.0, *)) {
        self.view.window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleAutomatic;
    } else if (@available(macOS 11.0, *)) {
        self.view.window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleLine;
    }
}

/// The page colour behind everything, set before the first frame so nothing flashes white (or black).
- (void)applyPageBackground {
    [self.view.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self.view.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
    }];
}

- (void)viewWillLayout {
    [super viewWillLayout];
    [self applyPageBackground];   // follows light/dark changes
}

- (void)addChildViewController:(NSViewController *)childViewController {
    MLLaunchTrace(@"container addChildViewController %@", NSStringFromClass([childViewController class]));
    [super addChildViewController:childViewController];
}

- (void)transitionFromViewController:(NSViewController *)fromViewController toViewController:(NSViewController *)toViewController options:(NSViewControllerTransitionOptions)options completionHandler:(void (^)(void))completion {
    MLLaunchTrace(@"container TRANSITION %@ -> %@ options=%lu", NSStringFromClass([fromViewController class]), NSStringFromClass([toViewController class]), (unsigned long)options);
    [super transitionFromViewController:fromViewController toViewController:toViewController options:options completionHandler:completion];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    MLLaunchTrace(@"container viewWillAppear, content subviews: %@", [[self.view.subviews valueForKey:@"className"] componentsJoinedByString:@","]);
    [self applyPageBackground];
    self.view.window.backgroundColor = NSColor.windowBackgroundColor;

    NSWindow *window = [Helpers getMainWindow];
    NSToolbar *toolbar = window.toolbar;
    toolbar.delegate = self;

    if ([window moonlight_toolbarItemForIdentifier:MoonlightSidebarToggleToolbarItemIdentifier] == nil) {
        [toolbar insertItemWithItemIdentifier:MoonlightSidebarToggleToolbarItemIdentifier atIndex:1];
    }

    if (![toolbar.items.lastObject.itemIdentifier isEqualToString:MoonlightSearchToolbarItemIdentifier]) {
        [toolbar insertItemWithItemIdentifier:MoonlightSearchToolbarItemIdentifier atIndex:toolbar.items.count];
    }

    // The ＋ names this container as its target, so it works wherever focus is (it used to go to whichever
    // page held focus, and the old page that handled it is no longer on screen).
    NSToolbarItem *plusItem = [window moonlight_toolbarItemForAction:@selector(addHostButtonClicked:)];
    plusItem.target = self;
    if ([plusItem.view isKindOfClass:[NSButton class]]) {
        ((NSButton *)plusItem.view).target = self;
    }

    NSToolbarItem *sidebarItem = [window moonlight_toolbarItemForIdentifier:MoonlightSidebarToggleToolbarItemIdentifier];
    if (sidebarItem != nil) {
        sidebarItem.enabled = NO;
    }
}

- (void)viewDidAppear {
    [super viewDidAppear];

    [[MLHostPathSignals shared] noteAttention];
    NSWindow *window = self.view.window;
    AppsWorkspaceViewController *workspace = [self activeAppsWorkspaceViewControllerFrom:self];
    if (workspace != nil) {
        [window makeFirstResponder:workspace];
    }

    window.frameAutosaveName = @"Main Window";
    [window moonlight_centerWindowOnFirstRunWithSize:CGSizeMake(852, 566)];

    // The computer page carries the host's name in the page; its title stays hidden. Flipping the title to
    // visible here and back to hidden in AppsViewController on every return of the window (a stream ending)
    // redraws the titlebar: the grey, then white flash. Set it only when it differs.
    NSWindowTitleVisibility wanted = [MLDeckVariant titleHidden] ? NSWindowTitleHidden : NSWindowTitleVisible;
    if (window.titleVisibility != wanted) {
        [window setTitleVisibility:wanted];
    }
    MLLaunchTrace(@"container viewDidAppear: window back (visible=%d key=%d titleVisibility=%ld toolbarVisible=%d)",
                  window.isVisible, window.isKeyWindow, (long)window.titleVisibility, window.toolbar.isVisible);

    NSToolbarItem *preferencesToolbarItem = [window moonlight_toolbarItemForIdentifier:@"PreferencesToolbarItem"];
    NSButton *preferencesButton = (NSButton *)preferencesToolbarItem.view;
    
    if (preferencesButton != nil) {
        // the gear says 设置 in words as well
        preferencesButton.title = [[LanguageManager shared] localize:@"Settings"];
        preferencesButton.imagePosition = NSImageLeading;
        NSString *toolTipKey;
        if (@available(macOS 13.0, *)) {
            toolTipKey = @"Settings";
        } else {
            toolTipKey = @"Preferences";
        }
        preferencesButton.toolTip = [[LanguageManager shared] localize:toolTipKey];
    }
}

#pragma mark - View menu: card and page size

/// The View menu's size items for the computer page: 放大卡片 / 缩小卡片 (the existing Increase / Decrease Item
/// Size items, now ⌘= and ⌘−) and, added here, 实际大小 (⌘0), 放大页面 (⌘⌥=), 缩小页面 (⌘⌥−). They are sent to
/// the container, which is on the responder chain whichever part of the window has focus.
+ (void)installZoomMenuItems {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (![MLDeckVariant isComputerPage]) {
            return;
        }
        NSMenu *view = [NSApp.mainMenu itemWithTag:3000].submenu;
        if (view == nil) {
            return;
        }
        NSInteger anchor = -1;
        for (NSMenuItem *item in view.itemArray) {
            if (item.action == @selector(increaseItemSize:)) {
                item.title = [MLDeckZoom titleForAction:@"tiles+"];
                item.keyEquivalent = @"=";
                item.keyEquivalentModifierMask = NSEventModifierFlagCommand;
            } else if (item.action == @selector(decreaseItemSize:)) {
                item.title = [MLDeckZoom titleForAction:@"tiles-"];
                anchor = [view indexOfItem:item];
            }
        }
        if (anchor < 0) {
            return;
        }
        // 实际大小 / 放大页面 / 缩小页面 are gone: the page has no scale (it was a transform that blurred the cards)
        (void)anchor;
    });
}

- (IBAction)actualPageSize:(id)sender { [MLDeckZoom resetPage]; }
- (IBAction)increasePageSize:(id)sender { [MLDeckZoom stepPage:1]; }
- (IBAction)decreasePageSize:(id)sender { [MLDeckZoom stepPage:-1]; }
- (IBAction)increaseItemSize:(id)sender { [MLDeckZoom stepTiles:1]; }
- (IBAction)decreaseItemSize:(id)sender { [MLDeckZoom stepTiles:-1]; }

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(actualPageSize:) || item.action == @selector(increasePageSize:) || item.action == @selector(decreasePageSize:) ||
        item.action == @selector(increaseItemSize:) || item.action == @selector(decreaseItemSize:)) {
        return [MLDeckVariant isComputerPage] && self.view.window.isKeyWindow;
    }
    return YES;
}

/// The toolbar's ＋ is sent to the first responder, which in the sidebar home is some page of the workspace.
/// The container is on that chain and hands it to the host logic (the add-by-address sheet).
- (IBAction)addHostButtonClicked:(id)sender {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckHostCommand" object:nil userInfo:@{@"command": @"add"}];
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
    } else if ([itemIdentifier isEqualToString:@"CustomizeHomeToolbarItem"]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
        // A page-layout symbol and the word 主页, so it cannot be mistaken for the gear (设置) beside it.
        item.label = [[LanguageManager shared] localize:@"deck.homeShort"];
        item.paletteLabel = [[LanguageManager shared] localize:@"deck.customize"];
        NSString *tip = [[LanguageManager shared] localize:@"deck.customize"];
        item.toolTip = tip;
        NSImage *image = [NSImage imageWithSystemSymbolName:@"rectangle.3.group" accessibilityDescription:tip];
        if (@available(macOS 14.0, *)) {
            NSButton *button = [NSButton buttonWithImage:image target:[MLDeckHomeCustomizer shared] action:@selector(toggle:)];
            button.title = item.label;
            button.bezelStyle = NSBezelStyleTexturedRounded;
            button.imagePosition = NSImageLeading;
            button.toolTip = tip;
            item.view = button;
            [MLDeckHomeCustomizer shared].anchor = button;
        }
        return item;
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
