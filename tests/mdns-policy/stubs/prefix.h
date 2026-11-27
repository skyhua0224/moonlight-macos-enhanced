// Test prefix: what the app's prefix header gives MDNSManager.m (Foundation, Log, the log levels).
#import <Foundation/Foundation.h>
typedef enum { LOG_D, LOG_I, LOG_W, LOG_E } LogLevel;
void Log(LogLevel level, NSString *fmt, ...);
