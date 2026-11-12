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
    [self performSelectorOnMainThread:@selector(sendCallbackForApp:) withObject:self.app waitUntilDone:NO];
}

- (void) sendCallbackForApp:(TemporaryApp*)app {
    [self.callback receivedAssetForApp:app];
}

@end
