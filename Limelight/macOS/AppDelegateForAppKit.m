//
//  AppDelegateForAppKit.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 10/2/18.
//  Copyright © 2018 Moonlight Stream. All rights reserved.
//

#import "AppDelegateForAppKit.h"
#import "DatabaseSingleton.h"

typedef enum : NSUInteger {
    SystemTheme,
    LightTheme,
    DarkTheme,
} Theme;

@interface AppDelegateForAppKit () <NSApplicationDelegate>
@property (nonatomic, strong) NSWindowController *preferencesWC;
@property (weak) IBOutlet NSMenuItem *themeMenuItem;
@end

@implementation AppDelegateForAppKit

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    NSURL *defaultPrefsFile = [[NSBundle mainBundle] URLForResource:@"DefaultPreferences" withExtension:@"plist"];
    NSDictionary *defaultPrefs = [NSDictionary dictionaryWithContentsOfURL:defaultPrefsFile];
    [[NSUserDefaults standardUserDefaults] registerDefaults:defaultPrefs];
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    if (@available(macOS 10.14, *)) {
        Theme theme = [[NSUserDefaults standardUserDefaults] integerForKey:@"theme"];
        [self changeTheme:theme withMenuItem:[self menuItemForTheme:theme forMenu:self.themeMenuItem.submenu]];
    } else {
        [self.themeMenuItem.submenu.supermenu removeItem:self.themeMenuItem];
    }
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    [[DatabaseSingleton shared] saveContext];
}

- (IBAction)showPreferences:(id)sender {
    if (self.preferencesWC == nil) {
        self.preferencesWC = [[NSWindowController alloc] initWithWindowNibName:@"PreferencesWindow"];
    }
    [self.preferencesWC showWindow:nil];
    [self.preferencesWC.window makeKeyAndOrderFront:nil];
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

- (NSMenuItem *)menuItemForTheme:(Theme)theme forMenu:(NSMenu *)menu {
    static NSUInteger menuIndexes[] = {0, 2, 3};
    return menu.itemArray[menuIndexes[theme]];
}

- (void)changeTheme:(Theme)theme withMenuItem:(NSMenuItem *)menuItem {
    menuItem.state = NSControlStateValueOn;
    for (NSMenuItem *item in menuItem.menu.itemArray) {
        if (menuItem != item) {
            item.state = NSControlStateValueOff;
        }
    }
    
    [[NSUserDefaults standardUserDefaults] setInteger:theme forKey:@"theme"];
    
    if (@available(macOS 10.14, *)) {
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
}

@end
