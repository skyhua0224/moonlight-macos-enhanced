//
//  StreamManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "Connection.h"
#import "StreamConfiguration.h"

@interface StreamManager : NSOperation

@property(nonatomic, readonly) Connection *connection;

- (id)initWithConfig:(StreamConfiguration *)config
             renderView:(OSView *)view
    connectionCallbacks:(id<ConnectionCallbacks>)callback;

- (void)stopStream;

@end
