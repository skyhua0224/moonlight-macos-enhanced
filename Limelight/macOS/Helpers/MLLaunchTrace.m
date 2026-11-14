//
//  MLLaunchTrace.m
//
#import "MLLaunchTrace.h"
#import <os/log.h>

static NSTimeInterval sStart;

__attribute__((constructor)) static void MLLaunchTraceStart(void) {
    sStart = [NSProcessInfo processInfo].systemUptime;
}

void MLLaunchTrace(NSString *format, ...) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("std.skyhua.MoonlightMacEnhanced", "launch"); });
    va_list args;
    va_start(args, format);
    NSString *text = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    os_log(log, "t=%.3f %{public}@", [NSProcessInfo processInfo].systemUptime - sStart, text);
}
