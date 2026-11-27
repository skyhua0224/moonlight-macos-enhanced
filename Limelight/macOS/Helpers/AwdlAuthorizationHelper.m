#import "AwdlAuthorizationHelper.h"
#import "AwdlPrivilegedHelperProtocol.h"

#import <Security/SecCode.h>
#import <Security/SecBase.h>

@implementation MLAwdlAuthorizationHelper

static NSXPCConnection *MLAwdlPrivilegedHelperConnection = nil;
/// This process holds awdl0 down through the connection above. Dropping the connection then gives awdl0 back (the helper
/// does that when a client goes away), which must not happen because one call timed out.
static BOOL MLAwdlHoldActive = NO;
static NSString * const MLAwdlPrivilegedHelperSuffix = @".AwdlPrivilegedHelper";
static NSTimeInterval const MLAwdlPrivilegedHelperTimeout = 5.0;
static NSTimeInterval const MLAwdlPrivilegedHelperVersionTimeout = 2.0;

+ (NSString *)helperLabel {
    NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    if (bundleIdentifier.length == 0) {
        return [@"std.skyhua.MoonlightMacEnhanced" stringByAppendingString:MLAwdlPrivilegedHelperSuffix];
    }
    return [bundleIdentifier stringByAppendingString:MLAwdlPrivilegedHelperSuffix];
}

+ (NSString *)bundledHelperPath {
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    if (bundlePath.length == 0) {
        return @"";
    }

    return [bundlePath stringByAppendingPathComponent:[NSString stringWithFormat:@"Contents/Library/LaunchServices/%@", [self helperLabel]]];
}

+ (NSString *)installedHelperPath {
    return [@"/Library/PrivilegedHelperTools" stringByAppendingPathComponent:[self helperLabel]];
}

+ (BOOL)helperExistsAtPath:(NSString *)helperPath {
    if (helperPath.length == 0) {
        return NO;
    }

    BOOL isDirectory = NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:helperPath isDirectory:&isDirectory] && !isDirectory;
}

+ (BOOL)helperAtPathHasUsableSignature:(NSString *)helperPath {
    if (![self helperExistsAtPath:helperPath]) {
        return NO;
    }

    NSURL *helperURL = [NSURL fileURLWithPath:helperPath];
    SecStaticCodeRef staticCode = NULL;
    OSStatus createStatus = SecStaticCodeCreateWithPath((__bridge CFURLRef)helperURL, kSecCSDefaultFlags, &staticCode);
    if (createStatus != errSecSuccess || staticCode == NULL) {
        if (staticCode != NULL) {
            CFRelease(staticCode);
        }
        return NO;
    }

    OSStatus validateStatus = SecStaticCodeCheckValidity(staticCode, kSecCSBasicValidateOnly, NULL);
    CFRelease(staticCode);
    return validateStatus == errSecSuccess;
}

+ (BOOL)bundledPrivilegedHelperAvailable {
    NSString *helperPath = [self bundledHelperPath];
    return [self helperAtPathHasUsableSignature:helperPath];
}

+ (BOOL)bundledPrivilegedHelperHasUsableSignature {
    return [self helperAtPathHasUsableSignature:[self bundledHelperPath]];
}

+ (BOOL)installedPrivilegedHelperFilePresent {
    return [self helperExistsAtPath:[self installedHelperPath]];
}

+ (BOOL)installedPrivilegedHelperHasUsableSignature {
    return [self helperAtPathHasUsableSignature:[self installedHelperPath]];
}

+ (BOOL)privilegedHelperLaunchdJobLoaded {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/launchctl";
    task.arguments = @[@"print", [@"system/" stringByAppendingString:[self helperLabel]]];
    task.standardOutput = [NSPipe pipe];
    task.standardError = [NSPipe pipe];

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        return NO;
    }

    return task.terminationStatus == 0;
}

+ (void)invalidateConnection {
    @synchronized (self) {
        if (MLAwdlPrivilegedHelperConnection != nil) {
            [MLAwdlPrivilegedHelperConnection invalidate];
            MLAwdlPrivilegedHelperConnection = nil;
        }
        MLAwdlHoldActive = NO;
    }
}

+ (NSXPCConnection *)helperConnection {
    @synchronized (self) {
        if (MLAwdlPrivilegedHelperConnection != nil) {
            return MLAwdlPrivilegedHelperConnection;
        }

        NSXPCConnection *connection = [[NSXPCConnection alloc] initWithMachServiceName:[self helperLabel]
                                                                               options:NSXPCConnectionPrivileged];
        connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(MLAwdlPrivilegedHelperProtocol)];
        void (^dropped)(void) = ^{
            @synchronized (self) {
                if (MLAwdlPrivilegedHelperConnection == connection) {
                    MLAwdlPrivilegedHelperConnection = nil;
                    MLAwdlHoldActive = NO;
                }
            }
        };
        connection.invalidationHandler = dropped;
        connection.interruptionHandler = dropped;
        [connection resume];
        MLAwdlPrivilegedHelperConnection = connection;
        return connection;
    }
}

typedef void (^MLAwdlHelperCall)(id<MLAwdlPrivilegedHelperProtocol> proxy, void (^finish)(BOOL success, NSString *message));

/// One call to the helper: `call` starts it and must call `finish` exactly once when the helper replied. Returns NO with
/// a message when the helper could not be reached, did not answer in time, or answered with a failure.
+ (BOOL)performHelperCall:(MLAwdlHelperCall)call
                  timeout:(NSTimeInterval)timeout
             errorMessage:(NSString * _Nullable * _Nullable)errorMessage {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSObject *lock = [[NSObject alloc] init];
    __block BOOL finished = NO;
    __block BOOL success = NO;
    __block NSString *message = @"";
    void (^finish)(BOOL, NSString *) = ^(BOOL replySuccess, NSString *replyMessage) {
        @synchronized (lock) {
            if (finished) {
                return;
            }
            finished = YES;
            success = replySuccess;
            message = replyMessage ?: @"";
        }
        dispatch_semaphore_signal(semaphore);
    };

    NSXPCConnection *connection = [self helperConnection];
    id<MLAwdlPrivilegedHelperProtocol> proxy =
        [connection remoteObjectProxyWithErrorHandler:^(NSError *proxyError) {
            finish(NO, proxyError.localizedDescription ?: @"Unable to contact the AWDL privileged helper.");
        }];
    call(proxy, finish);

    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(semaphore, deadline) != 0) {
        finish(NO, @"Timed out while waiting for the AWDL privileged helper.");
    }

    @synchronized (lock) {
        if (!success) {
            BOOL holdActive;
            @synchronized (self) {
                holdActive = MLAwdlHoldActive;
            }
            if (!holdActive) {
                [self invalidateConnection];
            }
            if (errorMessage != NULL) {
                *errorMessage = message.length > 0 ? message : @"The AWDL privileged helper command failed.";
            }
        }
        return success;
    }
}

+ (NSDictionary<NSString *, id> *)helperHandshake {
    NSString *queryError = nil;
    BOOL reachable = [self performHelperCall:^(id<MLAwdlPrivilegedHelperProtocol> proxy, void (^finish)(BOOL, NSString *)) {
        [proxy queryAwdlStateWithReply:^(BOOL present, BOOL up, NSString *stderrText) {
            finish(YES, @"");
        }];
    } timeout:MLAwdlPrivilegedHelperTimeout errorMessage:&queryError];
    if (!reachable) {
        return @{
            @"reachable": @NO,
            @"interfaceVersion": @0,
            @"buildVersion": @"",
            @"error": queryError ?: @"Unable to contact the AWDL privileged helper.",
        };
    }

    __block NSInteger version = 0;
    __block NSString *build = @"";
    NSString *versionError = nil;
    BOOL answered = [self performHelperCall:^(id<MLAwdlPrivilegedHelperProtocol> proxy, void (^finish)(BOOL, NSString *)) {
        [proxy interfaceVersionWithReply:^(NSInteger replyVersion, NSString *buildVersion) {
            version = replyVersion;
            build = buildVersion ?: @"";
            finish(YES, @"");
        }];
    } timeout:MLAwdlPrivilegedHelperVersionTimeout errorMessage:&versionError];

    return @{
        @"reachable": @YES,
        @"interfaceVersion": @(answered ? version : 0),
        @"buildVersion": answered ? build : @"",
        @"error": @"",
    };
}

+ (BOOL)holdAwdlDownWithErrorMessage:(NSString * _Nullable * _Nullable)errorMessage {
    BOOL held = [self performHelperCall:^(id<MLAwdlPrivilegedHelperProtocol> proxy, void (^finish)(BOOL, NSString *)) {
        [proxy holdAwdlDownWithReply:^(BOOL success, NSString *message) {
            finish(success, message);
        }];
    } timeout:MLAwdlPrivilegedHelperTimeout errorMessage:errorMessage];
    if (held) {
        @synchronized (self) {
            MLAwdlHoldActive = YES;
        }
    }
    return held;
}

+ (BOOL)releaseAwdlHoldStillHeld:(BOOL *)stillHeld
                    errorMessage:(NSString * _Nullable * _Nullable)errorMessage {
    __block BOOL heldByOthers = NO;
    BOOL released = [self performHelperCall:^(id<MLAwdlPrivilegedHelperProtocol> proxy, void (^finish)(BOOL, NSString *)) {
        [proxy releaseAwdlHoldWithReply:^(BOOL success, BOOL stillHeldByOthers, NSString *message) {
            heldByOthers = stillHeldByOthers;
            finish(success, message);
        }];
    } timeout:MLAwdlPrivilegedHelperTimeout errorMessage:errorMessage];
    if (released) {
        @synchronized (self) {
            MLAwdlHoldActive = NO;
        }
    }
    if (stillHeld != NULL) {
        *stillHeld = released && heldByOthers;
    }
    return released;
}

+ (BOOL)bringAwdlUpWithErrorMessage:(NSString * _Nullable * _Nullable)errorMessage {
    return [self performHelperCall:^(id<MLAwdlPrivilegedHelperProtocol> proxy, void (^finish)(BOOL, NSString *)) {
        [proxy runIfconfigArgument:@"up" withReply:^(BOOL success, NSString *message) {
            finish(success, message);
        }];
    } timeout:MLAwdlPrivilegedHelperTimeout errorMessage:errorMessage];
}

+ (void)invalidateSession {
    [self invalidateConnection];
}

@end
