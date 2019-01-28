//
//  NSApplication+Moonlight.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 28/1/19.
//  Copyright © 2019 Moonlight Game Streaming Project. All rights reserved.
//

#import "NSApplication+Moonlight.h"

@implementation NSApplication (Moonlight)

+ (BOOL)moonlight_isDarkAppearance {
    if (@available(macOS 10.14, *)) {
        NSAppearanceName basicAppearance = [[NSApplication sharedApplication].effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
        return [basicAppearance isEqualToString:NSAppearanceNameDarkAqua];
    } else {
        return NO;
    }
}

@end
