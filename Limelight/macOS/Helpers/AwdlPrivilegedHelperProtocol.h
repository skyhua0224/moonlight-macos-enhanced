#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Version of what the installed helper does and of the XPC interface below. Raise it with every change to either:
/// an app that finds a helper with a lower number installed asks the user, once per app build, to update it.
/// Version 1 (no version call) is the helper of builds before the default-on release.
/// Version 2 added the version call and the hold, which the helper takes back by itself when its client goes away.
#define MLAwdlPrivilegedHelperInterfaceVersion 2

@protocol MLAwdlPrivilegedHelperProtocol

- (void)queryAwdlStateWithReply:(void (^)(BOOL present, BOOL up, NSString *stderrText))reply;
- (void)runIfconfigArgument:(NSString *)argument
                  withReply:(void (^)(BOOL success, NSString *message))reply;

/// Version 2. `version` is MLAwdlPrivilegedHelperInterfaceVersion of the running helper, `buildVersion` the build
/// number it was compiled with (for the log only).
- (void)interfaceVersionWithReply:(void (^)(NSInteger version, NSString *buildVersion))reply;

/// Version 2. Brings awdl0 down for this connection's stream and remembers whether it was up. awdl0 comes back up when
/// the last holder releases it, and when a holder's connection ends for any reason (quit, crash, force quit).
- (void)holdAwdlDownWithReply:(void (^)(BOOL success, NSString *message))reply;

/// Version 2. Ends this connection's hold. Harmless without one.
- (void)releaseAwdlHoldWithReply:(void (^)(BOOL success, NSString *message))reply;

@end

NS_ASSUME_NONNULL_END
