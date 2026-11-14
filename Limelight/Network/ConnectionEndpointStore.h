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

/// What the user said an address is when adding it: "host", "forward", "relay" or "overlay" (nil = decide automatically).
+ (nullable NSString *)declaredPathForEndpoint:(NSString *)address forHost:(NSString *)hostId;

/// The order the user gave the addresses (host:port, best first). allEndpointsForHost lists them in this order, so it is the
/// order automatic connection prefers; the address pinned as default is still tried first, and addresses not in the list follow.
+ (NSArray<NSString *> *)endpointOrderForHost:(NSString *)hostId;
+ (void)setEndpointOrder:(NSArray<NSString *> *)order forHost:(NSString *)hostId;
/// Edit in place: the manual endpoint `oldAddress` becomes `newAddress` (same place in the order, same declared kind unless given).
+ (BOOL)replaceManualEndpoint:(NSString *)oldAddress with:(NSString *)newAddress forHost:(NSString *)hostId;
+ (void)setDeclaredPath:(nullable NSString *)kind forEndpoint:(NSString *)address forHost:(NSString *)hostId;
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
