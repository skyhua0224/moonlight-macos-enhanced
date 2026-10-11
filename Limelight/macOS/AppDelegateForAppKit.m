//
//  AppDelegateForAppKit.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 10/2/18.
//  Copyright © 2018 Moonlight Stream. All rights reserved.
//

#import "AppDelegateForAppKit.h"
#import "DatabaseSingleton.h"
#import "AboutViewController.h"
#import "NSWindow+Moonlight.h"
#import "NSResponder+Moonlight.h"
#import "ControllerNavigation.h"

#import "MASPreferencesWindowController.h"
#import "GeneralPrefsPaneVC.h"

#import "AppsViewController.h"
#import "AppsWorkspaceViewController.h"
#import "TemporaryHost.h"
#import "Logger.h"
#import "MLAudioBitstreamOutput.h"
#import "StreamingSessionManager.h"
#import "MoonlightEnhanced-Swift.h"
#import <objc/runtime.h>

typedef enum : NSUInteger {
    SystemTheme,
    LightTheme,
    DarkTheme,
} Theme;

@interface AppDelegateForAppKit () <NSApplicationDelegate, NSWindowDelegate>
@property (nonatomic, strong) NSWindowController *preferencesWC;
@property (nonatomic) BOOL settingsPrewarmDone;
@property (nonatomic, strong) NSWindowController *aboutWC;
@property (nonatomic, strong) NSWindowController *welcomePermissionsWC;
@property (nonatomic, strong) ControllerNavigation *controllerNavigation;
@property (weak) IBOutlet NSMenuItem *themeMenuItem;
@end

@implementation AppDelegateForAppKit

static const void *MoonlightOriginalMenuItemTitleKey = &MoonlightOriginalMenuItemTitleKey;
static const void *MoonlightOriginalMenuTitleKey = &MoonlightOriginalMenuTitleKey;
static const void *MoonlightOriginalToolbarLabelKey = &MoonlightOriginalToolbarLabelKey;
static const void *MoonlightOriginalToolbarPaletteLabelKey = &MoonlightOriginalToolbarPaletteLabelKey;
static const void *MoonlightOriginalToolbarToolTipKey = &MoonlightOriginalToolbarToolTipKey;

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSString *)hostUUIDFromViewControllerTree:(NSViewController *)viewController {
    if (viewController == nil) {
        return nil;
    }

    if ([viewController isKindOfClass:[AppsWorkspaceViewController class]]) {
        NSString *hostUUID = ((AppsWorkspaceViewController *)viewController).currentHostUUID;
        if (hostUUID.length > 0) {
            return hostUUID;
        }
    }

    if ([viewController isKindOfClass:[AppsViewController class]]) {
        NSString *hostUUID = ((AppsViewController *)viewController).host.uuid;
        if (hostUUID.length > 0) {
            return hostUUID;
        }
    }

    for (NSViewController *child in viewController.childViewControllers) {
        NSString *hostUUID = [self hostUUIDFromViewControllerTree:child];
        if (hostUUID.length > 0) {
            return hostUUID;
        }
    }

    return nil;
}

// Opt in explicitly to secure restorable state to avoid the system warning on some macOS versions.
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return YES;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    [self createMainWindow];

    [SparkleUpdateManager startIfConfigured];
    [self installUpdateMenuItem];

    // A crash during Dolby passthrough can leave the sound device in an encoded
    // format; put it back. Switching a format can take seconds, so not on the main thread.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [MLAudioBitstreamOutput restoreLeftoverDeviceFormatIfNeeded];
    });

    __weak typeof(self) prewarmSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [prewarmSelf prewarmSettingsWhenQuiet];
    });

    
    self.controllerNavigation = [[ControllerNavigation alloc] init];
    [self refreshLocalizedChrome];
    [self showWelcomePermissionsIfNeeded];
}

- (void)installUpdateMenuItem {
    NSMenu *appMenu = NSApp.mainMenu.itemArray.firstObject.submenu;
    if (appMenu == nil || [appMenu indexOfItemWithTarget:self andAction:@selector(checkForUpdates:)] >= 0) {
        return;
    }
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Check for Updates…"
                                               action:@selector(checkForUpdates:)
                                        keyEquivalent:@""];
    item.target = self;
    NSInteger aboutIndex = [appMenu indexOfItemWithTarget:self andAction:@selector(showAbout:)];
    [appMenu insertItem:item atIndex:aboutIndex >= 0 ? aboutIndex + 1 : 0];
}

- (IBAction)checkForUpdates:(id)sender {
    [SparkleUpdateManager checkForUpdatesFromMenu];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(checkForUpdates:)) {
        return [SparkleUpdateManager canCheckForUpdates];
    }
    return YES;
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    [SettingsClass applyLoggerSettings];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(languageChanged:) name:@"LanguageChanged" object:nil];
    [[LanguageManager shared] applyAppLanguage];

    [self applyThemePreference:[self currentThemePreference]];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    if (!flag) {
        [self createMainWindow];

        return YES;
    }
    
    return NO;
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    [[DatabaseSingleton shared] saveContext];
    // Lines are written by a background queue; make sure the last ones reach the files.
    LoggerFlush();
}

- (void)createMainWindow {
    NSWindowController *mainWC = [NSStoryboard.mainStoryboard instantiateControllerWithIdentifier:@"MainWindowController"];
    mainWC.window.frameAutosaveName = @"Main Window";
    [mainWC.window setMinSize:NSMakeSize(650, 350)];
    
    [mainWC showWindow:self];
    [mainWC.window makeKeyAndOrderFront:nil];
    [self localizeToolbarForWindow:mainWC.window];
}

- (void)showWelcomePermissionsIfNeeded {
    if (![WelcomePermissionsWindowObjCBridge shouldShowWelcomeWindow]) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.welcomePermissionsWC != nil) {
            return;
        }

        NSWindow *parentWindow = NSApplication.sharedApplication.mainWindow;
        if (parentWindow == nil) {
            parentWindow = NSApplication.sharedApplication.windows.firstObject;
        }
        if (parentWindow == nil) {
            return;
        }

        self.welcomePermissionsWC = [WelcomePermissionsWindowObjCBridge makeWelcomeWindow];
        self.welcomePermissionsWC.window.delegate = self;
        self.welcomePermissionsWC.window.frameAutosaveName = @"Welcome Permissions Window";
        [parentWindow beginSheet:self.welcomePermissionsWC.window completionHandler:^(__unused NSModalResponse returnCode) {
            [WelcomePermissionsWindowObjCBridge markWelcomeWindowShown];
            self.welcomePermissionsWC = nil;
        }];
    });
}

// The settings window is built once and kept: building it lays the whole settings tree out,
// which took more than a second every time it was opened. Shown again, it selects the host's
// profile and reads it afresh, since the stream and the control center write settings too.
- (NSWindowController *)preferencesWCWithHostId:(NSString *)hostId {
    if (_preferencesWC == nil) {
        _preferencesWC = [SettingsWindowObjCBridge makeSettingsWindowWithHostId:hostId];
        _preferencesWC.window.delegate = self;
    }
    // Also for a window that was just made: it may have been made ahead, for no host.
    [SettingsWindowObjCBridge prepareSettingsWindowForShowingWithHostId:hostId];
    return _preferencesWC;
}

// Building the settings window takes around two seconds of the main thread the first time, and
// the equalizer's file dialog one more, and every settings page some more when it is first
// shown. The window and the dialog are made ahead in quiet moments (nobody at the keyboard or
// mouse, or the app in the background; never during a stream), a piece per moment, so that
// the first click on Settings shows what already exists. The other pages are made the same
// way, but only while the window is open.
- (void)prewarmSettingsWhenQuiet {
    BOOL builtSomething = NO;

    const CFTimeInterval idle = CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState, kCGAnyInputEventType);
    const BOOL quiet = (idle >= 2.0 || !NSApp.isActive) &&
        [StreamingSessionManager shared].state == StreamingStateIdle &&
        NSApp.modalWindow == nil;
    if ([StreamingSessionManager shared].state != StreamingStateIdle) {
        [SettingsWindowObjCBridge releaseSettingsPagesNotShowing];
    }
    if (quiet) {
        // One piece of work per quiet moment: the window with the page it opens on, the file
        // dialog, and, while the window is open, the other pages one by one.
        if (_preferencesWC == nil) {
            _preferencesWC = [SettingsWindowObjCBridge makeSettingsWindowWithHostId:nil];
            _preferencesWC.window.delegate = self;
            [_preferencesWC.window layoutIfNeeded];
            [SettingsWindowObjCBridge settingsWindowVisibilityChanged:NO];
            builtSomething = YES;
        } else if (!self.settingsPrewarmDone) {
            [SettingsWindowObjCBridge prewarmImportPanel];
            self.settingsPrewarmDone = YES;
            builtSomething = YES;
        } else if (_preferencesWC.window.isVisible && [SettingsWindowObjCBridge prewarmNextSettingsPage]) {
            builtSomething = YES;
        }
    }

    // This keeps looking: pages are released when settings are edited, and when the window
    // closes, and built again here. A look that finds nothing to do costs nothing to speak of.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((builtSomething ? 0.4 : 2.0) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf prewarmSettingsWhenQuiet];
    });
}

- (void)showPreferencesWindowForHost:(NSString *)hostId {
    const BOOL firstTime = _preferencesWC == nil;
    NSWindowController *prefsWC = [self preferencesWCWithHostId:hostId];
    if (firstTime || !prefsWC.window.isVisible) {
        [prefsWC.window setContentSize:NSMakeSize(960.0, 680.0)];
        [prefsWC.window setMinSize:NSMakeSize(820.0, 560.0)];
        [prefsWC.window center];
    }
    [SettingsWindowObjCBridge settingsWindowVisibilityChanged:YES];
    [prefsWC showWindow:nil];
    [prefsWC.window makeKeyAndOrderFront:nil];
}

- (void)showPreferencesForHost:(NSString *)hostId {
    [self showPreferencesWindowForHost:hostId];
}

- (IBAction)showPreferences:(id)sender {
    NSViewController *contentVC = NSApplication.sharedApplication.mainWindow.contentViewController;
    [self showPreferencesWindowForHost:[self hostUUIDFromViewControllerTree:contentVC]];
}

- (IBAction)showAbout:(id)sender {
    if (self.aboutWC == nil) {
        self.aboutWC = [[NSWindowController alloc] initWithWindowNibName:@"AboutWindow"];
        self.aboutWC.contentViewController = [[AboutViewController alloc] initWithNibName:@"AboutView" bundle:nil];
    }

    self.aboutWC.window.frameAutosaveName = @"About Window";
    [self.aboutWC.window moonlight_centerWindowOnFirstRunWithSize:CGSizeZero];
    
    [self.aboutWC showWindow:nil];
    [self.aboutWC.window makeKeyAndOrderFront:nil];
}

- (IBAction)filterList:(id)sender {
    NSWindow *window = NSApplication.sharedApplication.mainWindow;
    [window makeFirstResponder:[window moonlight_searchFieldInToolbar]];
}

- (IBAction)setSystemTheme:(id)sender {
    [self changeTheme:SystemTheme withMenuItem:((NSMenuItem *)sender)];
}

- (IBAction)setLightTheme:(id)sender {
    [self changeTheme:LightTheme withMenuItem:((NSMenuItem *)sender)];
}

- (IBAction)setDarkTheme:(id)sender {
    [self changeTheme:DarkTheme withMenuItem:((NSMenuItem *)sender)];
}

- (NSInteger)currentThemePreference {
    return [[NSUserDefaults standardUserDefaults] integerForKey:@"theme"];
}

- (void)applyThemePreference:(NSInteger)theme {
    Theme resolvedTheme = (theme >= SystemTheme && theme <= DarkTheme) ? (Theme)theme : SystemTheme;
    [self changeTheme:resolvedTheme withMenuItem:[self menuItemForTheme:resolvedTheme forMenu:self.themeMenuItem.submenu]];
}

- (NSMenuItem *)menuItemForTheme:(Theme)theme forMenu:(NSMenu *)menu {
    static NSUInteger menuIndexes[] = {0, 2, 3};
    if (menu == nil || theme > DarkTheme) {
        return nil;
    }
    return menu.itemArray[menuIndexes[theme]];
}

- (void)changeTheme:(Theme)theme withMenuItem:(NSMenuItem *)menuItem {
    NSMenu *menu = menuItem.menu ?: self.themeMenuItem.submenu;
    NSMenuItem *resolvedMenuItem = menuItem ?: [self menuItemForTheme:theme forMenu:menu];

    resolvedMenuItem.state = NSControlStateValueOn;
    for (NSMenuItem *item in menu.itemArray) {
        if (resolvedMenuItem != item) {
            item.state = NSControlStateValueOff;
        }
    }
    
    [[NSUserDefaults standardUserDefaults] setInteger:theme forKey:@"theme"];
    
    NSApplication *app = [NSApplication sharedApplication];
    switch (theme) {
        case SystemTheme:
            app.appearance = nil;
            break;
        case LightTheme:
            app.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
            break;
        case DarkTheme:
            app.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
            break;
    }
}

- (void)languageChanged:(NSNotification *)notification {
    [self refreshLocalizedChrome];
}

- (void)refreshLocalizedChrome {
    [self localizeMenu:[NSApplication sharedApplication].mainMenu];

    for (NSWindow *window in NSApplication.sharedApplication.windows) {
        [self localizeToolbarForWindow:window];
    }
}

- (NSString *)localizedChromeString:(NSString *)key {
    if (key.length == 0) {
        return key;
    }
    return [[LanguageManager shared] localize:key];
}

- (NSString *)storedStringForObject:(id)object associationKey:(const void *)associationKey currentValue:(NSString *)currentValue {
    NSString *storedValue = objc_getAssociatedObject(object, associationKey);
    if (storedValue == nil && currentValue.length > 0) {
        storedValue = [currentValue copy];
        objc_setAssociatedObject(object, associationKey, storedValue, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return storedValue ?: currentValue ?: @"";
}

- (void)localizeMenu:(NSMenu *)menu {
    if (menu == nil) {
        return;
    }

    NSString *originalMenuTitle = [self storedStringForObject:menu associationKey:MoonlightOriginalMenuTitleKey currentValue:menu.title];
    if (originalMenuTitle.length > 0) {
        menu.title = [self localizedChromeString:originalMenuTitle];
    }

    for (NSMenuItem *item in menu.itemArray) {
        NSString *originalItemTitle = [self storedStringForObject:item associationKey:MoonlightOriginalMenuItemTitleKey currentValue:item.title];
        if (originalItemTitle.length > 0) {
            item.title = [self localizedChromeString:originalItemTitle];
        }

        if (item.submenu != nil) {
            NSString *submenuOriginalTitle = [self storedStringForObject:item.submenu associationKey:MoonlightOriginalMenuTitleKey currentValue:item.submenu.title];
            NSString *submenuKey = submenuOriginalTitle.length > 0 ? submenuOriginalTitle : originalItemTitle;
            if (submenuKey.length > 0) {
                item.submenu.title = [self localizedChromeString:submenuKey];
            }
            [self localizeMenu:item.submenu];
        }
    }
}

- (NSString *)toolbarLocalizationKeyForItem:(NSToolbarItem *)item originalValue:(NSString *)originalValue {
    if ([item.itemIdentifier isEqualToString:@"PreferencesToolbarItem"]) {
        if (@available(macOS 13.0, *)) {
            return @"Settings";
        }
        return @"Preferences";
    }
    return originalValue;
}

- (void)localizeToolbarForWindow:(NSWindow *)window {
    NSToolbar *toolbar = window.toolbar;
    if (toolbar == nil) {
        return;
    }

    for (NSToolbarItem *item in toolbar.items) {
        NSString *originalLabel = [self storedStringForObject:item associationKey:MoonlightOriginalToolbarLabelKey currentValue:item.label];
        NSString *originalPaletteLabel = [self storedStringForObject:item associationKey:MoonlightOriginalToolbarPaletteLabelKey currentValue:item.paletteLabel];
        NSString *originalToolTip = [self storedStringForObject:item associationKey:MoonlightOriginalToolbarToolTipKey currentValue:item.toolTip];

        NSString *labelKey = [self toolbarLocalizationKeyForItem:item originalValue:originalLabel];
        NSString *paletteLabelKey = [self toolbarLocalizationKeyForItem:item originalValue:(originalPaletteLabel.length > 0 ? originalPaletteLabel : originalLabel)];
        NSString *toolTipKey = [self toolbarLocalizationKeyForItem:item originalValue:(originalToolTip.length > 0 ? originalToolTip : originalLabel)];

        if (labelKey.length > 0) {
            item.label = [self localizedChromeString:labelKey];
        }
        if (paletteLabelKey.length > 0) {
            item.paletteLabel = [self localizedChromeString:paletteLabelKey];
        }
        if (toolTipKey.length > 0) {
            item.toolTip = [self localizedChromeString:toolTipKey];
        }

        if ([item.view isKindOfClass:[NSButton class]] && item.toolTip.length > 0) {
            ((NSButton *)item.view).toolTip = item.toolTip;
        }
    }
}


#pragma mark - NSWindowDelegate

- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object == self.preferencesWC.window) {
        // Kept for the next time it is shown; what only matters while it is seen stops.
        [SettingsWindowObjCBridge settingsWindowVisibilityChanged:NO];
    } else if (notification.object == self.aboutWC.window) {
        self.aboutWC = nil;
    } else if (notification.object == self.welcomePermissionsWC.window && self.welcomePermissionsWC.window.sheetParent == nil) {
        [WelcomePermissionsWindowObjCBridge markWelcomeWindowShown];
        self.welcomePermissionsWC = nil;
    }
}

@end
