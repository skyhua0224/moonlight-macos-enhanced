//
//  AppsWorkspaceViewController.h
//  Limelight
//
//  Created by SkyHua on 2025-01-20.
//

#import <Cocoa/Cocoa.h>
#import "TemporaryHost.h"

NS_ASSUME_NONNULL_BEGIN

@interface AppsWorkspaceViewController : NSSplitViewController

@property (nonatomic, strong) TemporaryHost *initialHost;

- (instancetype)initWithHost:(TemporaryHost *)host;
- (instancetype)initWithHost:(TemporaryHost *)host hostsSnapshot:(NSArray<TemporaryHost *> *)hostsSnapshot;

@end

NS_ASSUME_NONNULL_END
