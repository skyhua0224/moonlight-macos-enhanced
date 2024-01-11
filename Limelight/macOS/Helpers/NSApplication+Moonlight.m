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
    NSAppearanceName basicAppearance = [[NSApplication sharedApplication].effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    return [basicAppearance isEqualToString:NSAppearanceNameDarkAqua];
}

@end
