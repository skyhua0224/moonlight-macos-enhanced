//
//  AppAssetRetriever.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/31/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "TemporaryHost.h"
#import "TemporaryApp.h"
#import "AppAssetManager.h"

@interface AppAssetRetriever : NSOperation

@property (nonatomic) TemporaryHost* host;
@property (nonatomic) TemporaryApp* app;
/// poster, hero, logo or icon (nil is the poster)
@property (nonatomic, copy) NSString* kind;
@property (nonatomic) id<AppAssetCallback> callback;
/// The manager that queued this: a tiered poster asks it to queue the full picture once the preview is in.
@property (nonatomic, weak) AppAssetManager* manager;

/// Tiered posters, for hosts that advertise poster_variants: where the preview and the full picture of an app
/// are kept, keyed by host, app and ETag.
+ (NSString*) posterDirectoryForApp:(TemporaryApp*)app;
+ (NSString*) metaKeyForFullOfApp:(TemporaryApp*)app;

@end

/// The lossless picture of a poster on a host that advertises poster_variants. It runs only when nothing else is going
/// on: no launch pending, no stream open (MLNetworkQuiet), no preview waiting. It asks for the bytes it does not have
/// yet (Range from the partial file), checks the ETag and the SHA-256 before the picture replaces the preview, and
/// stops the moment a launch or a stream begins, keeping the partial file.
@interface PosterFullRetriever : NSOperation
@property (nonatomic) TemporaryHost* host;
@property (nonatomic) TemporaryApp* app;
@property (nonatomic) id<AppAssetCallback> callback;
@property (nonatomic, weak) AppAssetManager* manager;
/// 0 nothing yet, 1 done, 2 stopped with part of the picture on disk (ask again soon), 3 stopped by a launch or a stream,
/// 4 failed without progress.
@property (nonatomic, readonly) NSInteger outcome;
@end
