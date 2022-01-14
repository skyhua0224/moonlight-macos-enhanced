//
//  PrivateAppAssetManager.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 22/12/2021.
//  Copyright © 2021 Moonlight Game Streaming Project. All rights reserved.
//

#import "TemporaryApp.h"
#import "TemporaryHost.h"
#import "HttpManager.h"

@protocol PrivateAppAssetCallback <NSObject>

- (void)receivedPrivateAssetForApp:(TemporaryApp *)app;

@end

@interface PrivateAppAssetManager : NSObject

- (id)initWithCallback:(id<PrivateAppAssetCallback>)callback;
- (void)retrieveAssetsFromHost:(TemporaryHost *)host;
- (void)stopRetrieving;

@end
