//
//  Logger.m
//  Moonlight
//
//  Created by Diego Waxemberg on 2/10/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//
//  Threading model
//  ---------------
//  Log() and friends run on the caller's thread (decode, network, input, main). They only do an
//  atomic level check, format the message once, take a timestamp and hand the line to the
//  logging queue; no file I/O, no regular expressions, no main-thread hop happens there.
//
//  Everything else is owned by ONE private serial queue (gLoggerQueue): sequence numbers, the
//  noise aggregation buckets, the repeat trackers, the open file handles, the timestamp cache and
//  the stderr mirror. Those statics are therefore only touched from that queue and need no locks.
//  The only state shared between threads is
//    - the settings atomics (minimum level, curated mode, input diagnostics),
//    - the pending list (gPending / gDrainScheduled / gDroppedCount), guarded by gPendingLock,
//    - the entry ring in LogBuffer, guarded by its own lock.
//

#import "Logger.h"

#import "LogBuffer.h"

#import <os/lock.h>
#import <stdatomic.h>
#import <unistd.h>

static const NSTimeInterval kWarnRepeatSuppressWindowSec = 1.0;
static const NSTimeInterval kNoiseAggregationWindowSec = 5.0;
static const unsigned long long kRawFileLogMaxBytes = 8 * 1024 * 1024;
static const unsigned long long kCuratedFileLogMaxBytes = 2 * 1024 * 1024;
static const NSTimeInterval kLogHandleRevalidateIntervalSec = 1.0;
// Distinct warning lines tracked for repeat suppression; beyond this the oldest state is dropped.
static const NSUInteger kWarnTrackerMaxEntries = 256;
// Lines waiting for the logging queue. Beyond this, anything below ERROR is dropped (and counted).
static const NSUInteger kPendingLineLimit = 20000;

static NSString * const kLoggerInputDiagnosticsDefaultsKey = @"debugLog.inputDiagnostics";

#pragma mark - Settings (atomics, read on hot paths)

static _Atomic(int) gLoggerMinimumLevel = LOG_I;
static atomic_bool gLoggerCuratedModeEnabled = true;
static atomic_bool gLoggerInputDiagnosticsEnabled = false;

// The input diagnostics switch used to be re-read from NSUserDefaults on every call. It is now
// seeded from the stored value once; later changes arrive through LoggerSetInputDiagnosticsEnabled.
static void LoggerSeedSettingsFromDefaults(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if ([defaults objectForKey:kLoggerInputDiagnosticsDefaultsKey] != nil) {
            atomic_store_explicit(&gLoggerInputDiagnosticsEnabled,
                                  [defaults boolForKey:kLoggerInputDiagnosticsDefaultsKey],
                                  memory_order_relaxed);
        }
    });
}

#pragma mark - Types

// A line on its way from the calling thread to the logging queue.
@interface LoggerPendingLine : NSObject
@property (nonatomic, readonly) LogLevel level;
@property (nonatomic, readonly, copy) NSString *tag;
@property (nonatomic, readonly, copy) NSString *message;
@property (nonatomic, readonly) NSTimeInterval timestamp;
- (instancetype)initWithLevel:(LogLevel)level tag:(NSString *)tag message:(NSString *)message timestamp:(NSTimeInterval)timestamp;
@end

@implementation LoggerPendingLine
- (instancetype)initWithLevel:(LogLevel)level tag:(NSString *)tag message:(NSString *)message timestamp:(NSTimeInterval)timestamp {
    self = [super init];
    if (self) {
        _level = level;
        _tag = [tag copy];
        _message = [message copy];
        _timestamp = timestamp;
    }
    return self;
}
@end

@interface LoggerRepeatState : NSObject
@property (nonatomic) NSTimeInterval last;
@property (nonatomic) NSInteger suppressed;
@end

@implementation LoggerRepeatState
@end

// Everything one batch wants to write, collected first and committed once.
@interface LoggerBatchOutput : NSObject
@property (nonatomic, strong) NSMutableString *raw;
@property (nonatomic, strong) NSMutableString *curated;
@property (nonatomic, strong) NSMutableString *standardError;
@property (nonatomic, strong) NSMutableArray<MLLogEntry *> *entries;
@property (nonatomic) BOOL curatedFileEnabled;
@end

@implementation LoggerBatchOutput
- (instancetype)init {
    self = [super init];
    if (self) {
        _raw = [NSMutableString string];
        _curated = [NSMutableString string];
        _standardError = [NSMutableString string];
        _entries = [NSMutableArray array];
        _curatedFileEnabled = atomic_load_explicit(&gLoggerCuratedModeEnabled, memory_order_relaxed);
    }
    return self;
}
@end

#pragma mark - State shared between threads

static char gLoggerQueueSpecificKey;
static dispatch_queue_t gLoggerQueue = nil;

static os_unfair_lock gPendingLock = OS_UNFAIR_LOCK_INIT;
static NSMutableArray<LoggerPendingLine *> *gPending = nil;  // gPendingLock
static BOOL gDrainScheduled = NO;                             // gPendingLock
static NSUInteger gDroppedCount = 0;                          // gPendingLock

#pragma mark - State owned by the logging queue

static NSUInteger gNextSequence = 0;
static NSMutableDictionary<NSString *, LoggerRepeatState *> *gRuntimeWarnTracker = nil;
static NSMutableDictionary<NSString *, LoggerRepeatState *> *gCuratedWarnTracker = nil;
static NSMutableDictionary<NSString *, NSMutableDictionary *> *gCuratedNoiseAggregation = nil;
static BOOL gNoiseFlushScheduled = NO;
static NSString *gLogDirectoryPath = nil;
static NSString *gRawFileLogPath = nil;
static NSString *gCuratedFileLogPath = nil;
// Open append handles, keyed by log path.
static NSMutableDictionary<NSString *, NSFileHandle *> *gOpenLogHandles = nil;
static NSMutableDictionary<NSString *, NSNumber *> *gOpenLogValidatedAt = nil;
static NSString *gProcessLabel = nil;

static void LoggerDrainPending(void);

static dispatch_queue_t LoggerQueue(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        gLoggerQueue = dispatch_queue_create("com.moonlight.logger", attributes);
        dispatch_queue_set_specific(gLoggerQueue, &gLoggerQueueSpecificKey, &gLoggerQueueSpecificKey, NULL);

        gPending = [NSMutableArray arrayWithCapacity:256];
        gRuntimeWarnTracker = [NSMutableDictionary dictionary];
        gCuratedWarnTracker = [NSMutableDictionary dictionary];
        gCuratedNoiseAggregation = [NSMutableDictionary dictionary];
        gOpenLogHandles = [NSMutableDictionary dictionary];
        gOpenLogValidatedAt = [NSMutableDictionary dictionary];
        gProcessLabel = [NSString stringWithFormat:@"%@[%d]", [[NSProcessInfo processInfo] processName], (int)getpid()];
    });
    return gLoggerQueue;
}

static BOOL LoggerIsOnLoggingQueue(void) {
    return dispatch_get_specific(&gLoggerQueueSpecificKey) != NULL;
}

#pragma mark - Formatting helpers

static NSTimeInterval LoggerNowTimestamp(void) {
    return CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970;
}

// "yyyy-MM-dd HH:mm:ss.SSS". The date/time part is formatted once per second and cached,
// the milliseconds are appended. Logging queue only.
static NSString *LoggerTimestampText(NSTimeInterval timestamp) {
    static NSDateFormatter *formatter = nil;
    static long long cachedSecond = LLONG_MIN;
    static NSString *cachedPrefix = nil;
    if (formatter == nil) {
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    }

    long long second = (long long)floor(timestamp);
    if (second != cachedSecond || cachedPrefix == nil) {
        cachedPrefix = [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)second]];
        cachedSecond = second;
    }
    int milliseconds = (int)((timestamp - (NSTimeInterval)second) * 1000.0);
    milliseconds = MAX(0, MIN(999, milliseconds));
    return [NSString stringWithFormat:@"%@.%03d", cachedPrefix, milliseconds];
}

static NSString *LogPrefixForLevel(LogLevel level) {
    switch (level) {
        case LOG_D: return PRFX_DEBUG;
        case LOG_I: return PRFX_INFO;
        case LOG_W: return PRFX_WARN;
        case LOG_E: return PRFX_ERROR;
        default: return @"";
    }
}

static NSString *FormatLogLine(LogLevel level, NSString *message) {
    return [NSString stringWithFormat:@"%@ %@", LogPrefixForLevel(level), message ?: @""];
}

static BOOL IsHighFrequencyDiagnosticLine(NSString *line) {
    if (line.length == 0) {
        return NO;
    }

    return [line rangeOfString:@"[inputdiag]" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [line rangeOfString:@"[clickdiag]" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [line rangeOfString:@"[diag] Pull renderer dequeued frame=" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL IsPersistableInputDiagnosticLine(NSString *line) {
    if (line.length == 0) {
        return NO;
    }

    if ([line rangeOfString:@"[clickdiag]" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return YES;
    }

    if ([line rangeOfString:@"[inputdiag]" options:NSCaseInsensitiveSearch].location == NSNotFound) {
        return NO;
    }

    return [line rangeOfString:@"scroll" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [line rangeOfString:@"mouse-button" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL LoggerInputDiagnosticsEnabledFlag(void) {
    LoggerSeedSettingsFromDefaults();
    return atomic_load_explicit(&gLoggerInputDiagnosticsEnabled, memory_order_relaxed);
}

static BOOL ShouldForcePersistDiagnosticLine(LogLevel level, NSString *line) {
    return level == LOG_D && LoggerInputDiagnosticsEnabledFlag() && IsPersistableInputDiagnosticLine(line);
}

// Cheap pre-check done BEFORE a below-minimum debug line is formatted: input diagnostics lines carry
// their marker in the format string (or the tag), so a line without it can never be force-persisted.
static BOOL FormatMayCarryDiagnosticMarker(NSString *fmt, NSString *tag) {
    if (fmt != nil &&
        ([fmt rangeOfString:@"[inputdiag]" options:NSCaseInsensitiveSearch].location != NSNotFound ||
         [fmt rangeOfString:@"[clickdiag]" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
        return YES;
    }
    return tag != nil &&
           ([tag rangeOfString:@"[inputdiag]" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [tag rangeOfString:@"[clickdiag]" options:NSCaseInsensitiveSearch].location != NSNotFound);
}

static BOOL IsPersistableDiagnosticMessage(NSString *tag, NSString *message) {
    if (IsPersistableInputDiagnosticLine(message)) {
        return YES;
    }
    return tag.length > 0 && IsPersistableInputDiagnosticLine([tag stringByAppendingString:message ?: @""]);
}

#pragma mark - Noise classification (logging queue)

// Compiling a pattern for every logged noise line is expensive; the set of patterns is small and fixed.
static NSRegularExpression *CachedRegularExpression(NSString *pattern) {
    static NSMutableDictionary<NSString *, NSRegularExpression *> *cache = nil;
    if (cache == nil) {
        cache = [NSMutableDictionary dictionary];
    }

    NSRegularExpression *regex = cache[pattern];
    if (regex != nil) {
        return regex;
    }
    NSError *error = nil;
    regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:&error];
    if (error != nil || regex == nil) {
        return nil;
    }
    cache[pattern] = regex;
    return regex;
}

static NSString *ExtractFirstMatch(NSString *input, NSString *pattern) {
    if (input.length == 0 || pattern.length == 0) {
        return nil;
    }
    NSRegularExpression *regex = CachedRegularExpression(pattern);
    if (regex == nil) {
        return nil;
    }
    NSTextCheckingResult *match = [regex firstMatchInString:input options:0 range:NSMakeRange(0, input.length)];
    if (match == nil || match.numberOfRanges < 2) {
        return nil;
    }
    NSRange range = [match rangeAtIndex:1];
    if (range.location == NSNotFound) {
        return nil;
    }
    return [input substringWithRange:range];
}

static NSString *ExtractErrorCode(NSString *line) {
    NSString *code = ExtractFirstMatch(line, @"Code=(-?\\d+)");
    if (code.length > 0) {
        return [NSString stringWithFormat:@"Error code %@", code];
    }
    code = ExtractFirstMatch(line, @"(-1001|-1004|-1005)");
    if (code.length > 0) {
        return [NSString stringWithFormat:@"Error code %@", code];
    }
    return @"unknown error code";
}

static BOOL IsServerCertificateMismatchLine(NSString *line) {
    return [line rangeOfString:@"Server certificate mismatch" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL IsIncorrectHostLine(NSString *line) {
    return [line rangeOfString:@"Received response from incorrect host:" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSString *ExtractIncorrectHostIdentifier(NSString *line) {
    NSString *identifier = ExtractFirstMatch(line, @"incorrect host:\\s*([^\\s]+)");
    return identifier.length > 0 ? identifier : nil;
}

static NSString *ExtractExpectedHostIdentifier(NSString *line) {
    NSString *identifier = ExtractFirstMatch(line, @"expected:\\s*([^\\s]+)");
    return identifier.length > 0 ? identifier : nil;
}

static NSString *ShortHostIdentifier(NSString *identifier) {
    if (identifier.length <= 8) {
        return identifier;
    }
    return [[identifier substringToIndex:8] stringByAppendingString:@"…"];
}

static NSString *ExtractDiscoveryHost(NSString *line) {
    NSString *host = ExtractFirstMatch(line, @"Discovery summary for\\s+([^:]+):");
    if (host.length > 0) {
        return host;
    }
    host = ExtractFirstMatch(line, @"Resolved address:\\s+([^\\s]+)\\s+->");
    if (host.length > 0) {
        return host;
    }
    return @"unknown";
}

static NSString *ExtractDiscoveryState(NSString *line) {
    NSString *state = ExtractFirstMatch(line, @":\\s*(\\d+\\s+online,\\s*\\d+\\s+offline)");
    if (state.length > 0) {
        return state;
    }
    return nil;
}

static NSString *ExtractTargetEndpoint(NSString *line) {
    NSString *target = ExtractFirstMatch(line, @"((?:\\d{1,3}\\.){3}\\d{1,3}:\\d+)");
    if (target.length > 0) {
        return target;
    }
    target = ExtractFirstMatch(line, @"(\\[[0-9a-fA-F:]+\\]:\\d+)");
    if (target.length > 0) {
        return target;
    }
    target = ExtractFirstMatch(line, @"https?://([^\\s/]+)");
    if (target.length > 0) {
        return target;
    }
    return @"unknown target";
}

static MLLogNoiseCategory DetectNoiseCategory(NSString *line) {
    if (line.length == 0) {
        return MLLogNoiseCategoryNone;
    }
    if ([line rangeOfString:@"Discovery summary for " options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [line rangeOfString:@"Resolved address:" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return MLLogNoiseCategoryDiscoveryChatter;
    }
    if (IsServerCertificateMismatchLine(line) || IsIncorrectHostLine(line)) {
        return MLLogNoiseCategoryHostIdentityMismatch;
    }
    if ([line rangeOfString:@"Internal inconsistency in menus" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return MLLogNoiseCategoryAppKitMenuInconsistency;
    }
    if ([line rangeOfString:@"NSURLErrorDomain" options:NSCaseInsensitiveSearch].location != NSNotFound &&
        ([line rangeOfString:@"-1001"].location != NSNotFound ||
         [line rangeOfString:@"-1004"].location != NSNotFound ||
         [line rangeOfString:@"-1005"].location != NSNotFound)) {
        return MLLogNoiseCategorySystemTransportFallback;
    }
    if ([line rangeOfString:@"nw_" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [line rangeOfString:@"tcp_input" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [line rangeOfString:@"Request failed with error" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        ([line rangeOfString:@"Connection " options:NSCaseInsensitiveSearch].location != NSNotFound &&
         [line rangeOfString:@"failed" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
        ([line rangeOfString:@"Task <" options:NSCaseInsensitiveSearch].location != NSNotFound &&
         [line rangeOfString:@"finished with error" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
        return MLLogNoiseCategoryNetworkStackNoise;
    }
    return MLLogNoiseCategoryNone;
}

static NSString *NoiseCategoryDisplayName(MLLogNoiseCategory category) {
    switch (category) {
        case MLLogNoiseCategoryAppKitMenuInconsistency:
            return @"AppKit Menu Inconsistency";
        case MLLogNoiseCategoryNetworkStackNoise:
            return @"Network Stack Noise";
        case MLLogNoiseCategorySystemTransportFallback:
            return @"System Transport Fallback";
        case MLLogNoiseCategoryDiscoveryChatter:
            return @"Discovery Chatter";
        case MLLogNoiseCategoryHostIdentityMismatch:
            return @"Host Identity Mismatch";
        default:
            return @"System Noise";
    }
}

static BOOL IsGeneratedCuratedNoiseSummaryLine(NSString *line) {
    if (line.length == 0) {
        return NO;
    }

    for (NSInteger category = MLLogNoiseCategoryAppKitMenuInconsistency;
         category <= MLLogNoiseCategoryHostIdentityMismatch;
         category++) {
        NSString *prefix = [NSString stringWithFormat:@"%@ %@:", PRFX_WARN, NoiseCategoryDisplayName((MLLogNoiseCategory)category)];
        if ([line hasPrefix:prefix]) {
            return YES;
        }
    }

    return NO;
}

static BOOL ShouldBypassCuratedWarnSuppression(NSString *line) {
    if (line.length == 0) {
        return NO;
    }

    if ([line hasPrefix:[NSString stringWithFormat:@"%@ [curated]", PRFX_WARN]]) {
        return YES;
    }

    return IsGeneratedCuratedNoiseSummaryLine(line);
}

static NSString *NoiseAggregationKey(NSString *line, MLLogNoiseCategory category) {
    if (line.length == 0) {
        return nil;
    }

    if (category == MLLogNoiseCategoryDiscoveryChatter) {
        NSString *host = ExtractDiscoveryHost(line);
        NSString *state = ExtractDiscoveryState(line);
        if ([line rangeOfString:@"Discovery summary for " options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return [NSString stringWithFormat:@"discovery-summary:%@:%@", host ?: @"unknown", state ?: @"unknown"];
        }
        if ([line rangeOfString:@"Resolved address:" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return [NSString stringWithFormat:@"resolved-address:%@", host ?: @"unknown"];
        }
    }
    if (category == MLLogNoiseCategoryHostIdentityMismatch) {
        return @"host-identity-mismatch";
    }

    NSString *errorCode = ExtractErrorCode(line);
    NSString *target = ExtractTargetEndpoint(line);
    if ([line rangeOfString:@"Request failed with error" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return [NSString stringWithFormat:@"request-failed:%@", errorCode ?: @"unknown error code"];
    }
    if ([line rangeOfString:@"NSURLErrorDomain" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return [NSString stringWithFormat:@"nsurl:%@:%@", errorCode ?: @"unknown error code", target ?: @"unknown target"];
    }
    if ([line rangeOfString:@"Task <" options:NSCaseInsensitiveSearch].location != NSNotFound &&
        [line rangeOfString:@"finished with error" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return [NSString stringWithFormat:@"task-error:%@:%@", errorCode ?: @"unknown error code", target ?: @"unknown target"];
    }
    if ([line rangeOfString:@"Connection " options:NSCaseInsensitiveSearch].location != NSNotFound &&
        [line rangeOfString:@"failed" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return [NSString stringWithFormat:@"conn-failed:%@:%@", errorCode ?: @"unknown error code", target ?: @"unknown target"];
    }

    return [NSString stringWithFormat:@"noise:%ld:%@", (long)category, line];
}

#pragma mark - Log files (logging queue)

static NSString *EnsureLogDirectoryPath(void) {
    if (gLogDirectoryPath != nil) {
        return gLogDirectoryPath;
    }

    NSString *libraryPath = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    if (libraryPath.length == 0) {
        return nil;
    }

    NSString *logDir = [libraryPath stringByAppendingPathComponent:@"Logs/Moonlight"];
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:logDir withIntermediateDirectories:YES attributes:nil error:&dirError];
    if (dirError != nil) {
        NSLog(@"<WARN> Failed to create Moonlight log directory: %@", dirError.localizedDescription);
    }

    gLogDirectoryPath = logDir;
    return gLogDirectoryPath;
}

static NSString *EnsureRawFileLogPath(void) {
    if (gRawFileLogPath != nil) {
        return gRawFileLogPath;
    }
    NSString *dir = EnsureLogDirectoryPath();
    if (dir.length == 0) {
        return nil;
    }
    gRawFileLogPath = [dir stringByAppendingPathComponent:@"moonlight-debug.log"];
    return gRawFileLogPath;
}

static NSString *EnsureCuratedFileLogPath(void) {
    if (gCuratedFileLogPath != nil) {
        return gCuratedFileLogPath;
    }
    NSString *dir = EnsureLogDirectoryPath();
    if (dir.length == 0) {
        return nil;
    }
    gCuratedFileLogPath = [dir stringByAppendingPathComponent:@"moonlight-debug-curated.log"];
    return gCuratedFileLogPath;
}

static void RotateFileLogIfNeeded(NSString *logPath, unsigned long long maxBytes) {
    if (logPath.length == 0) {
        return;
    }

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:logPath error:nil];
    unsigned long long size = [attrs fileSize];
    if (size < maxBytes) {
        return;
    }

    NSString *rotatedPath = [logPath stringByAppendingString:@".1"];
    [[NSFileManager defaultManager] removeItemAtPath:rotatedPath error:nil];
    NSError *moveError = nil;
    [[NSFileManager defaultManager] moveItemAtPath:logPath toPath:rotatedPath error:&moveError];
    if (moveError != nil) {
        NSLog(@"<WARN> Failed rotating log file: %@", moveError.localizedDescription);
    }
}

static void CloseCachedLogHandle(NSString *logPath) {
    NSFileHandle *handle = gOpenLogHandles[logPath];
    if (handle != nil) {
        @try {
            [handle closeFile];
        } @catch (NSException *exception) {
            // Already closed or invalid; nothing else to release.
        }
    }
    [gOpenLogHandles removeObjectForKey:logPath];
    [gOpenLogValidatedAt removeObjectForKey:logPath];
}

// Opens (creating it with a header when missing) the log file for appending and caches the handle.
static NSFileHandle *OpenCachedLogHandle(NSString *logPath, NSString *title) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
        NSString *header = [NSString stringWithFormat:@"===== %@ started %@ =====\n", title, LoggerTimestampText(LoggerNowTimestamp())];
        [header writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (file == nil) {
        return nil;
    }
    gOpenLogHandles[logPath] = file;
    gOpenLogValidatedAt[logPath] = @(CFAbsoluteTimeGetCurrent());
    return file;
}

// Appends `text` (already newline terminated lines) with ONE write. The logging queue is the only
// writer, so the cached handles need no lock.
static void AppendTextToLogFile(NSString *logPath, NSString *text, NSString *title, unsigned long long maxBytes) {
    if (text.length == 0 || logPath.length == 0) {
        return;
    }

    NSFileHandle *file = gOpenLogHandles[logPath];
    if (file != nil) {
        NSTimeInterval now = CFAbsoluteTimeGetCurrent();
        NSTimeInterval validatedAt = [gOpenLogValidatedAt[logPath] doubleValue];
        if (now - validatedAt >= kLogHandleRevalidateIntervalSec) {
            // The file may have been removed (for example by clearing the log directory); reopen if so.
            if ([[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
                gOpenLogValidatedAt[logPath] = @(now);
            } else {
                CloseCachedLogHandle(logPath);
                file = nil;
            }
        }
    }

    if (file == nil) {
        RotateFileLogIfNeeded(logPath, maxBytes);
        file = OpenCachedLogHandle(logPath, title);
        if (file == nil) {
            return;
        }
    }

    @try {
        unsigned long long endOffset = [file seekToEndOfFile];
        if (endOffset >= maxBytes) {
            CloseCachedLogHandle(logPath);
            RotateFileLogIfNeeded(logPath, maxBytes);
            file = OpenCachedLogHandle(logPath, title);
            if (file == nil) {
                return;
            }
            [file seekToEndOfFile];
        }

        NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
        if (data.length > 0) {
            [file writeData:data];
        }
    } @catch (NSException *exception) {
        NSLog(@"<WARN> Failed writing log file: %@", exception.reason);
        CloseCachedLogHandle(logPath);
    }
}

// One write(2) per batch. Plain stderr rather than NSLog: NSLog costs a formatter, a lock and a
// trip through the unified log for every line.
static void WriteToStandardError(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
    const char *bytes = (const char *)data.bytes;
    size_t remaining = data.length;
    while (remaining > 0) {
        ssize_t written = write(STDERR_FILENO, bytes, remaining);
        if (written <= 0) {
            break;
        }
        bytes += written;
        remaining -= (size_t)written;
    }
}

static void CommitBatchOutput(LoggerBatchOutput *output) {
    // The in-memory store first: viewers should not wait for the disk.
    if (output.entries.count > 0) {
        [[LogBuffer shared] appendEntries:output.entries];
    }
    if (output.raw.length > 0) {
        AppendTextToLogFile(EnsureRawFileLogPath(), output.raw, @"Moonlight raw debug log", kRawFileLogMaxBytes);
    }
    if (output.curated.length > 0) {
        AppendTextToLogFile(EnsureCuratedFileLogPath(), output.curated, @"Moonlight curated debug log", kCuratedFileLogMaxBytes);
    }
    if (output.standardError.length > 0) {
        WriteToStandardError(output.standardError);
    }
}

#pragma mark - Curated log and entries (logging queue)

static MLLogEntry *MakeEntry(NSTimeInterval timestamp, NSString *timestampText, LogLevel level, NSString *tag,
                             NSString *message, NSString *line, NSString *fileLine,
                             MLLogNoiseCategory category, BOOL inRaw, BOOL inCurated, BOOL isSummary) {
    gNextSequence += 1;
    return [[MLLogEntry alloc] initWithSequence:gNextSequence
                                      timestamp:timestamp
                                  timestampText:timestampText
                                          level:level
                                            tag:tag
                                        message:message
                                           line:line
                                       fileLine:fileLine
                                  noiseCategory:category
                                          inRaw:inRaw
                                      inCurated:inCurated
                                      isSummary:isSummary];
}

// A curated-only WARN line the logger generates itself: a noise summary or a repeat summary.
static void EmitGeneratedCuratedLine(LoggerBatchOutput *output, NSTimeInterval timestamp, NSString *messageText,
                                     MLLogNoiseCategory category) {
    NSString *timestampText = LoggerTimestampText(timestamp);
    NSString *line = FormatLogLine(LOG_W, messageText);
    NSString *fileLine = [NSString stringWithFormat:@"[%@] %@", timestampText, line];
    if (output.curatedFileEnabled) {
        [output.curated appendString:fileLine];
        [output.curated appendString:@"\n"];
    }
    [output.entries addObject:MakeEntry(timestamp, timestampText, LOG_W, nil, messageText, line, fileLine,
                                        category, NO, YES, YES)];
}

static void PruneWarnTracker(NSMutableDictionary<NSString *, LoggerRepeatState *> *tracker, NSTimeInterval now) {
    NSMutableArray<NSString *> *stale = [NSMutableArray array];
    [tracker enumerateKeysAndObjectsUsingBlock:^(NSString *key, LoggerRepeatState *state, BOOL *stop) {
        if (now - state.last >= kWarnRepeatSuppressWindowSec) {
            [stale addObject:key];
        }
    }];
    [tracker removeObjectsForKeys:stale];
    if (tracker.count >= kWarnTrackerMaxEntries) {
        // Everything is recent; forgetting the state only means a repeat is not suppressed once.
        [tracker removeAllObjects];
    }
}

// Repeat suppression for warning lines. Returns YES when the line should be shown. The first
// occurrence always passes; repeats within the window are counted and reported by the next
// occurrence after the window, via `outSuppressedRun`.
static BOOL WarnRepeatPasses(NSMutableDictionary<NSString *, LoggerRepeatState *> *tracker, NSString *line,
                             NSTimeInterval now, NSInteger *outSuppressedRun) {
    *outSuppressedRun = 0;
    LoggerRepeatState *state = tracker[line];
    if (state == nil) {
        if (tracker.count >= kWarnTrackerMaxEntries) {
            PruneWarnTracker(tracker, now);
        }
        state = [[LoggerRepeatState alloc] init];
        state.last = now;
        state.suppressed = 0;
        tracker[line] = state;
        return YES;
    }

    if (now - state.last < kWarnRepeatSuppressWindowSec) {
        state.suppressed += 1;
        return NO;
    }

    *outSuppressedRun = state.suppressed;
    state.suppressed = 0;
    state.last = now;
    return YES;
}

// Decides whether an ordinary (non-noise) line is part of the curated log.
static BOOL OrdinaryLinePassesCuratedFilter(NSString *line, LogLevel level, NSTimeInterval timestamp,
                                            LoggerBatchOutput *output) {
    if (level != LOG_W || ShouldBypassCuratedWarnSuppression(line)) {
        return YES;
    }

    NSInteger suppressedRun = 0;
    BOOL passes = WarnRepeatPasses(gCuratedWarnTracker, line, timestamp, &suppressedRun);
    if (suppressedRun > 0) {
        EmitGeneratedCuratedLine(output, timestamp,
                                 [NSString stringWithFormat:@"[curated] repeated for %.1fs: %ld times (last: %@)",
                                                            kWarnRepeatSuppressWindowSec, (long)suppressedRun, line],
                                 MLLogNoiseCategoryNone);
    }
    return passes;
}

static BOOL FlushOneCuratedNoiseBucket(NSMutableDictionary *bucket, NSTimeInterval now, BOOL force,
                                       LoggerBatchOutput *output) {
    if (bucket == nil) {
        return YES;
    }

    NSInteger categoryRaw = [bucket[@"category"] integerValue];
    MLLogNoiseCategory category = (MLLogNoiseCategory)categoryRaw;
    NSTimeInterval start = [bucket[@"start"] doubleValue];
    NSInteger count = [bucket[@"count"] integerValue];
    NSString *errorCode = bucket[@"errorCode"];
    NSString *target = bucket[@"target"];
    NSString *sampleLine = bucket[@"sampleLine"];
    NSString *discoveryHost = bucket[@"discoveryHost"];
    NSString *discoveryState = bucket[@"discoveryState"];
    NSInteger certificateMismatchCount = [bucket[@"certificateMismatchCount"] integerValue];
    NSInteger incorrectHostCount = [bucket[@"incorrectHostCount"] integerValue];
    NSString *incorrectHost = bucket[@"incorrectHost"];
    NSString *expectedHost = bucket[@"expectedHost"];

    if (category == MLLogNoiseCategoryNone || count <= 0) {
        return YES;
    }
    if (!force && (now - start) < kNoiseAggregationWindowSec) {
        return NO;
    }

    NSString *summary = nil;
    switch (category) {
        case MLLogNoiseCategoryDiscoveryChatter:
            if ([sampleLine rangeOfString:@"Resolved address:" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                summary = [NSString stringWithFormat:@"%@: in %.0fs, %ld occurrences (repeated address resolution: %@)",
                           NoiseCategoryDisplayName(category),
                           kNoiseAggregationWindowSec,
                           (long)count,
                           discoveryHost.length > 0 ? discoveryHost : @"unknown"];
            } else {
                summary = [NSString stringWithFormat:@"%@: in %.0fs, %ld occurrences (%@, %@)",
                           NoiseCategoryDisplayName(category),
                           kNoiseAggregationWindowSec,
                           (long)count,
                           discoveryHost.length > 0 ? discoveryHost : @"unknown",
                           discoveryState.length > 0 ? discoveryState : @"state changed"];
            }
            break;
        case MLLogNoiseCategoryHostIdentityMismatch: {
            NSMutableArray<NSString *> *parts = [NSMutableArray array];
            if (certificateMismatchCount > 0) {
                [parts addObject:[NSString stringWithFormat:@"certificate mismatches: %ld", (long)certificateMismatchCount]];
            }
            if (incorrectHostCount > 0) {
                [parts addObject:[NSString stringWithFormat:@"incorrect hosts: %ld", (long)incorrectHostCount]];
            }
            if (expectedHost.length > 0) {
                [parts addObject:[NSString stringWithFormat:@"expected %@", ShortHostIdentifier(expectedHost)]];
            }
            if (incorrectHost.length > 0) {
                [parts addObject:[NSString stringWithFormat:@"received %@", ShortHostIdentifier(incorrectHost)]];
            }
            NSString *detail = parts.count > 0 ? [parts componentsJoinedByString:@", "] : @"host identity verification failed";
            summary = [NSString stringWithFormat:@"%@: in %.0fs, %ld occurrences (%@)",
                       NoiseCategoryDisplayName(category),
                       kNoiseAggregationWindowSec,
                       (long)count,
                       detail];
            break;
        }
        default:
            summary = [NSString stringWithFormat:@"%@: in %.0fs, %ld entries (primary cause: %@, target: %@)",
                       NoiseCategoryDisplayName(category),
                       kNoiseAggregationWindowSec,
                       (long)count,
                       errorCode.length > 0 ? errorCode : @"unknown error code",
                       target.length > 0 ? target : @"unknown target"];
            break;
    }

    EmitGeneratedCuratedLine(output, now, summary, category);
    return YES;
}

static void FlushCuratedNoiseAggregation(NSTimeInterval now, BOOL force, LoggerBatchOutput *output) {
    if (gCuratedNoiseAggregation.count == 0) {
        return;
    }

    NSArray<NSString *> *keys = [gCuratedNoiseAggregation allKeys];
    for (NSString *key in keys) {
        NSMutableDictionary *bucket = gCuratedNoiseAggregation[key];
        if (![bucket isKindOfClass:[NSMutableDictionary class]]) {
            [gCuratedNoiseAggregation removeObjectForKey:key];
            continue;
        }
        if (FlushOneCuratedNoiseBucket(bucket, now, force, output)) {
            [gCuratedNoiseAggregation removeObjectForKey:key];
        }
    }
}

static void AggregateNoiseLine(NSString *line, MLLogNoiseCategory category, NSTimeInterval now) {
    NSString *bucketKey = NoiseAggregationKey(line, category);
    if (bucketKey.length == 0) {
        bucketKey = [NSString stringWithFormat:@"noise:%ld", (long)category];
    }
    NSMutableDictionary *bucket = gCuratedNoiseAggregation[bucketKey];
    if (bucket == nil) {
        bucket = [@{
            @"category": @(category),
            @"start": @(now),
            @"count": @(0),
        } mutableCopy];
        gCuratedNoiseAggregation[bucketKey] = bucket;
    }

    NSInteger count = [bucket[@"count"] integerValue];
    bucket[@"count"] = @(count + 1);
    bucket[@"errorCode"] = ExtractErrorCode(line);
    bucket[@"target"] = ExtractTargetEndpoint(line);
    bucket[@"sampleLine"] = line;
    bucket[@"discoveryHost"] = ExtractDiscoveryHost(line);
    NSString *discoveryState = ExtractDiscoveryState(line);
    if (discoveryState.length > 0) {
        bucket[@"discoveryState"] = discoveryState;
    } else {
        [bucket removeObjectForKey:@"discoveryState"];
    }
    if (category == MLLogNoiseCategoryHostIdentityMismatch) {
        if (IsServerCertificateMismatchLine(line)) {
            NSInteger certificateMismatchCount = [bucket[@"certificateMismatchCount"] integerValue];
            bucket[@"certificateMismatchCount"] = @(certificateMismatchCount + 1);
        }
        if (IsIncorrectHostLine(line)) {
            NSInteger incorrectHostCount = [bucket[@"incorrectHostCount"] integerValue];
            bucket[@"incorrectHostCount"] = @(incorrectHostCount + 1);
        }

        NSString *incorrectHost = ExtractIncorrectHostIdentifier(line);
        if (incorrectHost.length > 0) {
            bucket[@"incorrectHost"] = incorrectHost;
        }

        NSString *expectedHost = ExtractExpectedHostIdentifier(line);
        if (expectedHost.length > 0) {
            bucket[@"expectedHost"] = expectedHost;
        }
    }
}

static void AppendStandardErrorLine(LoggerBatchOutput *output, NSString *timestampText, NSString *text) {
    [output.standardError appendFormat:@"%@ %@ %@\n", timestampText, gProcessLabel, text];
}

#pragma mark - Batch processing (logging queue)

static void ProcessPendingLine(LoggerPendingLine *pending, LoggerBatchOutput *output) {
    LogLevel level = pending.level;
    NSString *message = pending.message ?: @"";
    NSString *tag = pending.tag;
    NSString *display = tag != nil ? [NSString stringWithFormat:@"(%@) %@", tag, message] : message;
    NSString *line = FormatLogLine(level, display);

    // High-frequency diagnostics (mouse moves, per-frame traces) are only kept when explicitly
    // force-persisted; otherwise they touch neither the files, nor the store, nor stderr.
    BOOL highFrequency = IsHighFrequencyDiagnosticLine(line);
    if (highFrequency && !ShouldForcePersistDiagnosticLine(level, line)) {
        return;
    }

    NSTimeInterval timestamp = pending.timestamp;
    NSString *timestampText = LoggerTimestampText(timestamp);
    NSString *fileLine = [NSString stringWithFormat:@"[%@] %@", timestampText, line];

    [output.raw appendString:fileLine];
    [output.raw appendString:@"\n"];

    // Curated log: expired noise buckets are summarised first, then the line is either folded into
    // a bucket (system chatter), checked for repeats (warnings), or passed through.
    FlushCuratedNoiseAggregation(timestamp, NO, output);
    MLLogNoiseCategory category = DetectNoiseCategory(line);
    BOOL inCurated = NO;
    if (category != MLLogNoiseCategoryNone) {
        AggregateNoiseLine(line, category, timestamp);
    } else {
        inCurated = OrdinaryLinePassesCuratedFilter(line, level, timestamp, output);
        if (inCurated && output.curatedFileEnabled) {
            [output.curated appendString:fileLine];
            [output.curated appendString:@"\n"];
        }
    }

    [output.entries addObject:MakeEntry(timestamp, timestampText, level, tag, display, line, fileLine,
                                        category, YES, inCurated, NO)];

    // Mirror to stderr (the old NSLog output). Repeated warnings within a second are collapsed.
    if (!highFrequency) {
        BOOL shouldPrint = YES;
        if (level == LOG_W) {
            NSInteger suppressedRun = 0;
            shouldPrint = WarnRepeatPasses(gRuntimeWarnTracker, line, timestamp, &suppressedRun);
            if (suppressedRun > 0) {
                AppendStandardErrorLine(output, timestampText,
                                        [NSString stringWithFormat:@"%@ (suppressed %ld repeats in last %.1fs)",
                                                                   line, (long)suppressedRun, kWarnRepeatSuppressWindowSec]);
            }
        }
        if (shouldPrint) {
            AppendStandardErrorLine(output, timestampText, line);
        }
    }
}

// Summaries are normally produced when the next line arrives. When the log goes quiet, this
// timer flushes the buckets whose window ended so the summary does not wait for the next line.
static void LoggerScheduleNoiseFlushIfNeeded(void) {
    if (gNoiseFlushScheduled || gCuratedNoiseAggregation.count == 0) {
        return;
    }
    gNoiseFlushScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kNoiseAggregationWindowSec + 0.5) * NSEC_PER_SEC)),
                   gLoggerQueue, ^{
        gNoiseFlushScheduled = NO;
        @autoreleasepool {
            LoggerBatchOutput *output = [[LoggerBatchOutput alloc] init];
            FlushCuratedNoiseAggregation(LoggerNowTimestamp(), NO, output);
            CommitBatchOutput(output);
        }
        LoggerScheduleNoiseFlushIfNeeded();
    });
}

static void LoggerProcessBatch(NSArray<LoggerPendingLine *> *batch, NSUInteger dropped) {
    LoggerBatchOutput *output = [[LoggerBatchOutput alloc] init];

    if (dropped > 0) {
        LoggerPendingLine *notice = [[LoggerPendingLine alloc]
            initWithLevel:LOG_W
                      tag:nil
                  message:[NSString stringWithFormat:@"[logger] dropped %lu log lines because the logging queue was overloaded", (unsigned long)dropped]
                timestamp:LoggerNowTimestamp()];
        ProcessPendingLine(notice, output);
    }
    for (LoggerPendingLine *pending in batch) {
        ProcessPendingLine(pending, output);
    }

    CommitBatchOutput(output);
    LoggerScheduleNoiseFlushIfNeeded();
}

// Runs on the logging queue until nothing is pending. Pending lines are taken in whole batches,
// so a burst becomes one store append and one write per file.
static void LoggerDrainPending(void) {
    for (;;) {
        NSMutableArray<LoggerPendingLine *> *replacement = [NSMutableArray arrayWithCapacity:64];
        NSArray<LoggerPendingLine *> *batch = nil;
        NSUInteger dropped = 0;

        os_unfair_lock_lock(&gPendingLock);
        if (gPending.count == 0 && gDroppedCount == 0) {
            gDrainScheduled = NO;
            os_unfair_lock_unlock(&gPendingLock);
            return;
        }
        batch = gPending;
        gPending = replacement;
        dropped = gDroppedCount;
        gDroppedCount = 0;
        os_unfair_lock_unlock(&gPendingLock);

        @autoreleasepool {
            LoggerProcessBatch(batch, dropped);
        }
    }
}

#pragma mark - Hot path

// Hands a line to the logging queue. Called on arbitrary threads; takes a short lock and returns.
static void LoggerEnqueue(LogLevel level, NSString *tag, NSString *message) {
    dispatch_queue_t queue = LoggerQueue();
    LoggerPendingLine *pending = [[LoggerPendingLine alloc] initWithLevel:level
                                                                      tag:tag
                                                                  message:message
                                                                timestamp:LoggerNowTimestamp()];
    BOOL scheduleDrain = NO;
    os_unfair_lock_lock(&gPendingLock);
    if (gPending.count >= kPendingLineLimit && level != LOG_E) {
        gDroppedCount += 1;
    } else {
        [gPending addObject:pending];
        if (!gDrainScheduled) {
            gDrainScheduled = YES;
            scheduleDrain = YES;
        }
    }
    os_unfair_lock_unlock(&gPendingLock);

    if (scheduleDrain) {
        dispatch_async(queue, ^{
            LoggerDrainPending();
        });
    }

    // Errors are the lines most worth having after a crash: wait until they are written. Never
    // wait from the logging queue itself, that would deadlock.
    if (level == LOG_E && !LoggerIsOnLoggingQueue()) {
        dispatch_sync(queue, ^{
            LoggerDrainPending();
        });
    }
}

static BOOL LoggerLevelIsValid(LogLevel level) {
    return LogPrefixForLevel(level).length > 0;
}

static BOOL LoggerLevelPassesMinimum(LogLevel level) {
    return (int)level >= atomic_load_explicit(&gLoggerMinimumLevel, memory_order_relaxed);
}

// Entry point for messages that are already formatted.
static void LoggerSubmitMessage(LogLevel level, NSString *tag, NSString *message) {
    if (!LoggerLevelIsValid(level)) {
        assert(false);
        return;
    }
    if (!LoggerLevelPassesMinimum(level)) {
        // Below the minimum only force-persisted input diagnostics survive.
        if (level != LOG_D || !LoggerInputDiagnosticsEnabledFlag() || !IsPersistableDiagnosticMessage(tag, message)) {
            return;
        }
    }
    LoggerEnqueue(level, tag, message ?: @"");
}

#pragma mark - Public API

void LoggerSetMinimumLevel(LogLevel level) {
    atomic_store_explicit(&gLoggerMinimumLevel, (int)level, memory_order_relaxed);
}

LogLevel LoggerGetMinimumLevel(void) {
    return (LogLevel)atomic_load_explicit(&gLoggerMinimumLevel, memory_order_relaxed);
}

void LoggerSetCuratedModeEnabled(BOOL enabled) {
    atomic_store_explicit(&gLoggerCuratedModeEnabled, enabled ? true : false, memory_order_relaxed);
}

BOOL LoggerIsCuratedModeEnabled(void) {
    return atomic_load_explicit(&gLoggerCuratedModeEnabled, memory_order_relaxed);
}

void LoggerSetInputDiagnosticsEnabled(BOOL enabled) {
    LoggerSeedSettingsFromDefaults();
    atomic_store_explicit(&gLoggerInputDiagnosticsEnabled, enabled ? true : false, memory_order_relaxed);
}

BOOL LoggerIsInputDiagnosticsEnabled(void) {
    return LoggerInputDiagnosticsEnabledFlag();
}

BOOL LoggerWouldLog(LogLevel level) {
    if (!LoggerLevelIsValid(level)) {
        return NO;
    }
    if (LoggerLevelPassesMinimum(level)) {
        return YES;
    }
    return level == LOG_D && LoggerInputDiagnosticsEnabledFlag();
}

void LoggerFlush(void) {
    dispatch_queue_t queue = LoggerQueue();
    if (LoggerIsOnLoggingQueue()) {
        return;
    }
    dispatch_sync(queue, ^{
        LoggerDrainPending();
    });
}

void LoggerPersistMessage(LogLevel level, NSString *message) {
    LoggerSubmitMessage(level, nil, message);
}

void LogMessage(LogLevel level, NSString *message) {
    LoggerSubmitMessage(level, nil, message);
}

void LogTaggedMessage(LogLevel level, NSString *tag, NSString *message) {
    LoggerSubmitMessage(level, tag.length > 0 ? tag : nil, message);
}

void LogTagv(LogLevel level, NSString *tag, NSString *fmt, va_list args);

void Log(LogLevel level, NSString* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    LogTagv(level, NULL, fmt, args);
    va_end(args);
}

void LogTag(LogLevel level, NSString* tag, NSString* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    LogTagv(level, tag, fmt, args);
    va_end(args);
}

void LogTagv(LogLevel level, NSString* tag, NSString* fmt, va_list args) {
    if (!LoggerLevelIsValid(level)) {
        assert(false);
        return;
    }

    // Decide from cheap information before paying for the formatting: suppressed debug lines (the
    // vast majority when the level is Info) cost one atomic load.
    BOOL passesMinimum = LoggerLevelPassesMinimum(level);
    if (!passesMinimum) {
        if (level != LOG_D || !LoggerInputDiagnosticsEnabledFlag() || !FormatMayCarryDiagnosticMarker(fmt, tag)) {
            return;
        }
    }

    NSString *message = [[NSString alloc] initWithFormat:fmt ?: @"" arguments:args];
    if (!passesMinimum && !IsPersistableDiagnosticMessage(tag, message)) {
        return;
    }
    LoggerEnqueue(level, tag, message);
}
