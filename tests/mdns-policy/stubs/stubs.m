#import "MoonlightEnhanced-Swift.h"
#import "TemporaryHost.h"
@implementation TemporaryHost
@end
static BOOL gQuiet;
@implementation MLNetworkQuiet
+ (BOOL)isQuiet { return gQuiet; }
+ (void)setIsQuiet:(BOOL)v { gQuiet = v; }
@end
@implementation Utils
+ (BOOL)isActiveNetworkVPN { return NO; }
@end
void Log(LogLevel level, NSString *fmt, ...) {
    if (getenv("MDNS_TEST_LOG") == NULL) return;
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "  log: %s\n", s.UTF8String);
}
