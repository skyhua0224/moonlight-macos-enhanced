//
//  NSAppearance+Moonlight.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 25/1/19.
//  Copyright © 2019 Moonlight Game Streaming Project. All rights reserved.
//

#import "NSAppearance+Moonlight.h"

@implementation NSAppearance (Moonlight)

- (BOOL)moonlight_isDark {
    if (@available(macOS 10.14, *)) {
        NSAppearanceName basicAppearance = [self bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
        return [basicAppearance isEqualToString:NSAppearanceNameDarkAqua];
    } else {
        return NO;
    }
}

@end
