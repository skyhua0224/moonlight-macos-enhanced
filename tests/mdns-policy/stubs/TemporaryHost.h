#import <Foundation/Foundation.h>
@interface TemporaryHost : NSObject
@property (nonatomic, copy) NSString *address, *localAddress, *ipv6Address, *externalAddress, *activeAddress, *name;
@end
