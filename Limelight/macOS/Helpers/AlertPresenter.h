//
//  AlertPresenter.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 24/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface AlertPresenter : NSObject

+ (NSAlert *)displayAlert:(NSAlertStyle)style title:(NSString *)title message:(NSString *)message window:(NSWindow *)window completionHandler:(void (^)(NSModalResponse returnCode))handler;

@end
