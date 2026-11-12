//
//  MLLaunchTrace.h
//  A launch trace that stays in release builds: which content view controllers are installed into the
//  main window and every transition between them, with a monotonic time since the process started.
//    log show --predicate 'subsystem == "std.skyhua.MoonlightMacEnhanced" AND category == "launch"' --last 5m
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
void MLLaunchTrace(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
NS_ASSUME_NONNULL_END
