//
//  ConnectionEndpointStore.h
//  Moonlight for macOS
//
//  Created by GitHub SkyHua on 2026/01/16.
//

#import <Foundation/Foundation.h>
@class TemporaryHost;

NS_ASSUME_NONNULL_BEGIN

@interface ConnectionEndpointStore : NSObject

+ (NSArray<NSString *> *)manualEndpointsForHost:(NSString *)hostId;
+ (BOOL)addManualEndpoint:(NSString *)address forHost:(NSString *)hostId;
+ (BOOL)removeManualEndpoint:(NSString *)address forHost:(NSString *)hostId;

+ (NSArray<NSString *> *)disabledEndpointsForHost:(NSString *)hostId;
+ (BOOL)disableEndpoint:(NSString *)address forHost:(NSString *)hostId;
+ (BOOL)enableEndpoint:(NSString *)address forHost:(NSString *)hostId;

/// The network interface this computer's stream is pinned to (its name, e.g. "en0" or "utun10"); nil = 自动. Per computer, by name:
/// an interface index is not kept because it changes when an interface is rebuilt.
+ (nullable NSString *)networkInterfaceForHost:(NSString *)hostId;
+ (void)setNetworkInterface:(nullable NSString *)name forHost:(NSString *)hostId;

+ (nullable NSString *)defaultConnectionMethodForHost:(NSString *)hostId;
+ (void)setDefaultConnectionMethod:(nullable NSString *)method forHost:(NSString *)hostId;

+ (NSArray<NSString *> *)allEndpointsForHost:(TemporaryHost *)host;
+ (nullable NSString *)streamEndpointForHost:(TemporaryHost *)host connectionMethod:(nullable NSString *)method;
+ (NSString *)normalizedAddress:(NSString *)address;

@end

NS_ASSUME_NONNULL_END
