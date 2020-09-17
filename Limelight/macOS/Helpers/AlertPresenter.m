//
//  AlertPresenter.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 24/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "AlertPresenter.h"

@implementation AlertPresenter

+ (NSAlert *)displayAlert:(NSAlertStyle)style title:(NSString *)title message:(NSString *)message window:(NSWindow *)window completionHandler:(void (^)(NSModalResponse returnCode))handler {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = style;
    alert.messageText = title;
    if (message != nil) {
        alert.informativeText = message;
    }
    [alert beginSheetModalForWindow:window completionHandler:handler];
    
    return alert;
}

@end
