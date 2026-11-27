#import <Foundation/Foundation.h>
@interface MLNetworkQuiet : NSObject
@property (class, nonatomic) BOOL isQuiet;   // the app's one is read-only; the test flips this one
@end
@interface Utils : NSObject
+ (BOOL)isActiveNetworkVPN;
@end
