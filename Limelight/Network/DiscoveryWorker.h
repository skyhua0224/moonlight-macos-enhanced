//
//  DiscoveryWorker.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/2/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "TemporaryHost.h"

@interface DiscoveryWorker : NSOperation

@property(nonatomic, copy) void (^onlineHandler)(TemporaryHost *host);

- (id) initWithHost:(TemporaryHost*)host uniqueId:(NSString*)uniqueId;
- (void) discoverHost;
- (TemporaryHost*) getHost;

@end
