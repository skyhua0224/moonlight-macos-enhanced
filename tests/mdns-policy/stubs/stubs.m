#import "MoonlightEnhanced-Swift.h"
#import "TemporaryHost.h"
@implementation TemporaryHost
@end
static BOOL gQuiet;
@implementation MLNetworkQuiet
+ (BOOL)isQuiet { return gQuiet; }
+ (void)setIsQuiet:(BOOL)v { gQuiet = v; }
static NSMutableDictionary<NSString *, void (^)(void)> *gQuietHooks;
+ (void)onQuiet:(NSString *)key cancel:(void (^)(void))cancel {
    if (gQuietHooks == nil) gQuietHooks = [NSMutableDictionary dictionary];
    gQuietHooks[key] = [cancel copy];
}
static NSMutableDictionary<NSString *, void (^)(void)> *gIdleHooks;
+ (void)onIdle:(NSString *)key resume:(void (^)(void))resume {
    if (gIdleHooks == nil) gIdleHooks = [NSMutableDictionary dictionary];
    gIdleHooks[key] = [resume copy];
}
+ (void)fireIdle {
    for (void (^hook)(void) in gIdleHooks.allValues) hook();
}
+ (void)fireQuiet {
    for (void (^hook)(void) in gQuietHooks.allValues) hook();
}
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
