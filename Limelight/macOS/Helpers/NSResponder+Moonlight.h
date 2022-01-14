//
//  NSResponder+Moonlight.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 13/1/2022.
//  Copyright © 2022 Moonlight Game Streaming Project. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

enum {
    kMCE_AButton,
    kMCE_BButton,
    kMCE_XButton,
    kMCE_LeftDpad,
    kMCE_RightDpad,
    kMCE_UpDpad,
    kMCE_DownDpad,
    kMCE_Unknown
};

typedef struct {
    unsigned short button;
} MoonlightControllerEvent;

@interface NSResponder (Moonlight)
- (void)controllerEvent:(MoonlightControllerEvent)event;
@end

NS_ASSUME_NONNULL_END
