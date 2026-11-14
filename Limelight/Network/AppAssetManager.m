//
//  AppManager.m
//  Moonlight
//
//  Created by Diego Waxemberg on 10/25/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "AppAssetManager.h"
#import "CryptoManager.h"
#import "Utils.h"
#import "HttpResponse.h"
#import "AppAssetRetriever.h"
#import "MoonlightEnhanced-Swift.h"

@implementation AppAssetManager {
    NSOperationQueue* _opQueue;
    id<AppAssetCallback> _callback;
    NSMutableSet<NSString*>* _queuedKeys;   // pictures that are queued or running: asked for once
    NSOperationQueue* _fullQueue;           // lossless posters, one at a time, behind everything else
    NSMutableSet<NSString*>* _fullKeys;
    TemporaryHost* _lastHost;
    id _knownObserver;
}

- (void) dealloc {
    if (_knownObserver != nil) [[NSNotificationCenter defaultCenter] removeObserver:_knownObserver];
}

// Covers are background work on a link that may be slow (an overlay link may carry only 10 Mbit/s): two at a time at most.
static const int MAX_REQUEST_COUNT = 2;

+ (NSString*) cacheDirectoryForHostUUID:(NSString*)uuid {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *filePath = [paths objectAtIndex:0];
    filePath = [filePath stringByAppendingPathComponent:[[NSBundle mainBundle] bundleIdentifier]];
    // Keep app assets separate by host UUID
    return [filePath stringByAppendingPathComponent:uuid];
}

+ (NSString*) boxArtPathForApp:(TemporaryApp*)app {
    // Use the app ID as the file name, with a png extension
    return [[[self cacheDirectoryForHostUUID:app.host.uuid] stringByAppendingPathComponent:app.id] stringByAppendingPathExtension:@"png"];
}

+ (NSString*) artPathForApp:(TemporaryApp*)app kind:(NSString*)kind {
    NSString *poster = [self boxArtPathForApp:app];
    if (kind.length == 0 || [kind isEqualToString:@"poster"]) return poster;
    NSString *suffix = [kind isEqualToString:@"hero"] ? @"_hero.jpg" : ([kind isEqualToString:@"logo"] ? @"_logo.png" : @"_icon.png");
    return [[poster stringByDeletingPathExtension] stringByAppendingString:suffix];
}

+ (BOOL) isDesktopApp:(TemporaryApp*)app {
    NSString *kind = app.fsExtras[@"FsKind"];
    if (kind.length > 0) {
        return [kind isEqualToString:@"desktop"];
    }
    NSString *name = app.name.lowercaseString;
    return [name isEqualToString:@"desktop"] || [name isEqualToString:@"桌面"];
}

- (id) initWithCallback:(id<AppAssetCallback>)callback {
    self = [super init];
    _callback = callback;
    _opQueue = [[NSOperationQueue alloc] init];
    [_opQueue setMaxConcurrentOperationCount:MAX_REQUEST_COUNT];
    _opQueue.qualityOfService = NSQualityOfServiceUtility;
    _queuedKeys = [NSMutableSet set];
    _fullQueue = [[NSOperationQueue alloc] init];
    [_fullQueue setMaxConcurrentOperationCount:1];
    _fullQueue.qualityOfService = NSQualityOfServiceBackground;
    _fullKeys = [NSMutableSet set];
    // a launch or a stream begins: what is queued goes, what runs is stopped by HttpManager (MLNetworkQuiet), and the
    // lossless posters stop as well (their partial files stay for the Range request that continues them)
    __weak typeof(self) weakSelf = self;
    [MLNetworkQuiet onQuiet:[NSString stringWithFormat:@"art-%p", self] cancel:^{ [weakSelf stopAllRetrieving]; }];
    // nothing is going on again (a few seconds after the last launch or stream ended): what was stopped is asked for again
    // the first serverinfo of a computer has been read: posters wait for it to know whether the host has variants
    _knownObserver = [[NSNotificationCenter defaultCenter] addObserverForName:MLPosterVariants.knownNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        TemporaryHost *host = [weakSelf lastHost];
        if (host != nil && [host.uuid isEqual:note.object]) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [weakSelf retrieveAssetsFromHost:host]; });
        }
    }];
    [MLNetworkQuiet onIdle:[NSString stringWithFormat:@"art-%p", self] resume:^{
        TemporaryHost *host = [weakSelf lastHost];
        if (host != nil) [weakSelf retrieveAssetsFromHost:host];
    }];
    
    return self;
}

/// The art kinds this app has on this host: the poster always, the others only when FsArt (Foundation Sunshine) lists them.
+ (NSArray<NSString*>*) artKindsForApp:(TemporaryApp*)app {
    NSMutableArray *kinds = [NSMutableArray arrayWithObject:@"poster"];
    NSString *fsArt = app.fsExtras[@"FsArt"] ?: @"";
    NSArray *announced = [fsArt componentsSeparatedByString:@","];
    for (NSString *kind in @[@"hero", @"logo", @"icon"]) {
        if ([announced containsObject:kind]) [kinds addObject:kind];
    }
    // A Foundation Sunshine host whose app list did not say what art it has (the list is unreachable, or an older build):
    // ask it for the hero anyway; a 404 is remembered (the retriever) and the poster stays.
    if (fsArt.length == 0 && app.host.uuid.length > 0 && [MLDeckActivity isFoundationWithHostUUID:app.host.uuid]) {
        [kinds addObject:@"hero"];
    }
    return kinds;
}

- (TemporaryHost*) lastHost {
    @synchronized (_fullKeys) { return _lastHost; }
}

- (void) retrieveAssetsFromHost:(TemporaryHost*)host {
    if (!host.canUseHttps) {
        return;
    }
    @synchronized (_fullKeys) { _lastHost = host; }
    // no covers while a launch is pending or a stream is open; they are asked for in the next pass
    if ([MLNetworkQuiet isQuiet]) {
        return;
    }
    // How long a copy is trusted without asking the host again. The Desktop app's picture is the host's wallpaper
    // (Foundation Sunshine on Windows): it changes, so it is checked more often than a game's cover.
    NSTimeInterval recheck = 6 * 3600, recheckDesktop = 12 * 3600;
#ifdef MLC_CONCEPT_HARNESS
    if (getenv("MLC_ART_RECHECK")) recheck = recheckDesktop = atof(getenv("MLC_ART_RECHECK"));
#endif
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *hostSoftware = [MLDeckActivity sunshineVersionWithHostUUID:host.uuid ?: @""];
    BOOL afterHostUpdate = NO;
    BOOL waitingForServerInfo = NO;
    for (TemporaryApp* app in host.appList) {
        NSString *version = app.fsExtras[@"FsArtVersion"] ?: @"";
        for (NSString *kind in [AppAssetManager artKindsForApp:app]) {
            // Whether the host has poster variants decides how a poster is asked for; serverinfo says
            if ([kind isEqualToString:@"poster"] && [MLPosterVariants stateWithHostUUID:host.uuid ?: @""] < 0) {
                waitingForServerInfo = YES;
                continue;
            }
            NSString *artPath = [AppAssetManager artPathForApp:app kind:kind];
            BOOL exists = [fm fileExistsAtPath:artPath];
            NSDictionary *entry = [AppAssetMeta entryForHost:host.uuid key:[AppAssetMeta keyForApp:app kind:kind]];
            // Never fetched, art version / art types of the app list changed, the host software changed (asked again
            // without validators, and once more after a minute), or the recheck interval is over: MLAppArtPolicy.
            BOOL need = [MLAppArtPolicy needsFetchWithEntry:entry fileExists:exists listVersion:version
                                                    listArt:app.fsExtras[@"FsArt"] ?: @""
                                               hostSoftware:hostSoftware
                                               recheckSeconds:[AppAssetManager isDesktopApp:app] ? recheckDesktop : recheck
                                                        now:[NSDate date]];
            if (need) {
                if (entry != nil && [MLAppArtPolicy hostSoftwareChangedWithStored:entry[@"hostSoftware"] ?: @"" current:hostSoftware]) afterHostUpdate = YES;
                NSString *queuedKey = [NSString stringWithFormat:@"%@/%@/%@/%@", host.uuid ?: @"", app.id ?: @"", kind, version];
                @synchronized (_queuedKeys) {
                    if ([_queuedKeys containsObject:queuedKey]) continue;
                    [_queuedKeys addObject:queuedKey];
                }
                AppAssetRetriever* retriever = [[AppAssetRetriever alloc] init];
                retriever.app = app;
                retriever.host = host;
                retriever.kind = kind;
                retriever.callback = _callback;
                retriever.manager = self;
                __weak typeof(self) weakQueue = self;
                __weak AppAssetRetriever *weakRetriever = retriever;
                retriever.completionBlock = ^{
                    typeof(self) strongQueue = weakQueue;
                    if (strongQueue == nil) return;
                    (void)weakRetriever;
                    @synchronized (strongQueue->_queuedKeys) { [strongQueue->_queuedKeys removeObject:queuedKey]; }
                };
                [_opQueue addOperation:retriever];
            }
        }
    }
    // Tiered posters: a host that advertises poster_variants gets the lossless picture of every poster whose
    // preview is in and whose full picture is not, when nothing else is going on.
    if ([MLPosterVariants supportsWithHostUUID:host.uuid ?: @""]) {
        for (TemporaryApp* app in host.appList) {
            NSDictionary *full = [AppAssetMeta entryForHost:host.uuid key:[AppAssetRetriever metaKeyForFullOfApp:app]];
            NSString *etag = full[@"etag"];
            if (etag.length > 0 && [MLPosterTier fullNeededWithHostFullEtag:etag cachedFullEtag:etag cachedComplete:[full[@"complete"] boolValue]]) {
                [self queueFullPosterForApp:app host:host];
            }
        }
    }
    if (waitingForServerInfo) {
        // the notification brings the next pass; this one is the fallback for a computer whose serverinfo never comes
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [weakSelf retrieveAssetsFromHost:host];
        });
    }
    if (afterHostUpdate) {
        // The host was updated: what it served in the first minute may still be the old files (its app list is read
        // a little after it starts). One more pass after the provisional time asks again without validators.
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((MLAppArtPolicy.provisionalSeconds + 5) * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [weakSelf retrieveAssetsFromHost:host];
        });
    }
}

/// The apps page asks for this after every app list: previews that are queued go; a lossless poster that is running
/// carries on (it is the slow one, and it is asked for again by key only once).
- (void) stopRetrieving {
    [_opQueue cancelAllOperations];
    @synchronized (_queuedKeys) { [_queuedKeys removeAllObjects]; }
}

/// A launch is pending or a stream is open: everything stops.
- (void) stopAllRetrieving {
    [self stopRetrieving];
    [_fullQueue cancelAllOperations];
    @synchronized (_fullKeys) { [_fullKeys removeAllObjects]; }
}

- (NSUInteger) previewOperationCount {
    return _opQueue.operationCount;
}

- (void) queueFullPosterForApp:(TemporaryApp*)app host:(TemporaryHost*)host {
    if (app == nil || host == nil || [MLNetworkQuiet isQuiet]) return;
    NSString *fullKey = [NSString stringWithFormat:@"%@/%@", host.uuid ?: @"", app.id ?: @""];
    @synchronized (_fullKeys) {
        if ([_fullKeys containsObject:fullKey]) return;
        [_fullKeys addObject:fullKey];
    }
    PosterFullRetriever *op = [[PosterFullRetriever alloc] init];
    op.host = host;
    op.app = app;
    op.callback = _callback;
    op.manager = self;
    __weak typeof(self) weakSelf = self;
    __weak PosterFullRetriever *weakOp = op;
    op.completionBlock = ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        @synchronized (strongSelf->_fullKeys) { [strongSelf->_fullKeys removeObject:fullKey]; }
        // part of the picture arrived and the connection ended: continue from there in a moment
        if (weakOp.outcome == 2) [strongSelf continueFullPosterForApp:app host:host afterSeconds:2];
    };
    [_fullQueue addOperation:op];
}

- (void) continueFullPosterForApp:(TemporaryApp*)app host:(TemporaryHost*)host afterSeconds:(NSTimeInterval)seconds {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (![MLNetworkQuiet isQuiet]) [weakSelf queueFullPosterForApp:app host:host];
    });
}

- (void) sendCallBackForApp:(TemporaryApp*)app {
    [_callback receivedAssetForApp:app];
}

@end


#pragma mark - AppAssetMeta

static NSMutableDictionary<NSString*, NSMutableDictionary*> *gAssetMeta;
static NSLock *gAssetMetaLock;
static dispatch_queue_t gAssetMetaQueue;
static dispatch_once_t gAssetMetaOnce;

@implementation AppAssetMeta

+ (NSString*) plistPathForHost:(NSString*)uuid {
    return [[AppAssetManager cacheDirectoryForHostUUID:uuid] stringByAppendingPathComponent:@"art-meta.plist"];
}

+ (NSString*) keyForApp:(TemporaryApp*)app kind:(NSString*)kind {
    return [NSString stringWithFormat:@"%@/%@", app.id ?: @"", kind.length > 0 ? kind : @"poster"];
}

+ (void) setup {
    dispatch_once(&gAssetMetaOnce, ^{
        gAssetMeta = [NSMutableDictionary dictionary];
        gAssetMetaLock = [[NSLock alloc] init];
        gAssetMetaQueue = dispatch_queue_create("std.skyhua.art-meta", DISPATCH_QUEUE_SERIAL);
    });
}

+ (NSDictionary*) entryForHost:(NSString*)hostUUID key:(NSString*)key {
    if (hostUUID.length == 0) return nil;
    [self setup];
    [gAssetMetaLock lock];
    BOOL loaded = gAssetMeta[hostUUID] != nil;
    [gAssetMetaLock unlock];
    if (!loaded) {
        // the file is read outside the lock
        NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:[self plistPathForHost:hostUUID]] ?: @{};
        [gAssetMetaLock lock];
        if (gAssetMeta[hostUUID] == nil) gAssetMeta[hostUUID] = [onDisk mutableCopy];
        [gAssetMetaLock unlock];
    }
    NSDictionary *entry = nil;
    [gAssetMetaLock lock];
    entry = [gAssetMeta[hostUUID][key] copy];
    [gAssetMetaLock unlock];
    return entry;
}

+ (void) setEntry:(NSDictionary*)entry forHost:(NSString*)hostUUID key:(NSString*)key {
    if (hostUUID.length == 0 || key.length == 0) return;
    [self entryForHost:hostUUID key:key];   // makes sure the host's file has been read
    NSDictionary *snapshot = nil;
    [gAssetMetaLock lock];
    gAssetMeta[hostUUID][key] = [entry copy];
    snapshot = [gAssetMeta[hostUUID] copy];
    [gAssetMetaLock unlock];
    NSString *path = [self plistPathForHost:hostUUID];
    dispatch_async(gAssetMetaQueue, ^{
        [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        [snapshot writeToFile:path atomically:YES];
    });
}

@end
