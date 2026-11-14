//
//  Utils.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(int, PairState) {
  PairStateUnknown,
  PairStateUnpaired,
  PairStatePaired
};

typedef NS_ENUM(int, State) { StateUnknown, StateOffline, StateOnline };

#if TARGET_OS_IPHONE
@class UIAlertController;
#endif

FOUNDATION_EXPORT NSString * const _Nonnull deviceName;

@interface Utils : NSObject

+ (NSData * _Nonnull)randomBytes:(NSInteger)length;
+ (NSString * _Nonnull)bytesToHex:(NSData * _Nonnull)data;
+ (NSData * _Nonnull)hexToBytes:(NSString * _Nonnull)hex;
+ (void)parseAddress:(NSString * _Nonnull)address
            intoHost:(NSString * _Nullable * _Nullable)host
             andPort:(NSString * _Nullable * _Nullable)port;
#if TARGET_OS_IPHONE
+ (void)addHelpOptionToDialog:(UIAlertController * _Nonnull)dialog;
#endif
+ (BOOL)isActiveNetworkVPN;
+ (BOOL)isTunnelInterfaceName:(NSString * _Nonnull)ifname;
/// The index of a named interface (if_nametoindex), or 0 when there is no such interface, it is down, or it is not running.
+ (unsigned int)usableInterfaceIndexForName:(NSString * _Nonnull)name;
+ (nullable NSString *)outboundInterfaceNameForAddress:(NSString * _Nonnull)address
                                         sourceAddress:(NSString * _Nullable * _Nullable)sourceAddress;

@end

@interface NSString (NSStringWithTrim)

- (NSString * _Nonnull)trim;

@end

NS_ASSUME_NONNULL_END
