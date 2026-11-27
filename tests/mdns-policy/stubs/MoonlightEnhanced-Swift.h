#import <Foundation/Foundation.h>
@interface MLNetworkQuiet : NSObject
@property (class, nonatomic) BOOL isQuiet;   // the app's one is read-only; the test flips this one
+ (void)onQuiet:(NSString *)key cancel:(void (^)(void))cancel;
+ (void)onIdle:(NSString *)key resume:(void (^)(void))resume;
+ (void)fireQuiet;                            // test only: run the registered cancel hooks, as a launch or stream does
@end
@interface Utils : NSObject
+ (BOOL)isActiveNetworkVPN;
@end
