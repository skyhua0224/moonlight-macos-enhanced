//
//  PrivateAppAssetRetriever.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 22/12/2021.
//  Copyright © 2021 Moonlight Game Streaming Project. All rights reserved.
//

#import "TemporaryHost.h"
#import "TemporaryApp.h"
#import "AppAssetManager.h"
#import "PrivateAppAssetManager.h"

@interface PrivateAppAssetRetriever : NSOperation

@property (nonatomic) TemporaryHost *host;
@property (nonatomic) TemporaryApp *app;
@property (nonatomic) id<PrivateAppAssetCallback> callback;

@end
