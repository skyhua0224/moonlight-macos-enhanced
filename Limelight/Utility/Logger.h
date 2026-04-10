//
//  Logger.h
//  Moonlight
//
//  Created by Diego Waxemberg on 2/10/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#ifndef Limelight_Logger_h
#define Limelight_Logger_h

#import <Foundation/Foundation.h>
#import <stdarg.h>

typedef enum {
    LOG_D,
    LOG_I,
    LOG_W,
    LOG_E
} LogLevel;

#define PRFX_DEBUG @"<DEBUG>"
#define PRFX_INFO @"<INFO>"
#define PRFX_WARN @"<WARN>"
#define PRFX_ERROR @"<ERROR>"

void Log(LogLevel level, NSString* fmt, ...);
void LogTag(LogLevel level, NSString* tag, NSString* fmt, ...);
void LogMessage(LogLevel level, NSString* message);
void LogTaggedMessage(LogLevel level, NSString* tag, NSString* message);
void LoggerSetMinimumLevel(LogLevel level);
LogLevel LoggerGetMinimumLevel(void);
void LoggerSetCuratedModeEnabled(BOOL enabled);
BOOL LoggerIsCuratedModeEnabled(void);
void LoggerSetInputDiagnosticsEnabled(BOOL enabled);
BOOL LoggerIsInputDiagnosticsEnabled(void);
void LoggerPersistMessage(LogLevel level, NSString *message);

#endif
