//
//  AppDelegateForUIKit.m
//  Moonlight
//
//  Created by Michael Kenny on 10/2/18.
//  Copyright © 2018 Moonlight Stream. All rights reserved.
//

#import "AppDelegateForUIKit.h"
#import "DatabaseSingleton.h"
#import "SWRevealViewController.h"
#import "MainFrameViewController.h"

@interface AppDelegateForUIKit () <UIApplicationDelegate>
@end

@implementation AppDelegateForUIKit

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    [[NSUserDefaults standardUserDefaults] setValue:@(NO) forKey:@"_UIConstraintBasedLayoutLogUnsatisfiable"];
    
    
    [[UILabel appearance] setFont:[UIFont systemFontOfSize:[UIFont systemFontSize]]];
    [[UIButton appearance].titleLabel setFont:[UIFont systemFontOfSize:[UIFont systemFontSize]]];
    
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self setupShortcuts];
    });
    
    return YES;
}

- (void)application:(UIApplication *)application performActionForShortcutItem:(UIApplicationShortcutItem *)shortcutItem completionHandler:(void (^)(BOOL))completionHandler {
    [self handleShortcut:shortcutItem];
    completionHandler(YES);
}

- (void)applicationWillResignActive:(UIApplication *)application
{
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    // Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    // Saves changes in the application's managed object context before the application terminates.
    [[DatabaseSingleton shared] saveContext];
}

- (void)setupShortcuts {
    NSMutableArray<UIApplicationShortcutItem *> *moonlightShortcutItems = [NSMutableArray array];
    NSArray<TemporaryHost *> *hosts = [[self mainFrameVC] returnSavedHosts];
    for (TemporaryHost *host in hosts) {
        [moonlightShortcutItems addObject:[[UIApplicationShortcutItem alloc] initWithType:host.name localizedTitle:host.name localizedSubtitle:nil icon:[UIApplicationShortcutIcon iconWithTemplateImageName:@"3DTouchHost"] userInfo:nil]];
    }
    [UIApplication sharedApplication].shortcutItems = moonlightShortcutItems;
}

- (void)handleShortcut:(UIApplicationShortcutItem *)shortcutItem {
    [[self mainFrameVC] handleShortcutWithHostName:(NSString *)shortcutItem.type];
}

- (MainFrameViewController *)mainFrameVC {
    SWRevealViewController *revealVC = (SWRevealViewController *)self.window.rootViewController;
    UINavigationController *navVC = (UINavigationController *)revealVC.frontViewController;
    return (MainFrameViewController *)navVC.childViewControllers.firstObject;
}

@end
