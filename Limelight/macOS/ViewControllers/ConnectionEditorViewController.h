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

@end

NS_ASSUME_NONNULL_END
