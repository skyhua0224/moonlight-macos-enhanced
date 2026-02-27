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
static const unsigned long long kFileLogMaxBytes = 2 * 1024 * 1024;
static NSMutableDictionary<NSString*, NSMutableDictionary*> *gWarnRepeatTracker = nil;
static NSObject *gWarnRepeatLock = nil;
static NSObject *gFileLogLock = nil;
static NSString *gFileLogPath = nil;

static LogLevel LoggerLogLevel = LOG_I;

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

static NSString *EnsureFileLogPath(void) {
    if (gFileLogPath != nil) {
        return gFileLogPath;
    }

    if (gFileLogLock == nil) {
        gFileLogLock = [[NSObject alloc] init];
    }

    @synchronized (gFileLogLock) {
        if (gFileLogPath != nil) {
            return gFileLogPath;
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

        gFileLogPath = [logDir stringByAppendingPathComponent:@"moonlight-debug.log"];
        return gFileLogPath;
    }
}

static void RotateFileLogIfNeeded(NSString *logPath) {
    if (logPath.length == 0) {
        return;
    }

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:logPath error:nil];
    unsigned long long size = [attrs fileSize];
    if (size < kFileLogMaxBytes) {
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

static void AppendFileLogLine(NSString *line) {
    if (line.length == 0) {
        return;
    }

    NSString *logPath = EnsureFileLogPath();
    if (logPath.length == 0) {
        return;
    }

    if (gFileLogLock == nil) {
        gFileLogLock = [[NSObject alloc] init];
    }

    @synchronized (gFileLogLock) {
        RotateFileLogIfNeeded(logPath);

        if (![[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
            NSString *header = [NSString stringWithFormat:@"===== Moonlight debug log started %@ =====\n", LoggerTimestampString()];
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
    NSString* levelPrefix = @"";
    
    if (level < LoggerLogLevel) {
        return;
    }
    
    switch(level) {
        case LOG_D:
            levelPrefix = PRFX_DEBUG;
            break;
        case LOG_I:
            levelPrefix = PRFX_INFO;
            break;
        case LOG_W:
            levelPrefix = PRFX_WARN;
            break;
        case LOG_E:
            levelPrefix = PRFX_ERROR;
            break;
        default:
            levelPrefix = @"";
            assert(false);
            break;
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

    // Suppress repeated warning lines within a short window to avoid log spam.
    if (level == LOG_W) {
        if (gWarnRepeatTracker == nil) {
            gWarnRepeatTracker = [NSMutableDictionary dictionary];
        }
        if (gWarnRepeatLock == nil) {
            gWarnRepeatLock = [[NSObject alloc] init];
        }

        BOOL shouldSuppress = NO;
        NSString *summaryLine = nil;
        NSTimeInterval now = CFAbsoluteTimeGetCurrent();

        @synchronized (gWarnRepeatLock) {
            NSMutableDictionary *entry = gWarnRepeatTracker[formattedLine];
            if (!entry) {
                entry = [@{ @"last": @(now), @"suppressed": @(0) } mutableCopy];
                gWarnRepeatTracker[formattedLine] = entry;
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
    AppendFileLogLine(formattedLine);

    NSLogv(prefixedString, args);
}
