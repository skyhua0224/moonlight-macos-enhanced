//
//  AppAssetRetriever.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/31/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "AppAssetRetriever.h"
#import "HttpManager.h"
#import "CryptoManager.h"
#import "AppAssetResponse.h"
#import "HttpRequest.h"
#import "IdManager.h"
#import "AppAssetManager.h"
#import "MoonlightEnhanced-Swift.h"
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>

@interface AppAssetRetriever (PosterTier)
+ (NSString*) posterFileForApp:(TemporaryApp*)app tier:(NSString*)tier etag:(NSString*)etag ext:(NSString*)ext;
+ (void) removeStaleFilesForApp:(TemporaryApp*)app tier:(NSString*)tier keepEtag:(NSString*)etag;
+ (BOOL) installPath:(NSString*)dst fromFile:(NSString*)src;
+ (NSString*) sha256OfFile:(NSString*)path;
@end

@implementation AppAssetRetriever
// One pass is one request; the second pass exists only for "the 304 was about some other file". A failed request is not
// repeated here: MLArtLedger holds the key back (30 s, doubling, up to 15 min, six failures and it is left alone until
// the art version changes), and nothing runs while a launch is pending or a stream is open (MLNetworkQuiet).
static const int MAX_PASSES = 2;
// A cover is not wanted now: idle timeout, and how long a whole transfer may take on a slow link (the Desktop picture
// of a host is a 10 MB wallpaper).
static const NSTimeInterval ART_IDLE_TIMEOUT = 20;
static const NSTimeInterval ART_TOTAL_SLACK = 100;

- (void) main {
    if (!_host.canUseHttps) {
        [self performSelectorOnMainThread:@selector(sendCallbackForApp:) withObject:self.app waitUntilDone:NO];
        return;
    }
    if ([MLNetworkQuiet isQuiet] || [self isCancelled]) return;
    NSString *kind = self.kind.length > 0 ? self.kind : @"poster";
    NSString *hostUUID = _host.uuid;
    NSString *key = [AppAssetMeta keyForApp:self.app kind:kind];
    NSString *artPath = [AppAssetManager artPathForApp:self.app kind:kind];
    NSString *version = self.app.fsExtras[@"FsArtVersion"] ?: @"";
    NSString *listArt = self.app.fsExtras[@"FsArt"] ?: @"";
    NSString *hostSoftware = [MLDeckActivity sunshineVersionWithHostUUID:hostUUID ?: @""];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL existedBefore = [fm fileExistsAtPath:artPath];
    NSDictionary *entry = [AppAssetMeta entryForHost:hostUUID key:key];
    // The host software changed since this picture was recorded: the host may still serve the old file under the
    // old validators for a while, so this fetch carries none, and a minute later one more follows (MLAppArtPolicy).
    BOOL afterHostUpdate = entry != nil && [MLAppArtPolicy hostSoftwareChangedWithStored:entry[@"hostSoftware"] ?: @"" current:hostSoftware];
    // an operation queued behind another one for the same picture finds it done: nothing more to ask
    NSTimeInterval recheckSeconds = [AppAssetManager isDesktopApp:self.app] ? 12 * 3600 : 6 * 3600;
#ifdef MLC_CONCEPT_HARNESS
    if (getenv("MLC_ART_RECHECK")) recheckSeconds = atof(getenv("MLC_ART_RECHECK"));   // as AppAssetManager does
#endif
    if (![MLAppArtPolicy needsFetchWithEntry:entry fileExists:existedBefore listVersion:version listArt:listArt hostSoftware:hostSoftware
                              recheckSeconds:recheckSeconds now:[NSDate date]]) {
        return;
    }
    BOOL forceFull = NO;
    BOOL changed = NO;
    int attempts = 0;
    // On a host that advertises poster_variants a poster is asked for as a preview first; its lossless picture
    // follows when the link is idle (PosterFullRetriever). Any other host, and every other art kind: one request.
    BOOL tiered = [kind isEqualToString:@"poster"] && [MLPosterVariants stateWithHostUUID:hostUUID ?: @""] == 1;
    if ([kind isEqualToString:@"poster"] && [MLPosterVariants stateWithHostUUID:hostUUID ?: @""] < 0) return;   // serverinfo not read yet; the manager asks again
    NSDate *startedAt = [NSDate date];
    // one transfer per picture and version at a time; a picture that keeps failing waits, then is given up
    NSString *ledgerKey = [NSString stringWithFormat:@"%@/%@/%@", hostUUID ?: @"", key, version];
    NSInteger verdict = [MLArtLedger claim:ledgerKey];
    if (verdict != 0) {
        Log(LOG_D, @"[art] %@ %@/%@: not asked now (%@)", _host.name, self.app.id, kind,
            verdict == 1 ? @"in flight" : (verdict == 2 ? @"waiting after a failure" : @"given up until the art changes"));
        return;
    }
    BOOL succeeded = NO, cancelledForQuiet = NO;
    while (![self isCancelled] && attempts++ < MAX_PASSES) {
        if ([MLNetworkQuiet isQuiet]) { cancelledForQuiet = YES; break; }
        BOOL conditional = !forceFull && [MLAppArtPolicy canUseValidatorsWithEntry:entry fileExists:existedBefore listVersion:version hostSoftware:hostSoftware];
        HttpManager* hMan = [[HttpManager alloc] initWithHost:_host.activeAddress uniqueId:[IdManager getUniqueId] serverCert:_host.serverCert];
        AppAssetResponse* appAssetResp = [[AppAssetResponse alloc] init];
        NSURLRequest *request = [hMan newAppAssetRequestWithAppId:self.app.id kind:kind variant:tiered ? MLPosterTier.previewVariant : nil
                                                             etag:conditional ? entry[@"etag"] : nil
                                                         modified:conditional ? entry[@"modified"] : nil];
        NSMutableURLRequest *bounded = [request mutableCopy];
        bounded.timeoutInterval = ART_IDLE_TIMEOUT;
        hMan.backgroundTransfer = YES;
        [hMan executeRequestSynchronously:[HttpRequest requestForResponse:appAssetResp withUrlRequest:bounded] waitSlack:ART_TOTAL_SLACK];
        if (hMan.endedForQuiet) { cancelledForQuiet = YES; break; }
        NSInteger status = appAssetResp.httpStatus;

        if (status == 304 && existedBefore && conditional) {
            NSString *responseEtag = [appAssetResp headerValue:@"ETag"];
            NSDictionary *next = [MLAppArtPolicy entryAfterNotModifiedWithPrevious:entry sentEtag:entry[@"etag"] responseEtag:responseEtag
                                                                  responseModified:[appAssetResp headerValue:@"Last-Modified"]
                                                                       listVersion:version listArt:listArt hostSoftware:hostSoftware now:[NSDate date]];
            if (next == nil) {
                // the host's answer is about some other file than the one the list announces: fetch it in full
                Log(LOG_I, @"[art] %@ %@/%@: 304 with ETag %@ does not match version %@; fetching in full", _host.name, self.app.id, kind, responseEtag ?: @"-", version);
                forceFull = YES;
                continue;
            }
            Log(LOG_D, @"[art] %@ %@/%@: not modified", _host.name, self.app.id, kind);
            [AppAssetMeta setEntry:next forHost:hostUUID key:key];
            if (tiered) {
                // the host's answer may name a new full picture; without it the stored one stands
                [self noteFullEtag:[appAssetResp headerValue:@"X-FS-Poster-Full-ETag"] length:[[appAssetResp headerValue:@"X-FS-Poster-Full-Length"] longLongValue]];
                [self queueFullIfNeeded];
            }
            succeeded = YES;
            break;
        }
        if (status == 404 && ![kind isEqualToString:@"poster"]) {
            // announced but not served: remembered, asked again only when the version changes or the interval is over
            [AppAssetMeta setEntry:[MLAppArtPolicy entryAbsentWithListVersion:version listArt:listArt hostSoftware:hostSoftware now:[NSDate date]] forHost:hostUUID key:key];
            succeeded = YES;
            break;
        }
        NSData *data = appAssetResp.data;
        if (tiered && status == 200 && data.length > 0 && [AppAssetRetriever isImage:data]) {
            NSString *sha = [AppAssetRetriever sha256:data];
            if ([self storeTieredBody:data response:appAssetResp existedBefore:existedBefore artPath:artPath startedAt:startedAt]) changed = YES;
            [AppAssetMeta setEntry:[MLAppArtPolicy entryAfterPictureWithEtag:[appAssetResp headerValue:@"ETag"]
                                                                     modified:[appAssetResp headerValue:@"Last-Modified"]
                                                                          sha:sha listVersion:version listArt:listArt hostSoftware:hostSoftware
                                                              afterHostUpdate:afterHostUpdate now:[NSDate date]]
                           forHost:hostUUID key:key];
            [self queueFullIfNeeded];
            succeeded = YES;
            break;
        }
        if (status == 200 && data.length > 0 && [AppAssetRetriever isImage:data]) {
            NSString *sha = [AppAssetRetriever sha256:data];
            NSString *knownSha = entry[@"sha"];
            if (knownSha == nil && existedBefore) {
                knownSha = [AppAssetRetriever sha256:[NSData dataWithContentsOfFile:artPath]];
            }
            if (!existedBefore || ![sha isEqualToString:knownSha]) {
                [fm createDirectoryAtPath:[artPath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
                [data writeToFile:artPath atomically:YES];
                changed = YES;
                Log(LOG_I, @"[art] %@ %@/%@: new picture (%lu bytes, version %@)", _host.name, self.app.id, kind, (unsigned long)data.length, version);
            } else {
                Log(LOG_D, @"[art] %@ %@/%@: same picture", _host.name, self.app.id, kind);
            }
            [AppAssetMeta setEntry:[MLAppArtPolicy entryAfterPictureWithEtag:[appAssetResp headerValue:@"ETag"]
                                                                     modified:[appAssetResp headerValue:@"Last-Modified"]
                                                                          sha:sha listVersion:version listArt:listArt hostSoftware:hostSoftware
                                                              afterHostUpdate:afterHostUpdate now:[NSDate date]]
                           forHost:hostUUID key:key];
            succeeded = YES;
            break;
        }
        // not a picture, not a 304, not a 404: the host or the link failed this time; the ledger decides when to ask again
        Log(LOG_W, @"[art] %@ %@/%@: failed (status %ld, %lu bytes)", _host.name, self.app.id, kind, (long)status, (unsigned long)data.length);
        break;
    }
    if (succeeded) {
        [MLArtLedger succeed:ledgerKey];
    } else if (cancelledForQuiet || [self isCancelled]) {
        [MLArtLedger release:ledgerKey];
    } else {
        [MLArtLedger fail:ledgerKey];
    }
    if (changed || !existedBefore) {
        [self performSelectorOnMainThread:@selector(sendCallbackForApp:) withObject:self.app waitUntilDone:NO];
    }
}


#pragma mark - Tiered posters

+ (NSString*) posterDirectoryForApp:(TemporaryApp*)app {
    return [[AppAssetManager cacheDirectoryForHostUUID:app.host.uuid] stringByAppendingPathComponent:@"posters"];
}

+ (NSString*) metaKeyForFullOfApp:(TemporaryApp*)app {
    return [NSString stringWithFormat:@"%@/poster-full", app.id ?: @""];
}

/// <dir>/<app>-<tier>-<etag>.<ext>: the preview and the full picture, by app and ETag.
+ (NSString*) posterFileForApp:(TemporaryApp*)app tier:(NSString*)tier etag:(NSString*)etag ext:(NSString*)ext {
    return [[self posterDirectoryForApp:app] stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@-%@-%@.%@", app.id ?: @"", tier, [MLPosterTier fileTag:etag], ext]];
}

/// Removes the cached files of an app and tier that belong to another ETag.
+ (void) removeStaleFilesForApp:(TemporaryApp*)app tier:(NSString*)tier keepEtag:(NSString*)etag {
    NSString *dir = [self posterDirectoryForApp:app];
    NSString *prefix = [NSString stringWithFormat:@"%@-%@-", app.id ?: @"", tier];
    NSString *keep = [MLPosterTier fileTag:etag];
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil]) {
        if (![name hasPrefix:prefix]) continue;
        NSString *rest = [[name substringFromIndex:prefix.length] stringByDeletingPathExtension];
        if (![rest isEqualToString:keep]) [[NSFileManager defaultManager] removeItemAtPath:[dir stringByAppendingPathComponent:name] error:nil];
    }
}

/// `dst` becomes the file `src` (a hard link, else a copy), replacing what was there in one step: a reader sees the old
/// picture or the new one, never half of either.
+ (BOOL) installPath:(NSString*)dst fromFile:(NSString*)src {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[dst stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *swap = [dst stringByAppendingString:@".swap"];
    [fm removeItemAtPath:swap error:nil];
    if (link(src.fileSystemRepresentation, swap.fileSystemRepresentation) != 0 && ![fm copyItemAtPath:src toPath:swap error:nil]) return NO;
    if (rename(swap.fileSystemRepresentation, dst.fileSystemRepresentation) != 0) {
        [fm removeItemAtPath:swap error:nil];
        return NO;
    }
    return YES;
}

+ (NSString*) sha256OfFile:(NSString*)path {
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:path];
    if (h == nil) return nil;
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    while (true) {
        @autoreleasepool {
            NSData *chunk = [h readDataOfLength:1 << 20];
            if (chunk.length == 0) break;
            CC_SHA256_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
        }
    }
    [h closeFile];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

/// The host named the full picture of this poster (X-FS-Poster-Full-ETag): another one than the stored means the stored
/// copies are of an older picture.
- (void) noteFullEtag:(NSString*)etag length:(long long)length {
    if (etag.length == 0) return;
    NSString *fullKey = [AppAssetRetriever metaKeyForFullOfApp:self.app];
    NSDictionary *full = [AppAssetMeta entryForHost:_host.uuid key:fullKey];
    if ([MLPosterTier sameEtag:full[@"etag"] :etag]) {
        if (length > 0 && [full[@"length"] longLongValue] != length) {
            NSMutableDictionary *m = [full mutableCopy]; m[@"length"] = @(length);
            [AppAssetMeta setEntry:m forHost:_host.uuid key:fullKey];
        }
        return;
    }
    [AppAssetRetriever removeStaleFilesForApp:self.app tier:@"full" keepEtag:etag];
    [AppAssetMeta setEntry:@{ @"etag": etag, @"length": @(length), @"complete": @NO } forHost:_host.uuid key:fullKey];
}

- (void) queueFullIfNeeded {
    NSDictionary *full = [AppAssetMeta entryForHost:_host.uuid key:[AppAssetRetriever metaKeyForFullOfApp:self.app]];
    NSString *etag = full[@"etag"];
    if (etag.length > 0 && [MLPosterTier fullNeededWithHostFullEtag:etag cachedFullEtag:etag cachedComplete:[full[@"complete"] boolValue]]) {
        [self.manager queueFullPosterForApp:self.app host:_host];
    }
}

/// A poster answered by a host that advertises poster_variants. `data` is the preview, or (X-FS-Poster-Variant missing,
/// or the source was small enough for the preview to be the picture itself) the full picture. Returns whether the
/// picture file changed.
- (BOOL) storeTieredBody:(NSData*)data response:(AppAssetResponse*)response existedBefore:(BOOL)existedBefore artPath:(NSString*)artPath startedAt:(NSDate*)startedAt {
    NSString *etag = [response headerValue:@"ETag"];
    NSString *fullEtag = [response headerValue:@"X-FS-Poster-Full-ETag"];
    long long fullLength = [[response headerValue:@"X-FS-Poster-Full-Length"] longLongValue];
    NSString *variant = [[response headerValue:@"X-FS-Poster-Variant"] lowercaseString];
    BOOL isPreview = [variant isEqualToString:MLPosterTier.previewVariant];
    // the body is the full picture: a host that did not mark it as a preview, or one whose preview is the full bytes
    BOOL bodyIsFull = !isPreview || fullEtag.length == 0 || [MLPosterTier sameEtag:etag :fullEtag];
    if (bodyIsFull) { fullEtag = etag; fullLength = (long long)data.length; }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [AppAssetRetriever posterDirectoryForApp:self.app];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *fullKey = [AppAssetRetriever metaKeyForFullOfApp:self.app];
    NSDictionary *known = [AppAssetMeta entryForHost:_host.uuid key:fullKey];
    BOOL wrote = NO;
    if (bodyIsFull) {
        // the whole picture came with the first request: it is the full copy (and shown), no second request follows
        NSString *fullFile = [AppAssetRetriever posterFileForApp:self.app tier:@"full" etag:fullEtag ext:@"bin"];
        [data writeToFile:fullFile atomically:YES];
        [AppAssetRetriever removeStaleFilesForApp:self.app tier:@"full" keepEtag:fullEtag];
        [AppAssetRetriever removeStaleFilesForApp:self.app tier:@"preview" keepEtag:@""];
        wrote = [AppAssetRetriever installPath:artPath fromFile:fullFile];
        [AppAssetMeta setEntry:@{ @"etag": fullEtag ?: @"", @"length": @(fullLength), @"complete": @YES } forHost:_host.uuid key:fullKey];
    } else {
        NSString *previewFile = [AppAssetRetriever posterFileForApp:self.app tier:@"preview" etag:etag ext:@"bin"];
        [data writeToFile:previewFile atomically:YES];
        [AppAssetRetriever removeStaleFilesForApp:self.app tier:@"preview" keepEtag:etag];
        BOOL sameFull = [MLPosterTier sameEtag:known[@"etag"] :fullEtag];
        BOOL show = [MLPosterTier shouldShowPreviewWithDisplayExists:existedBefore knownFullEtag:known[@"etag"] hostFullEtag:fullEtag];
        BOOL complete = sameFull && [known[@"complete"] boolValue];
        if (show) {
            wrote = [AppAssetRetriever installPath:artPath fromFile:previewFile];
            complete = NO;
        } else if (existedBefore && known == nil) {
            // a picture fetched before the host spoke of variants: if it is already the full picture, there is nothing more to fetch
            NSString *onDisk = [AppAssetRetriever sha256OfFile:artPath];
            complete = [[MLPosterTier sha256HexOfEtag:fullEtag] isEqualToString:onDisk ?: @""];
        }
        if (!sameFull) [AppAssetRetriever removeStaleFilesForApp:self.app tier:@"full" keepEtag:fullEtag];
        [AppAssetMeta setEntry:@{ @"etag": fullEtag ?: @"", @"length": @(fullLength), @"complete": @(complete) } forHost:_host.uuid key:fullKey];
    }
    Log(LOG_I, @"[art] %@ %@/poster: %@ %@ (%lu bytes, %.0f ms after the request began; full picture %lld bytes, %@)",
        _host.name, self.app.id, bodyIsFull ? @"full picture" : @"preview", wrote ? @"shown" : @"kept behind the picture on screen",
        (unsigned long)data.length, -[startedAt timeIntervalSinceNow] * 1000, fullLength, bodyIsFull ? @"in hand" : @"to follow when idle");
    return wrote;
}

+ (BOOL) isImage:(NSData*)data {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (source == NULL) return NO;
    BOOL ok = CGImageSourceGetCount(source) > 0;
    CFRelease(source);
    return ok;
}

+ (NSString*) sha256:(NSData*)data {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

- (void) sendCallbackForApp:(TemporaryApp*)app {
    [self.callback receivedAssetForApp:app];
}

@end

#pragma mark - A download that streams to disk

/// One request whose body goes to a file as it arrives, so a connection that drops (or is stopped because a stream
/// begins) leaves the bytes it had for the Range request that continues it. TLS is answered by the HttpManager.
@interface MLPosterDownload : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, weak) HttpManager *manager;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) long long offset;
@property (nonatomic, copy) NSString *expectedEtag;
@property (nonatomic) NSInteger status;
@property (nonatomic, copy) NSDictionary *headers;
@property (nonatomic) long long written;
@property (nonatomic) MLPosterResume action;
@property (nonatomic) BOOL stopped;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, copy) BOOL (^shouldStop)(void);
- (void) run:(NSURLRequest*)request;
- (NSString*) header:(NSString*)name;
@end

@implementation MLPosterDownload {
    dispatch_semaphore_t _done;
    NSFileHandle *_handle;
}

- (NSString*) header:(NSString*)name {
    for (id key in self.headers) {
        if ([key isKindOfClass:[NSString class]] && [(NSString *)key caseInsensitiveCompare:name] == NSOrderedSame) {
            id value = self.headers[key];
            return [value isKindOfClass:[NSString class]] ? value : nil;
        }
    }
    return nil;
}

- (void) run:(NSURLRequest*)request {
    _done = dispatch_semaphore_create(0);
    _action = MLPosterResumeFail;
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    // not wanted now: the system may send everything else first; one connection; a stall of 20 s ends it, the size does not
    config.networkServiceType = NSURLNetworkServiceTypeBackground;
    config.HTTPMaximumConnectionsPerHost = 1;
    config.timeoutIntervalForRequest = request.timeoutInterval;
    config.timeoutIntervalForResource = 6 * 3600;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request];
    task.priority = NSURLSessionTaskPriorityLow;
    [task resume];
    while (dispatch_semaphore_wait(_done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC))) != 0) {
        if ([MLNetworkQuiet isQuiet] || (self.shouldStop != nil && self.shouldStop())) {
            _stopped = YES;
            [task cancel];
            dispatch_semaphore_wait(_done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
            break;
        }
    }
    [session invalidateAndCancel];
}

- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler {
    HttpManager *manager = self.manager;
    if (manager == nil) { completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil); return; }
    [manager URLSession:session didReceiveChallenge:challenge completionHandler:completionHandler];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    self.status = http.statusCode;
    self.headers = http.allHeaderFields;
    self.action = [MLPosterTier resumeActionWithStatus:self.status contentRange:[self header:@"Content-Range"]
                                          responseEtag:[self header:@"ETag"] expectedEtag:self.expectedEtag offset:self.offset];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (self.action == MLPosterResumeAppend) {
        long long size = [[[fm attributesOfItemAtPath:self.path error:nil] objectForKey:NSFileSize] longLongValue];
        if (size == self.offset) {
            _handle = [NSFileHandle fileHandleForWritingAtPath:self.path];
            [_handle seekToEndOfFile];
        } else {
            self.action = MLPosterResumeDiscard;
        }
    } else if (self.action == MLPosterResumeRestart) {
        [fm createFileAtPath:self.path contents:nil attributes:nil];
        _handle = [NSFileHandle fileHandleForWritingAtPath:self.path];
    }
    completionHandler(_handle != nil ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (_handle == nil) return;
    NSError *writeError = nil;
    if ([_handle writeData:data error:&writeError]) {
        self.written += data.length;
    } else {
        self.error = writeError;
        [dataTask cancel];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    [_handle closeFile];
    _handle = nil;
    if (self.error == nil) self.error = error;
    dispatch_semaphore_signal(_done);
}

@end

#pragma mark - PosterFullRetriever

@implementation PosterFullRetriever

- (void) main {
    if (!_host.canUseHttps || [MLNetworkQuiet isQuiet] || [self isCancelled]) return;
    NSString *hostUUID = _host.uuid;
    NSString *fullKey = [AppAssetRetriever metaKeyForFullOfApp:self.app];
    NSDictionary *full = [AppAssetMeta entryForHost:hostUUID key:fullKey];
    NSString *etag = full[@"etag"];
    long long length = [full[@"length"] longLongValue];
    if (etag.length == 0 || [full[@"complete"] boolValue]) return;

    // The previews come first: this waits until none is queued or running (a launch or a stream ends the wait).
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:900];
    while ([self.manager previewOperationCount] > 0) {
        if ([self isCancelled] || [MLNetworkQuiet isQuiet] || [limit timeIntervalSinceNow] <= 0) { _outcome = 3; return; }
        [NSThread sleepForTimeInterval:0.5];
    }
    if ([self isCancelled] || [MLNetworkQuiet isQuiet]) { _outcome = 3; return; }

    NSString *ledgerKey = [NSString stringWithFormat:@"%@/%@/full/%@", hostUUID ?: @"", fullKey, [MLPosterTier fileTag:etag]];
    NSInteger verdict = [MLArtLedger claim:ledgerKey];
    if (verdict != 0) {
        Log(LOG_D, @"[art] %@ %@/poster full: not asked now (%@)", _host.name, self.app.id,
            verdict == 1 ? @"in flight" : (verdict == 2 ? @"waiting after a failure" : @"given up until the art changes"));
        return;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *part = [AppAssetRetriever posterFileForApp:self.app tier:@"full" etag:etag ext:@"part"];
    NSString *finalFile = [AppAssetRetriever posterFileForApp:self.app tier:@"full" etag:etag ext:@"bin"];
    [fm createDirectoryAtPath:[part stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];

    // a finished copy is on disk already (the app ended between the move and the note): prove it and use it
    if ([fm fileExistsAtPath:finalFile]) {
        NSString *sha = [MLPosterTier sha256HexOfEtag:etag] != nil ? [AppAssetRetriever sha256OfFile:finalFile] : nil;
        long long size = [[[fm attributesOfItemAtPath:finalFile error:nil] objectForKey:NSFileSize] longLongValue];
        if ([MLPosterTier verifiesWithSize:size announcedLength:length etag:etag computedSha256:sha]) {
            [self finishWithFile:finalFile etag:etag length:size ledgerKey:ledgerKey resumedFrom:-1];
            return;
        }
        [fm removeItemAtPath:finalFile error:nil];
    }

    long long offset = [[[fm attributesOfItemAtPath:part error:nil] objectForKey:NSFileSize] longLongValue];
    if (length > 0 && offset > length) { [fm removeItemAtPath:part error:nil]; offset = 0; }
    long long fresh = 0;
    BOOL transferred = NO;     // the response ended cleanly
    if (!(length > 0 && offset == length)) {
        HttpManager *hMan = [[HttpManager alloc] initWithHost:_host.activeAddress uniqueId:[IdManager getUniqueId] serverCert:_host.serverCert];
        NSMutableURLRequest *request = [[hMan newAppAssetRequestWithAppId:self.app.id kind:@"poster" variant:nil etag:nil modified:nil] mutableCopy];
        request.timeoutInterval = ART_IDLE_TIMEOUT;
        NSString *range = [MLPosterTier rangeHeaderWithPartialBytes:offset];
        if (range != nil) {
            [request setValue:range forHTTPHeaderField:@"Range"];
            [request setValue:etag forHTTPHeaderField:@"If-Range"];
        }
        MLPosterDownload *download = [[MLPosterDownload alloc] init];
        download.manager = hMan;
        download.path = part;
        download.offset = offset;
        download.expectedEtag = etag;
        __weak typeof(self) weakSelf = self;
        download.shouldStop = ^BOOL{ return [weakSelf isCancelled]; };
        Log(LOG_I, @"[art] %@ %@/poster full: asking for %@ (%lld of %lld bytes on disk)", _host.name, self.app.id, range ?: @"the whole picture", offset, length);
        [download run:request];
        fresh = download.written;
        if (download.stopped) {
            // a launch or a stream began: the partial file stays for the next idle time
            Log(LOG_I, @"[art] %@ %@/poster full: stopped, a connection is starting (%lld bytes kept)", _host.name, self.app.id, offset + fresh);
            [MLArtLedger release:ledgerKey];
            _outcome = 3;
            return;
        }
        switch (download.action) {
            case MLPosterResumeAppend:
            case MLPosterResumeRestart:
                transferred = download.error == nil;
                break;
            case MLPosterResumeChanged: {
                // the host has another full picture now: what is on disk belongs to the old one
                NSString *newEtag = [download header:@"ETag"];
                Log(LOG_I, @"[art] %@ %@/poster full: the picture changed on the host (%@ -> %@)", _host.name, self.app.id, etag, newEtag ?: @"-");
                [fm removeItemAtPath:part error:nil];
                if (newEtag.length > 0) [AppAssetMeta setEntry:@{ @"etag": newEtag, @"length": @0, @"complete": @NO } forHost:hostUUID key:fullKey];
                [MLArtLedger release:ledgerKey];
                _outcome = 2;
                return;
            }
            case MLPosterResumeDiscard:
                Log(LOG_W, @"[art] %@ %@/poster full: the partial file could not be continued (status %ld); starting again later", _host.name, self.app.id, (long)download.status);
                [fm removeItemAtPath:part error:nil];
                [MLArtLedger fail:ledgerKey];
                _outcome = 4;
                return;
            default:
                Log(LOG_W, @"[art] %@ %@/poster full: failed (status %ld)", _host.name, self.app.id, (long)download.status);
                [MLArtLedger fail:ledgerKey];
                _outcome = 4;
                return;
        }
        if (!transferred) {
            // the connection dropped part-way: what arrived is on disk, the next request continues from there
            Log(LOG_I, @"[art] %@ %@/poster full: connection ended after %lld new bytes (%lld on disk): %@", _host.name, self.app.id, fresh, offset + fresh, download.error.localizedDescription);
            if (fresh > 0) { [MLArtLedger release:ledgerKey]; _outcome = 2; }
            else { [MLArtLedger fail:ledgerKey]; _outcome = 4; }
            return;
        }
    }
    long long size = [[[fm attributesOfItemAtPath:part error:nil] objectForKey:NSFileSize] longLongValue];
    if (length > 0 && size < length) {
        // the answer ended before the announced size: continue
        [MLArtLedger release:ledgerKey];
        _outcome = fresh > 0 ? 2 : 4;
        return;
    }
    NSString *sha = [MLPosterTier sha256HexOfEtag:etag] != nil ? [AppAssetRetriever sha256OfFile:part] : nil;
    if (![MLPosterTier verifiesWithSize:size announcedLength:length etag:etag computedSha256:sha]) {
        Log(LOG_W, @"[art] %@ %@/poster full: the file does not match the host's ETag (%lld bytes, sha %@); discarded", _host.name, self.app.id, size, sha ?: @"-");
        [fm removeItemAtPath:part error:nil];
        [MLArtLedger fail:ledgerKey];
        _outcome = 4;
        return;
    }
    [fm removeItemAtPath:finalFile error:nil];
    if (![fm moveItemAtPath:part toPath:finalFile error:nil]) { [MLArtLedger fail:ledgerKey]; _outcome = 4; return; }
    [self finishWithFile:finalFile etag:etag length:size ledgerKey:ledgerKey resumedFrom:offset];
}

/// The checked picture replaces the preview in one step (same box, same aspect: the apps page draws the new file in
/// place of the old), the cache notes it, and the page is told.
- (void) finishWithFile:(NSString*)file etag:(NSString*)etag length:(long long)length ledgerKey:(NSString*)ledgerKey resumedFrom:(long long)offset {
    NSString *artPath = [AppAssetManager artPathForApp:self.app kind:@"poster"];
    BOOL installed = [AppAssetRetriever installPath:artPath fromFile:file];
    [AppAssetMeta setEntry:@{ @"etag": etag, @"length": @(length), @"complete": @YES } forHost:_host.uuid key:[AppAssetRetriever metaKeyForFullOfApp:self.app]];
    [MLArtLedger succeed:ledgerKey];
    _outcome = 1;
    Log(LOG_I, @"[art] %@ %@/poster full: lossless picture %@ (%lld bytes, %@)", _host.name, self.app.id, installed ? @"swapped in" : @"cached, could not replace the file on screen", length,
        offset > 0 ? [NSString stringWithFormat:@"continued from byte %lld", offset] : @"in one go");
    if (installed) [self performSelectorOnMainThread:@selector(sendCallbackForApp:) withObject:self.app waitUntilDone:NO];
}

- (void) sendCallbackForApp:(TemporaryApp*)app {
    [self.callback receivedAssetForApp:app];
}

@end
