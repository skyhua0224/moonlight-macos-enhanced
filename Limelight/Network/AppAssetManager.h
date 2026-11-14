//
//  AppManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/25/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "TemporaryApp.h"
#import "HttpManager.h"
#import "TemporaryHost.h"

@protocol AppAssetCallback <NSObject>

- (void) receivedAssetForApp:(TemporaryApp*)app;

@end

@interface AppAssetManager : NSObject

- (id) initWithCallback:(id<AppAssetCallback>)callback;
- (void) retrieveAssetsFromHost:(TemporaryHost*)host;
- (void) stopRetrieving;
/// Tiered posters: the lossless picture of a poster is fetched when nothing else is going on (deduplicated).
- (void) queueFullPosterForApp:(TemporaryApp*)app host:(TemporaryHost*)host;
/// Pictures (previews) that are queued or running.
- (NSUInteger) previewOperationCount;
/// The full picture stopped with part of it on disk: asks again in a moment, if the app is not busy.
- (void) continueFullPosterForApp:(TemporaryApp*)app host:(TemporaryHost*)host afterSeconds:(NSTimeInterval)seconds;
+ (NSString*) cacheDirectoryForHostUUID:(NSString*)uuid;
+ (NSString*) boxArtPathForApp:(TemporaryApp*)app;
/// poster (<id>.png), hero (<id>_hero.jpg), logo (<id>_logo.png), icon (<id>_icon.png): the names the apps page reads.
+ (NSString*) artPathForApp:(TemporaryApp*)app kind:(NSString*)kind;
+ (BOOL) isDesktopApp:(TemporaryApp*)app;

@end

/// What the cache knows about each art file of a host: the validators the host sent (ETag, Last-Modified), the
/// FsArtVersion it announced, a SHA-256 of the bytes on disk and when it was last checked. A file with no entry
/// (every copy cached before this was added) is checked once against the host, so an old cover is replaced
/// without anybody clearing a cache. Memory only under the lock; the plist is written on a queue afterwards.
@interface AppAssetMeta : NSObject
+ (NSDictionary*) entryForHost:(NSString*)hostUUID key:(NSString*)key;
+ (void) setEntry:(NSDictionary*)entry forHost:(NSString*)hostUUID key:(NSString*)key;
+ (NSString*) keyForApp:(TemporaryApp*)app kind:(NSString*)kind;
@end
