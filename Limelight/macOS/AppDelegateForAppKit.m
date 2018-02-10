//
//  AppDelegateForAppKit.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 10/2/18.
//  Copyright © 2018 Moonlight Stream. All rights reserved.
//

#import "AppDelegateForAppKit.h"
#import "DatabaseSingleton.h"

@interface AppDelegateForAppKit () <NSApplicationDelegate>
@property (nonatomic, strong) NSWindowController *preferencesWC;
@end

@implementation AppDelegateForAppKit

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    NSURL *defaultPrefsFile = [[NSBundle mainBundle] URLForResource:@"DefaultPreferences" withExtension:@"plist"];
    NSDictionary *defaultPrefs = [NSDictionary dictionaryWithContentsOfURL:defaultPrefsFile];
    [[NSUserDefaults standardUserDefaults] registerDefaults:defaultPrefs];
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

@end
