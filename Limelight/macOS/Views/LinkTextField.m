//
//  LinkTextField.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 5/11/19.
//  Copyright © 2019 Moonlight Game Streaming Project. All rights reserved.
//

#import "LinkTextField.h"

@implementation LinkTextField

- (void)resetCursorRects {
    [self addCursorRect:[self bounds] cursor:[NSCursor pointingHandCursor]];
}

@end
