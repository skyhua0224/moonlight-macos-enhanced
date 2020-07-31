//
//  Helpers.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 29/7/20.
//  Copyright © 2020 Moonlight Game Streaming Project. All rights reserved.
//

#import "Helpers.h"

@implementation Helpers

+ (NSWindow *)getMainWindow {
    for (NSWindow *window in [NSApplication sharedApplication].windows) {
        if ([window.identifier isEqualToString:@"MainWindow"]) {
            return window;
        }
    }
    
    return nil;
}


+ (NSString *)versionNumberString {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *version = [info objectForKey:@"CFBundleShortVersionString"];
    NSString *buildNumber = [info objectForKey:@"CFBundleVersion"];
    
    return [NSString stringWithFormat:@"Version %@ (%@)", version, buildNumber];
}

+ (NSString *)copyrightString {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *copyright = [info objectForKey:@"NSHumanReadableCopyright"];
    
    return copyright;
}

@end
