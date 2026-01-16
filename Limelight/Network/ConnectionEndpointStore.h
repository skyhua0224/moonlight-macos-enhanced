//
//  ConnectionEndpointStore.h
//  Moonlight for macOS
//
//  Created by GitHub Copilot on 2026/01/16.
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

+ (nullable NSString *)defaultConnectionMethodForHost:(NSString *)hostId;
+ (void)setDefaultConnectionMethod:(nullable NSString *)method forHost:(NSString *)hostId;

+ (NSArray<NSString *> *)allEndpointsForHost:(TemporaryHost *)host;
+ (NSString *)normalizedAddress:(NSString *)address;

@end

NS_ASSUME_NONNULL_END
