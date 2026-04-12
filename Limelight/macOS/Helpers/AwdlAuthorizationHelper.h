#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MLAwdlAuthorizationHelper : NSObject

+ (BOOL)bundledPrivilegedHelperAvailable;

+ (BOOL)bundledPrivilegedHelperHasUsableSignature;

+ (BOOL)installedPrivilegedHelperHasUsableSignature;

+ (BOOL)mainApplicationSupportsPrivilegedHelperBlessing;

+ (BOOL)privilegedHelperLaunchdJobLoaded;

+ (BOOL)prepareSessionWithPrompt:(NSString *)prompt
                    errorMessage:(NSString * _Nullable * _Nullable)errorMessage;

+ (BOOL)privilegedHelperInstalled;

+ (BOOL)runIfconfigArgument:(NSString *)argument
                     prompt:(NSString *)prompt
               errorMessage:(NSString * _Nullable * _Nullable)errorMessage;

+ (void)invalidateSession;

@end

NS_ASSUME_NONNULL_END
