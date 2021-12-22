//
//  PrivateAppAssetManager.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 22/12/2021.
//  Copyright © 2021 Moonlight Game Streaming Project. All rights reserved.
//

#import "PrivateAppAssetManager.h"
#import "AppAssetManager.h"
#import "CryptoManager.h"
#import "Utils.h"
#import "HttpResponse.h"
#import "PrivateAppAssetRetriever.h"

@implementation PrivateAppAssetManager {
    NSOperationQueue* _opQueue;
    id<PrivateAppAssetCallback> _callback;
}

static const int MAX_REQUEST_COUNT = 4;

- (id)initWithCallback:(id<PrivateAppAssetCallback>)callback {
    self = [super init];
    _callback = callback;
    _opQueue = [[NSOperationQueue alloc] init];
    [_opQueue setMaxConcurrentOperationCount:MAX_REQUEST_COUNT];
    
    return self;
}

- (void)retrieveAssetsFromHost:(TemporaryHost *)host {
    for (TemporaryApp *app in host.appList) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:[AppAssetManager boxArtPathForApp:app]]) {
            PrivateAppAssetRetriever *retriever = [[PrivateAppAssetRetriever alloc] init];
            retriever.app = app;
            retriever.host = host;
            retriever.callback = _callback;
            
            [_opQueue addOperation:retriever];
        }
    }
}

- (void)stopRetrieving {
    [_opQueue cancelAllOperations];
}

- (void)sendCallBackForApp:(TemporaryApp *)app {
    [_callback receivedPrivateAssetForApp:app];
}

@end
