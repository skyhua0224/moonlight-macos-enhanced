//
//  ConnectionEditorViewController.h
//  Moonlight for macOS
//
//  Created by GitHub SkyHua on 2026/01/16.
//

#import <Cocoa/Cocoa.h>
@class TemporaryHost;

NS_ASSUME_NONNULL_BEGIN

@interface ConnectionEditorViewController : NSViewController

- (instancetype)initWithHost:(TemporaryHost *)host;

// Set by SwiftUI presentations that need the backing sheet binding cleared
// when the AppKit close button is used. Other callers may leave it unset.
@property (nonatomic, copy, nullable) void (^closeHandler)(void);

@end

NS_ASSUME_NONNULL_END
