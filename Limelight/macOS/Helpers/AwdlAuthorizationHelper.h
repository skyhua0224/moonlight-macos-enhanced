#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Talks to the installed privileged helper (a launchd daemon, installed once by the app) and inspects the copy bundled in
/// the app. Every call that reaches the helper blocks until the helper answers or the call times out: call it off the main
/// thread.
@interface MLAwdlAuthorizationHelper : NSObject

+ (BOOL)bundledPrivilegedHelperAvailable;

+ (BOOL)bundledPrivilegedHelperHasUsableSignature;

+ (BOOL)installedPrivilegedHelperFilePresent;

+ (BOOL)installedPrivilegedHelperHasUsableSignature;

+ (BOOL)privilegedHelperLaunchdJobLoaded;

/// What the helper says about itself. Keys: `reachable` (NSNumber BOOL: it answered the awdl0 query),
/// `interfaceVersion` (NSNumber: 0 when it did not answer the version call, which is how helpers of builds before the
/// version call behave), `buildVersion` (NSString), `error` (NSString, empty when reachable).
+ (NSDictionary<NSString *, id> *)helperHandshake;

/// Brings awdl0 down for this app until `releaseAwdlHold...`, or until the helper sees this process go away.
+ (BOOL)holdAwdlDownWithErrorMessage:(NSString * _Nullable * _Nullable)errorMessage NS_SWIFT_NAME(holdAwdlDown(errorMessage:));

/// `stillHeld` is set when another client holds awdl0 down: it then stays down, and bringing it up would be wrong.
+ (BOOL)releaseAwdlHoldStillHeld:(BOOL *)stillHeld
                    errorMessage:(NSString * _Nullable * _Nullable)errorMessage NS_SWIFT_NAME(releaseAwdlHold(stillHeld:errorMessage:));

/// `ifconfig awdl0 up` through the helper, for a restore that has no hold to release (a hold lost with an earlier run).
+ (BOOL)bringAwdlUpWithErrorMessage:(NSString * _Nullable * _Nullable)errorMessage NS_SWIFT_NAME(bringAwdlUp(errorMessage:));

/// Drops the connection to the helper; the next call opens a new one. Dropping it ends this process's hold.
+ (void)invalidateSession;

@end

NS_ASSUME_NONNULL_END
