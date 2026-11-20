#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

BOOL MLStreamDisconnectUsesSheet(NSWindowStyleMask style, NSInteger level);

@interface MLStreamDisconnectConfirmation : NSObject

- (instancetype)initWithAlert:(NSAlert *)alert host:(NSWindow *)host;
- (void)presentWithShortcutMatcher:(BOOL (^)(NSEvent *))matchesShortcut
                        completion:(void (^)(NSModalResponse))completion;
- (void)chooseDisconnect;
- (void)dismiss;

@end

NS_ASSUME_NONNULL_END
