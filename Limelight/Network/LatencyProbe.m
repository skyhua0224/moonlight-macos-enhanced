//
//  LatencyProbe.m
//  Moonlight for macOS
//
//  Created by GitHub SkyHua on 2026/01/16.
//

#import "LatencyProbe.h"
#import "Utils.h"
#import "HostPathRank.h"
#import "Logger.h"

@implementation LatencyProbe

+ (NSNumber * _Nullable)icmpPingMsForAddress:(NSString *)address {
    if (![address isKindOfClass:[NSString class]] || address.length == 0) {
        return nil;
    }

    NSString *host = nil;
    NSString *port = nil;
    [Utils parseAddress:address intoHost:&host andPort:&port];
    if (host.length == 0) {
        return nil;
    }

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/sbin/ping";
    task.arguments = @[ @"-c", @"1", @"-W", @"1000", host ];

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];

    @try {
        [task launch];
    } @catch (NSException *exception) {
        return nil;
    }

    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];

    if (data.length == 0 || task.terminationStatus != 0) {
        return nil;
    }

    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (output.length == 0) {
        return nil;
    }

    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"time=([0-9.]+)\\s*ms" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:output options:0 range:NSMakeRange(0, output.length)];
    if (!match || match.numberOfRanges < 2) {
        return nil;
    }

    NSString *value = [output substringWithRange:[match rangeAtIndex:1]];
    double ms = [value doubleValue];
    if (ms <= 0) {
        return nil;
    }

    return @( MAX(1, (int)llround(ms)) );
}

static NSLock *sRttLock;
static NSMutableDictionary<NSString *, NSDictionary *> *sRttCache;       // address -> @{ms, when}
static NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *sStreamRecent;   // "uuid|address" -> recent samples
static NSDate *sStreamSaved;
static dispatch_queue_t sRttWriter;

+ (void)load {
    sRttLock = [[NSLock alloc] init];
    sRttCache = [NSMutableDictionary dictionary];
    sStreamRecent = [NSMutableDictionary dictionary];
    sRttWriter = dispatch_queue_create("std.skyhua.rtt-writer", DISPATCH_QUEUE_SERIAL);
}

+ (NSNumber * _Nullable)appRttMsForAddress:(NSString *)address probeTotalMs:(int)probeTotalMs {
    if (![address isKindOfClass:[NSString class]] || address.length == 0) {
        return nil;
    }
    [sRttLock lock];
    NSDictionary *cached = sRttCache[address.lowercaseString];
    [sRttLock unlock];
    if (cached != nil && -[(NSDate *)cached[@"when"] timeIntervalSinceNow] < 15.0) {
        return [cached[@"ms"] intValue] >= 0 ? cached[@"ms"] : nil;
    }
    NSString *host = nil;
    NSString *port = nil;
    [Utils parseAddress:address intoHost:&host andPort:&port];
    if (host.length == 0) {
        return nil;
    }
    HostAppRtt result;
    int rc = host_app_rtt_measure(host.UTF8String, port.length > 0 ? port.intValue : 47989, 5, 1500, &result);
    NSNumber *value = nil;
    if (rc == 0) {
        value = @(host_app_rtt_display_ms(result.median_us));
        Log(LOG_I, @"[latency] %@ probe total %d ms / app RTT %@ ms (median of %d, %d on an open connection, min %.1f max %.1f, handshake %.1f ms not counted)",
            address, probeTotalMs, value, result.samples, result.reused, result.min_us / 1000.0, result.max_us / 1000.0, result.connect_us / 1000.0);
    } else {
        Log(LOG_I, @"[latency] %@ probe total %d ms / app RTT unavailable (%d): no number is shown", address, probeTotalMs, rc);
    }
    [sRttLock lock];
    sRttCache[address.lowercaseString] = @{@"ms": value ?: @(-1), @"when": [NSDate date]};
    [sRttLock unlock];
    return value;
}

+ (NSString *)streamKeyForHost:(NSString *)uuid address:(NSString *)address {
    NSString *host = nil;
    NSString *port = nil;
    [Utils parseAddress:address ?: @"" intoHost:&host andPort:&port];
    return [NSString stringWithFormat:@"%@|%@:%@", uuid ?: @"", (host ?: @"").lowercaseString, port.length > 0 ? port : @"47989"];
}

+ (void)resetStreamRttWindowForHost:(NSString *)uuid address:(NSString *)address {
    NSString *key = [self streamKeyForHost:uuid address:address];
    [sRttLock lock];
    [sStreamRecent removeObjectForKey:key];
    [sRttLock unlock];
}

+ (void)noteStreamRttMs:(uint32_t)rttMs forHost:(NSString *)uuid address:(NSString *)address {
    if (rttMs == 0 || uuid.length == 0 || address.length == 0) {
        return;
    }
    NSString *key = [self streamKeyForHost:uuid address:address];
    int median = 0;
    BOOL save = NO;
    [sRttLock lock];
    NSMutableArray<NSNumber *> *recent = sStreamRecent[key];
    if (recent == nil) {
        recent = [NSMutableArray array];
        sStreamRecent[key] = recent;
    }
    [recent addObject:@(rttMs)];
    if (recent.count > 31) {
        [recent removeObjectAtIndex:0];
    }
    NSArray<NSNumber *> *sorted = [recent sortedArrayUsingSelector:@selector(compare:)];
    median = [sorted[sorted.count / 2] intValue];
    if (recent.count >= 5 && (sStreamSaved == nil || -[sStreamSaved timeIntervalSinceNow] > 10.0)) {
        sStreamSaved = [NSDate date];
        save = YES;
    }
    [sRttLock unlock];
    if (!save) {
        return;
    }
    // written after the lock is released, on a serial queue (UserDefaults posts a notification the main queue observes)
    dispatch_async(sRttWriter, ^{
        NSMutableDictionary *all = [([[NSUserDefaults standardUserDefaults] dictionaryForKey:@"MLStreamRtt"] ?: @{}) mutableCopy];
        all[key] = @{@"ms": @(median), @"when": @([[NSDate date] timeIntervalSince1970])};
        [[NSUserDefaults standardUserDefaults] setObject:all forKey:@"MLStreamRtt"];
        Log(LOG_I, @"[latency] stream RTT %@ = %d ms (median of recent control-stream samples)", key, median);
    });
}

+ (NSDictionary * _Nullable)lastStreamRttForHost:(NSString *)uuid address:(NSString *)address {
    NSDictionary *all = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"MLStreamRtt"];
    NSDictionary *entry = all[[self streamKeyForHost:uuid address:address]];
    if (![entry isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSNumber *ms = entry[@"ms"];
    NSNumber *when = entry[@"when"];
    if (ms == nil || when == nil || ms.intValue <= 0) {
        return nil;
    }
    return @{@"ms": ms, @"when": [NSDate dateWithTimeIntervalSince1970:when.doubleValue]};
}

@end


// MARK: - StreamPathHealth

static NSLock *sHealthLock;
static NSMutableDictionary<NSString *, NSMutableDictionary *> *sHealth;   // "uuid|host:port" -> {fail, ok, reason, detail}; "uuid|#" -> {n}
static dispatch_queue_t sHealthWriter;

static NSString *StreamHealthKey(NSString *uuid, NSString *address) {
    NSString *host = nil;
    NSString *port = nil;
    [Utils parseAddress:address ?: @"" intoHost:&host andPort:&port];
    return [NSString stringWithFormat:@"%@|%@:%@", uuid ?: @"", (host ?: @"").lowercaseString, port.length > 0 ? port : @"47989"];
}

@implementation StreamPathHealth

+ (void)load {
    sHealthLock = [[NSLock alloc] init];
    sHealthWriter = dispatch_queue_create("std.skyhua.stream-health-writer", DISPATCH_QUEUE_SERIAL);
}

+ (void)ensureLoaded {
    [sHealthLock lock];
    BOOL needLoad = sHealth == nil;
    [sHealthLock unlock];
    if (!needLoad) {
        return;
    }
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"MLStreamPathHealth"] ?: @{};
    NSMutableDictionary *copy = [NSMutableDictionary dictionary];
    for (NSString *key in saved) {
        if ([saved[key] isKindOfClass:[NSDictionary class]]) {
            copy[key] = [saved[key] mutableCopy];
        }
    }
    [sHealthLock lock];
    if (sHealth == nil) {
        sHealth = copy;
    }
    [sHealthLock unlock];
}

/// Writes on a serial queue, after the caller released the lock (UserDefaults posts a notification the main queue observes).
/// The snapshot is taken inside the queue block, so a later write can never be overwritten by an earlier snapshot.
+ (void)save {
    dispatch_async(sHealthWriter, ^{
        [sHealthLock lock];
        NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
        for (NSString *key in sHealth) {
            snapshot[key] = [sHealth[key] copy];
        }
        [sHealthLock unlock];
        [[NSUserDefaults standardUserDefaults] setObject:snapshot forKey:@"MLStreamPathHealth"];
    });
}

+ (void)recordFailureForHost:(NSString *)uuid address:(NSString *)address reason:(NSString *)reason detail:(NSString *)detail {
    if (uuid.length == 0 || address.length == 0) {
        return;
    }
    [self ensureLoaded];
    NSString *key = StreamHealthKey(uuid, address);
    NSString *countKey = [uuid stringByAppendingString:@"|#"];
    NSInteger consecutive = 0;
    [sHealthLock lock];
    NSMutableDictionary *entry = sHealth[key] ?: [NSMutableDictionary dictionary];
    entry[@"fail"] = @([[NSDate date] timeIntervalSince1970]);
    entry[@"reason"] = reason ?: @"";
    entry[@"detail"] = detail ?: @"";
    sHealth[key] = entry;
    NSMutableDictionary *count = sHealth[countKey] ?: [NSMutableDictionary dictionary];
    // failures older than the window are forgotten: a count from yesterday must not stop today's first reconnect
    double previousWhen = [count[@"when"] doubleValue];
    double nowSeconds = [[NSDate date] timeIntervalSince1970];
    BOOL stale = previousWhen > 0 && nowSeconds - previousWhen > HOST_PATH_HEALTH_WINDOW_SEC;
    consecutive = (stale ? 0 : [count[@"n"] integerValue]) + 1;
    count[@"n"] = @(consecutive);
    count[@"when"] = @(nowSeconds);
    sHealth[countKey] = count;
    [sHealthLock unlock];
    [self save];
    Log(LOG_W, @"[route] stream on %@ failed (%@ %@): %ld in a row", address, reason ?: @"", detail ?: @"", (long)consecutive);
}

+ (void)recordSuccessForHost:(NSString *)uuid address:(NSString *)address {
    if (uuid.length == 0 || address.length == 0) {
        return;
    }
    [self ensureLoaded];
    NSString *key = StreamHealthKey(uuid, address);
    [sHealthLock lock];
    NSMutableDictionary *entry = sHealth[key] ?: [NSMutableDictionary dictionary];
    entry[@"ok"] = @([[NSDate date] timeIntervalSince1970]);
    sHealth[key] = entry;
    sHealth[[uuid stringByAppendingString:@"|#"]] = [@{@"n": @0} mutableCopy];
    [sHealthLock unlock];
    [self save];
}

+ (NSDictionary *)recentFailureForHost:(NSString *)uuid address:(NSString *)address {
    [self ensureLoaded];
    NSString *key = StreamHealthKey(uuid, address);
    [sHealthLock lock];
    NSDictionary *entry = [sHealth[key] copy];
    [sHealthLock unlock];
    double failure = [entry[@"fail"] doubleValue];
    double success = [entry[@"ok"] doubleValue];
    double now = [[NSDate date] timeIntervalSince1970];
    if (!host_path_health_avoid((long long)failure, (long long)success, (long long)now)) {
        return nil;
    }
    return @{@"reason": entry[@"reason"] ?: @"", @"detail": entry[@"detail"] ?: @"", @"when": [NSDate dateWithTimeIntervalSince1970:failure]};
}

+ (BOOL)shouldAvoidHost:(NSString *)uuid address:(NSString *)address {
    return [self recentFailureForHost:uuid address:address] != nil;
}

+ (NSInteger)consecutiveFailuresForHost:(NSString *)uuid {
    [self ensureLoaded];
    [sHealthLock lock];
    NSDictionary *count = sHealth[[uuid stringByAppendingString:@"|#"]];
    NSInteger n = [count[@"n"] integerValue];
    double when = [count[@"when"] doubleValue];
    [sHealthLock unlock];
    if (when > 0 && [[NSDate date] timeIntervalSince1970] - when > HOST_PATH_HEALTH_WINDOW_SEC) {
        return 0;
    }
    return n;
}

+ (void)resetConsecutiveForHost:(NSString *)uuid {
    [self ensureLoaded];
    [sHealthLock lock];
    sHealth[[uuid stringByAppendingString:@"|#"]] = [@{@"n": @0} mutableCopy];
    [sHealthLock unlock];
    [self save];
}

@end
