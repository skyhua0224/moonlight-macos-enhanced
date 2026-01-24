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
static NSMutableDictionary<NSString*, NSMutableDictionary*> *gWarnRepeatTracker = nil;
static NSObject *gWarnRepeatLock = nil;

static LogLevel LoggerLogLevel = LOG_I;

void LogTagv(LogLevel level, NSString* tag, NSString* fmt, va_list args);

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

    NSLogv(prefixedString, args);
}
