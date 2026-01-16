//
//  ConnectionEndpointStore.m
//  Moonlight for macOS
//
//  Created by GitHub Copilot on 2026/01/16.
//

#import "ConnectionEndpointStore.h"
#import "TemporaryHost.h"
#import "Utils.h"

@implementation ConnectionEndpointStore
static const NSString* HTTP_PORT = @"47989";
static const NSString* HTTPS_PORT = @"47984";

+ (NSString *)manualEndpointsKeyForHost:(NSString *)hostId {
    return [NSString stringWithFormat:@"manualEndpoints.%@", hostId ?: @""];
}

+ (NSString *)defaultConnectionMethodKeyForHost:(NSString *)hostId {
    return [NSString stringWithFormat:@"defaultConnectionMethod.%@", hostId ?: @""];
}

+ (NSString *)disabledEndpointsKeyForHost:(NSString *)hostId {
    return [NSString stringWithFormat:@"disabledEndpoints.%@", hostId ?: @""];
}

+ (NSArray<NSString *> *)manualEndpointsForHost:(NSString *)hostId {
    if (hostId.length == 0) {
        return @[];
    }
    NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:[self manualEndpointsKeyForHost:hostId]];
    if (![stored isKindOfClass:[NSArray class]]) {
        return @[];
    }
    return stored;
}

+ (NSArray<NSString *> *)disabledEndpointsForHost:(NSString *)hostId {
    if (hostId.length == 0) {
        return @[];
    }
    NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:[self disabledEndpointsKeyForHost:hostId]];
    if (![stored isKindOfClass:[NSArray class]]) {
        return @[];
    }
    return stored;
}

+ (NSString *)defaultConnectionMethodForHost:(NSString *)hostId {
    if (hostId.length == 0) {
        return nil;
    }
    NSString *stored = [[NSUserDefaults standardUserDefaults] stringForKey:[self defaultConnectionMethodKeyForHost:hostId]];
    if (stored.length == 0) {
        return nil;
    }
    if ([stored isEqualToString:@"Auto"]) {
        return @"Auto";
    }
    return [self normalizedAddress:stored];
}

+ (void)setDefaultConnectionMethod:(NSString *)method forHost:(NSString *)hostId {
    if (hostId.length == 0) {
        return;
    }
    if (method.length == 0) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:[self defaultConnectionMethodKeyForHost:hostId]];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ConnectionEndpointsUpdated"
                                                            object:nil
                                                          userInfo:@{ @"uuid": hostId ?: @"" }];
        return;
    }

    NSString *value = method;
    if (![method isEqualToString:@"Auto"]) {
        value = [self normalizedAddress:method];
    }

    [[NSUserDefaults standardUserDefaults] setObject:value forKey:[self defaultConnectionMethodKeyForHost:hostId]];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ConnectionEndpointsUpdated"
                                                        object:nil
                                                      userInfo:@{ @"uuid": hostId ?: @"" }];
}

+ (BOOL)addManualEndpoint:(NSString *)address forHost:(NSString *)hostId {
    NSString *normalized = [self normalizedAddress:address];
    if (hostId.length == 0 || normalized.length == 0) {
        return NO;
    }

    NSMutableArray *existing = [[self manualEndpointsForHost:hostId] mutableCopy];
    if (!existing) {
        existing = [NSMutableArray array];
    }

    if ([existing containsObject:normalized]) {
        return NO;
    }

    [existing addObject:normalized];
    [[NSUserDefaults standardUserDefaults] setObject:existing forKey:[self manualEndpointsKeyForHost:hostId]];
    // Re-enable if it was previously disabled
    [self enableEndpoint:normalized forHost:hostId];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ConnectionEndpointsUpdated"
                                                                                                                object:nil
                                                                                                            userInfo:@{ @"uuid": hostId ?: @"" }];
    return YES;
}

+ (BOOL)removeManualEndpoint:(NSString *)address forHost:(NSString *)hostId {
    NSString *normalized = [self normalizedAddress:address];
    if (hostId.length == 0 || normalized.length == 0) {
        return NO;
    }

    NSMutableArray *existing = [[self manualEndpointsForHost:hostId] mutableCopy];
    if (!existing) {
        return NO;
    }

    if (![existing containsObject:normalized]) {
        return NO;
    }

    [existing removeObject:normalized];
    [[NSUserDefaults standardUserDefaults] setObject:existing forKey:[self manualEndpointsKeyForHost:hostId]];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ConnectionEndpointsUpdated"
                                                                                                                object:nil
                                                                                                            userInfo:@{ @"uuid": hostId ?: @"" }];
    return YES;
}

+ (BOOL)disableEndpoint:(NSString *)address forHost:(NSString *)hostId {
    NSString *normalized = [self normalizedAddress:address];
    if (hostId.length == 0 || normalized.length == 0) {
        return NO;
    }

    NSMutableArray *disabled = [[self disabledEndpointsForHost:hostId] mutableCopy];
    if (!disabled) {
        disabled = [NSMutableArray array];
    }

    if ([disabled containsObject:normalized]) {
        return NO;
    }

    [disabled addObject:normalized];
    [[NSUserDefaults standardUserDefaults] setObject:disabled forKey:[self disabledEndpointsKeyForHost:hostId]];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ConnectionEndpointsUpdated"
                                                                                                                object:nil
                                                                                                            userInfo:@{ @"uuid": hostId ?: @"" }];
    return YES;
}

+ (BOOL)enableEndpoint:(NSString *)address forHost:(NSString *)hostId {
    NSString *normalized = [self normalizedAddress:address];
    if (hostId.length == 0 || normalized.length == 0) {
        return NO;
    }

    NSMutableArray *disabled = [[self disabledEndpointsForHost:hostId] mutableCopy];
    if (!disabled || ![disabled containsObject:normalized]) {
        return NO;
    }

    [disabled removeObject:normalized];
    [[NSUserDefaults standardUserDefaults] setObject:disabled forKey:[self disabledEndpointsKeyForHost:hostId]];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ConnectionEndpointsUpdated"
                                                                                                                object:nil
                                                                                                            userInfo:@{ @"uuid": hostId ?: @"" }];
    return YES;
}

+ (NSArray<NSString *> *)allEndpointsForHost:(TemporaryHost *)host {
    if (!host) {
        return @[];
    }

    NSMutableOrderedSet *ordered = [[NSMutableOrderedSet alloc] init];

    NSArray *candidates = @[
        host.activeAddress ?: @"",
        host.localAddress ?: @"",
        host.address ?: @"",
        host.externalAddress ?: @"",
        host.ipv6Address ?: @""
    ];

    NSArray *disabled = [self disabledEndpointsForHost:host.uuid];
    NSSet *disabledSet = [NSSet setWithArray:disabled];

    for (NSString *addr in candidates) {
        NSString *normalized = [self normalizedAddress:addr];
        if (normalized.length > 0 && ![disabledSet containsObject:normalized]) {
            [ordered addObject:normalized];
        }
    }

    for (NSString *manual in [self manualEndpointsForHost:host.uuid]) {
        NSString *normalized = [self normalizedAddress:manual];
        if (normalized.length > 0 && ![disabledSet containsObject:normalized]) {
            [ordered addObject:normalized];
        }
    }

    return [ordered array];
}

+ (NSString *)normalizedAddress:(NSString *)address {
    if (![address isKindOfClass:[NSString class]]) {
        return @"";
    }
    NSString *trimmed = [address trim];
    if (trimmed.length == 0) {
        return @"";
    }

    NSString *host = nil;
    NSString *port = nil;
    [Utils parseAddress:trimmed intoHost:&host andPort:&port];
    if (host.length == 0) {
        return trimmed;
    }

    if (port.length > 0) {
        if ([port isEqualToString:(NSString *)HTTP_PORT] || [port isEqualToString:(NSString *)HTTPS_PORT]) {
            return host;
        }
        return [NSString stringWithFormat:@"%@:%@", host, port];
    }

    return host;
}

@end
