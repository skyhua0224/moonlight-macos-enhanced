//
//  Logger.m
//  Moonlight
//
//  Created by Diego Waxemberg on 2/10/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "Logger.h"

#import "LogBuffer.h"

static const NSTimeInterval kWarnRepeatSuppressWindowSec = 1.0;
static const NSTimeInterval kNoiseAggregationWindowSec = 5.0;
static const unsigned long long kRawFileLogMaxBytes = 8 * 1024 * 1024;
static const unsigned long long kCuratedFileLogMaxBytes = 2 * 1024 * 1024;
static NSMutableDictionary<NSString*, NSMutableDictionary*> *gRuntimeWarnRepeatTracker = nil;
static NSObject *gRuntimeWarnRepeatLock = nil;
static NSMutableDictionary<NSString*, NSMutableDictionary*> *gCuratedWarnRepeatTracker = nil;
static NSObject *gCuratedWarnRepeatLock = nil;
static NSObject *gCuratedNoiseLock = nil;
static NSObject *gFileLogLock = nil;
static NSObject *gLoggerStateLock = nil;
static NSString *gLogDirectoryPath = nil;
static NSString *gRawFileLogPath = nil;
static NSString *gCuratedFileLogPath = nil;
static NSMutableDictionary *gCuratedNoiseAggregation = nil;

static LogLevel gLoggerMinimumLevel = LOG_I;
static BOOL gCuratedModeEnabled = YES;

typedef NS_ENUM(NSInteger, LoggerNoiseCategory) {
    LoggerNoiseCategoryNone = 0,
    LoggerNoiseCategoryAppKitMenuInconsistency,
    LoggerNoiseCategoryNetworkStackNoise,
    LoggerNoiseCategorySystemTransportFallback,
    LoggerNoiseCategoryDiscoveryChatter,
    LoggerNoiseCategoryHostIdentityMismatch,
};

void LogTagv(LogLevel level, NSString* tag, NSString* fmt, va_list args);

static NSString *LoggerTimestampString(void) {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    return [formatter stringFromDate:[NSDate date]];
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

static NSString *EnsureLogDirectoryPath(void) {
    if (gLogDirectoryPath != nil) {
        return gLogDirectoryPath;
    }

    if (gFileLogLock == nil) {
        gFileLogLock = [[NSObject alloc] init];
    }

    @synchronized (gFileLogLock) {
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

static NSString *ExtractFirstMatch(NSString *input, NSString *pattern) {
    if (input.length == 0 || pattern.length == 0) {
        return nil;
    }
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:&error];
    if (error != nil || regex == nil) {
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
        return [NSString stringWithFormat:@"错误码 %@", code];
    }
    code = ExtractFirstMatch(line, @"(-1001|-1004|-1005)");
    if (code.length > 0) {
        return [NSString stringWithFormat:@"错误码 %@", code];
    }
    return @"错误码未知";
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
    return @"未知目标";
}

static LoggerNoiseCategory DetectNoiseCategory(NSString *line) {
    if (line.length == 0) {
        return LoggerNoiseCategoryNone;
    }
    if ([line rangeOfString:@"Discovery summary for " options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [line rangeOfString:@"Resolved address:" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return LoggerNoiseCategoryDiscoveryChatter;
    }
    if (IsServerCertificateMismatchLine(line) || IsIncorrectHostLine(line)) {
        return LoggerNoiseCategoryHostIdentityMismatch;
    }
    if ([line rangeOfString:@"Internal inconsistency in menus" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return LoggerNoiseCategoryAppKitMenuInconsistency;
    }
    if ([line rangeOfString:@"NSURLErrorDomain" options:NSCaseInsensitiveSearch].location != NSNotFound &&
        ([line rangeOfString:@"-1001"].location != NSNotFound ||
         [line rangeOfString:@"-1004"].location != NSNotFound ||
         [line rangeOfString:@"-1005"].location != NSNotFound)) {
        return LoggerNoiseCategorySystemTransportFallback;
    }
    if ([line rangeOfString:@"nw_" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [line rangeOfString:@"tcp_input" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [line rangeOfString:@"Request failed with error" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        ([line rangeOfString:@"Connection " options:NSCaseInsensitiveSearch].location != NSNotFound &&
         [line rangeOfString:@"failed" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
        ([line rangeOfString:@"Task <" options:NSCaseInsensitiveSearch].location != NSNotFound &&
         [line rangeOfString:@"finished with error" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
        return LoggerNoiseCategoryNetworkStackNoise;
    }
    return LoggerNoiseCategoryNone;
}

static NSString *NoiseCategoryDisplayName(LoggerNoiseCategory category) {
    switch (category) {
        case LoggerNoiseCategoryAppKitMenuInconsistency:
            return @"AppKit 菜单噪音 / AppKit Menu Inconsistency";
        case LoggerNoiseCategoryNetworkStackNoise:
            return @"系统网络噪音 / Network Stack Noise";
        case LoggerNoiseCategorySystemTransportFallback:
            return @"系统传输回退噪音 / System Transport Fallback";
        case LoggerNoiseCategoryDiscoveryChatter:
            return @"发现服务噪音 / Discovery Chatter";
        case LoggerNoiseCategoryHostIdentityMismatch:
            return @"主机身份不匹配 / Host Identity Mismatch";
        default:
            return @"系统噪音 / System Noise";
    }
}

static BOOL IsGeneratedCuratedNoiseSummaryLine(NSString *line) {
    if (line.length == 0) {
        return NO;
    }

    for (NSInteger category = LoggerNoiseCategoryAppKitMenuInconsistency;
         category <= LoggerNoiseCategoryHostIdentityMismatch;
         category++) {
        NSString *prefix = [NSString stringWithFormat:@"%@ %@：", PRFX_WARN, NoiseCategoryDisplayName((LoggerNoiseCategory)category)];
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

static NSString *NoiseAggregationKey(NSString *line, LoggerNoiseCategory category) {
    if (line.length == 0) {
        return nil;
    }

    if (category == LoggerNoiseCategoryDiscoveryChatter) {
        NSString *host = ExtractDiscoveryHost(line);
        NSString *state = ExtractDiscoveryState(line);
        if ([line rangeOfString:@"Discovery summary for " options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return [NSString stringWithFormat:@"discovery-summary:%@:%@", host ?: @"unknown", state ?: @"unknown"];
        }
        if ([line rangeOfString:@"Resolved address:" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return [NSString stringWithFormat:@"resolved-address:%@", host ?: @"unknown"];
        }
    }
    if (category == LoggerNoiseCategoryHostIdentityMismatch) {
        return @"host-identity-mismatch";
    }

    NSString *errorCode = ExtractErrorCode(line);
    NSString *target = ExtractTargetEndpoint(line);
    if ([line rangeOfString:@"Request failed with error" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return [NSString stringWithFormat:@"request-failed:%@", errorCode ?: @"错误码未知"];
    }
    if ([line rangeOfString:@"NSURLErrorDomain" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return [NSString stringWithFormat:@"nsurl:%@:%@", errorCode ?: @"错误码未知", target ?: @"未知目标"];
    }
    if ([line rangeOfString:@"Task <" options:NSCaseInsensitiveSearch].location != NSNotFound &&
        [line rangeOfString:@"finished with error" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return [NSString stringWithFormat:@"task-error:%@:%@", errorCode ?: @"错误码未知", target ?: @"未知目标"];
    }
    if ([line rangeOfString:@"Connection " options:NSCaseInsensitiveSearch].location != NSNotFound &&
        [line rangeOfString:@"failed" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return [NSString stringWithFormat:@"conn-failed:%@:%@", errorCode ?: @"错误码未知", target ?: @"未知目标"];
    }

    return [NSString stringWithFormat:@"noise:%ld:%@", (long)category, line];
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

static void AppendFileLogLineToPath(NSString *logPath, NSString *line, NSString *title, unsigned long long maxBytes) {
    if (line.length == 0) {
        return;
    }

    if (logPath.length == 0) {
        return;
    }

    if (gFileLogLock == nil) {
        gFileLogLock = [[NSObject alloc] init];
    }

    @synchronized (gFileLogLock) {
        RotateFileLogIfNeeded(logPath, maxBytes);

        if (![[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
            NSString *header = [NSString stringWithFormat:@"===== %@ started %@ =====\n", title, LoggerTimestampString()];
            [header writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }

        NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (file == nil) {
            return;
        }

        @try {
            [file seekToEndOfFile];
            NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", LoggerTimestampString(), line];
            NSData *data = [entry dataUsingEncoding:NSUTF8StringEncoding];
            [file writeData:data];
        } @catch (NSException *exception) {
            NSLog(@"<WARN> Failed writing log file: %@", exception.reason);
        } @finally {
            [file closeFile];
        }
    }
}

static void AppendRawFileLogLine(NSString *line) {
    AppendFileLogLineToPath(EnsureRawFileLogPath(), line, @"Moonlight raw debug log", kRawFileLogMaxBytes);
}

static void AppendCuratedFileLogLine(NSString *line) {
    AppendFileLogLineToPath(EnsureCuratedFileLogPath(), line, @"Moonlight curated debug log", kCuratedFileLogMaxBytes);
}

static void AppendCuratedLineWithWarnSuppression(NSString *line, LogLevel level) {
    if (line.length == 0) {
        return;
    }
    if (ShouldBypassCuratedWarnSuppression(line)) {
        AppendCuratedFileLogLine(line);
        return;
    }
    if (level != LOG_W) {
        AppendCuratedFileLogLine(line);
        return;
    }

    if (gCuratedWarnRepeatTracker == nil) {
        gCuratedWarnRepeatTracker = [NSMutableDictionary dictionary];
    }
    if (gCuratedWarnRepeatLock == nil) {
        gCuratedWarnRepeatLock = [[NSObject alloc] init];
    }

    BOOL shouldSuppress = NO;
    NSString *summaryLine = nil;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();

    @synchronized (gCuratedWarnRepeatLock) {
        NSMutableDictionary *entry = gCuratedWarnRepeatTracker[line];
        if (entry == nil) {
            entry = [@{ @"last": @(now), @"suppressed": @(0) } mutableCopy];
            gCuratedWarnRepeatTracker[line] = entry;
        }

        NSTimeInterval last = [entry[@"last"] doubleValue];
        NSInteger suppressed = [entry[@"suppressed"] integerValue];
        if (now - last < kWarnRepeatSuppressWindowSec) {
            entry[@"suppressed"] = @(suppressed + 1);
            shouldSuppress = YES;
        } else {
            if (suppressed > 0) {
                summaryLine = FormatLogLine(LOG_W,
                                            [NSString stringWithFormat:@"[curated] %.1fs 内重复 %ld 次（最后一条：%@）",
                                                                       kWarnRepeatSuppressWindowSec, (long)suppressed, line]);
            }
            entry[@"suppressed"] = @(0);
            entry[@"last"] = @(now);
        }
    }

    if (summaryLine.length > 0) {
        AppendCuratedFileLogLine(summaryLine);
    }
    if (!shouldSuppress) {
        AppendCuratedFileLogLine(line);
    }
}

static BOOL FlushOneCuratedNoiseBucketLocked(NSString *bucketKey, NSMutableDictionary *bucket, NSTimeInterval now, BOOL force) {
    if (bucket == nil || bucketKey.length == 0) {
        return YES;
    }

    NSInteger categoryRaw = [bucket[@"category"] integerValue];
    LoggerNoiseCategory category = (LoggerNoiseCategory)categoryRaw;
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

    if (category == LoggerNoiseCategoryNone || count <= 0) {
        return YES;
    }
    if (!force && (now - start) < kNoiseAggregationWindowSec) {
        return NO;
    }

    NSString *summary = nil;
    switch (category) {
        case LoggerNoiseCategoryDiscoveryChatter:
            if ([sampleLine rangeOfString:@"Resolved address:" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                summary = [NSString stringWithFormat:@"%@：%.0f秒内 %ld 次（%@ 地址解析重复）",
                           NoiseCategoryDisplayName(category),
                           kNoiseAggregationWindowSec,
                           (long)count,
                           discoveryHost.length > 0 ? discoveryHost : @"unknown"];
            } else {
                summary = [NSString stringWithFormat:@"%@：%.0f秒内 %ld 次（%@，%@）",
                           NoiseCategoryDisplayName(category),
                           kNoiseAggregationWindowSec,
                           (long)count,
                           discoveryHost.length > 0 ? discoveryHost : @"unknown",
                           discoveryState.length > 0 ? discoveryState : @"state changed"];
            }
            break;
        case LoggerNoiseCategoryHostIdentityMismatch: {
            NSMutableArray<NSString *> *parts = [NSMutableArray array];
            if (certificateMismatchCount > 0) {
                [parts addObject:[NSString stringWithFormat:@"证书不匹配 %ld 次", (long)certificateMismatchCount]];
            }
            if (incorrectHostCount > 0) {
                [parts addObject:[NSString stringWithFormat:@"错误主机 %ld 次", (long)incorrectHostCount]];
            }
            if (expectedHost.length > 0) {
                [parts addObject:[NSString stringWithFormat:@"期望 %@", ShortHostIdentifier(expectedHost)]];
            }
            if (incorrectHost.length > 0) {
                [parts addObject:[NSString stringWithFormat:@"收到 %@", ShortHostIdentifier(incorrectHost)]];
            }
            NSString *detail = parts.count > 0 ? [parts componentsJoinedByString:@"，"] : @"主机身份校验失败";
            summary = [NSString stringWithFormat:@"%@：%.0f秒内 %ld 次（%@）",
                       NoiseCategoryDisplayName(category),
                       kNoiseAggregationWindowSec,
                       (long)count,
                       detail];
            break;
        }
        default:
            summary = [NSString stringWithFormat:@"%@：%.0f秒内 %ld 条（主因：%@，目标 %@）",
                       NoiseCategoryDisplayName(category),
                       kNoiseAggregationWindowSec,
                       (long)count,
                       errorCode.length > 0 ? errorCode : @"错误码未知",
                       target.length > 0 ? target : @"未知目标"];
            break;
    }

    AppendCuratedLineWithWarnSuppression(FormatLogLine(LOG_W, summary), LOG_W);
    return YES;
}

static void FlushCuratedNoiseAggregationLocked(NSTimeInterval now, BOOL force) {
    if (gCuratedNoiseAggregation == nil || gCuratedNoiseAggregation.count == 0) {
        return;
    }

    NSArray<NSString *> *keys = [gCuratedNoiseAggregation allKeys];
    for (NSString *key in keys) {
        NSMutableDictionary *bucket = gCuratedNoiseAggregation[key];
        if (![bucket isKindOfClass:[NSMutableDictionary class]]) {
            [gCuratedNoiseAggregation removeObjectForKey:key];
            continue;
        }
        BOOL shouldRemove = FlushOneCuratedNoiseBucketLocked(key, bucket, now, force);
        if (shouldRemove) {
            [gCuratedNoiseAggregation removeObjectForKey:key];
        }
    }
}

static void ProcessCuratedLogLine(NSString *line, LogLevel level) {
    if (line.length == 0 || !LoggerIsCuratedModeEnabled()) {
        return;
    }
    if (level < LoggerGetMinimumLevel()) {
        return;
    }

    if (gCuratedNoiseLock == nil) {
        gCuratedNoiseLock = [[NSObject alloc] init];
    }

    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    LoggerNoiseCategory category = DetectNoiseCategory(line);
    BOOL appendOriginalAfterUnlock = NO;

    @synchronized (gCuratedNoiseLock) {
        if (gCuratedNoiseAggregation == nil) {
            gCuratedNoiseAggregation = [NSMutableDictionary dictionary];
        }
        FlushCuratedNoiseAggregationLocked(now, NO);

        if (category != LoggerNoiseCategoryNone) {
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
            if (category == LoggerNoiseCategoryHostIdentityMismatch) {
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
            return;
        }

        appendOriginalAfterUnlock = YES;
    }

    if (appendOriginalAfterUnlock) {
        AppendCuratedLineWithWarnSuppression(line, level);
    }
}

void LoggerSetMinimumLevel(LogLevel level) {
    if (gLoggerStateLock == nil) {
        gLoggerStateLock = [[NSObject alloc] init];
    }
    @synchronized (gLoggerStateLock) {
        gLoggerMinimumLevel = level;
    }
}

LogLevel LoggerGetMinimumLevel(void) {
    if (gLoggerStateLock == nil) {
        gLoggerStateLock = [[NSObject alloc] init];
    }
    @synchronized (gLoggerStateLock) {
        return gLoggerMinimumLevel;
    }
}

void LoggerSetCuratedModeEnabled(BOOL enabled) {
    if (gLoggerStateLock == nil) {
        gLoggerStateLock = [[NSObject alloc] init];
    }
    @synchronized (gLoggerStateLock) {
        gCuratedModeEnabled = enabled;
    }
}

BOOL LoggerIsCuratedModeEnabled(void) {
    if (gLoggerStateLock == nil) {
        gLoggerStateLock = [[NSObject alloc] init];
    }
    @synchronized (gLoggerStateLock) {
        return gCuratedModeEnabled;
    }
}

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

void LogMessage(LogLevel level, NSString *message) {
    NSString *line = FormatLogLine(level, message ?: @"");
    AppendRawFileLogLine(line);
    ProcessCuratedLogLine(line, level);
}

void LogTaggedMessage(LogLevel level, NSString *tag, NSString *message) {
    NSString *line = tag.length > 0
        ? [NSString stringWithFormat:@"(%@) %@", tag, message ?: @""]
        : (message ?: @"");
    AppendRawFileLogLine(FormatLogLine(level, line));
    ProcessCuratedLogLine(FormatLogLine(level, line), level);
}

void LogTagv(LogLevel level, NSString* tag, NSString* fmt, va_list args) {
    NSString *levelPrefix = LogPrefixForLevel(level);
    if (levelPrefix.length == 0) {
        assert(false);
    }

    NSString* prefixedString;
    if (tag) {
        prefixedString = [NSString stringWithFormat:@"%@ (%@) %@", levelPrefix, tag, fmt];
    } else {
        prefixedString = [NSString stringWithFormat:@"%@ %@", levelPrefix, fmt];
    }

    // Build a formatted line for in-app log overlays without consuming the original va_list.
    va_list argsCopy;
    va_copy(argsCopy, args);
    NSString *formattedLine = [[NSString alloc] initWithFormat:prefixedString arguments:argsCopy];
    va_end(argsCopy);

    AppendRawFileLogLine(formattedLine);
    ProcessCuratedLogLine(formattedLine, level);

    if (level < LoggerGetMinimumLevel()) {
        return;
    }

    // Suppress repeated warning lines within a short window to avoid log spam.
    if (level == LOG_W) {
        if (gRuntimeWarnRepeatTracker == nil) {
            gRuntimeWarnRepeatTracker = [NSMutableDictionary dictionary];
        }
        if (gRuntimeWarnRepeatLock == nil) {
            gRuntimeWarnRepeatLock = [[NSObject alloc] init];
        }

        BOOL shouldSuppress = NO;
        NSString *summaryLine = nil;
        NSTimeInterval now = CFAbsoluteTimeGetCurrent();

        @synchronized (gRuntimeWarnRepeatLock) {
            NSMutableDictionary *entry = gRuntimeWarnRepeatTracker[formattedLine];
            if (!entry) {
                entry = [@{ @"last": @(now), @"suppressed": @(0) } mutableCopy];
                gRuntimeWarnRepeatTracker[formattedLine] = entry;
            }

            NSTimeInterval last = [entry[@"last"] doubleValue];
            NSInteger suppressed = [entry[@"suppressed"] integerValue];

            if (now - last < kWarnRepeatSuppressWindowSec) {
                entry[@"suppressed"] = @(suppressed + 1);
                shouldSuppress = YES;
            } else {
                if (suppressed > 0) {
                    summaryLine = [NSString stringWithFormat:@"%@ (suppressed %ld repeats in last %.1fs)",
                                   formattedLine, (long)suppressed, kWarnRepeatSuppressWindowSec];
                }
                entry[@"suppressed"] = @(0);
                entry[@"last"] = @(now);
            }
        }

        if (summaryLine) {
            [[LogBuffer shared] appendLine:summaryLine level:level];
            NSLog(@"%@", summaryLine);
        }

        if (shouldSuppress) {
            return;
        }
    }

    [[LogBuffer shared] appendLine:formattedLine level:level];
    NSLogv(prefixedString, args);
}
