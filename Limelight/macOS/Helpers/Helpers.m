//
//  Helpers.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 29/7/20.
//  Copyright © 2020 Moonlight Game Streaming Project. All rights reserved.
//

#import "Helpers.h"

@implementation Helpers

+ (NSString *)versionNumberString {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *version = [info objectForKey:@"CFBundleShortVersionString"];
    NSString *buildNumber = [info objectForKey:@"CFBundleVersion"];
    
    return [NSString stringWithFormat:@"Version %@ (%@)", version, buildNumber];
}

@end
