//
//  NSResponder+Moonlight.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 13/1/2022.
//  Copyright © 2022 Moonlight Game Streaming Project. All rights reserved.
//

#import "NSResponder+Moonlight.h"

@implementation NSResponder (Moonlight)

- (void)controllerEvent:(MoonlightControllerEvent)event {
    [[self nextResponder] controllerEvent:event];
}

@end
