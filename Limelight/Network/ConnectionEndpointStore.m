//
//  ConnectionEndpointStore.m
//  Moonlight for macOS
//
//  Created by GitHub SkyHua on 2026/01/16.
//

#import "LatencyProbe.h"
#import "Logger.h"
#import "ConnectionEndpointStore.h"
#import "TemporaryHost.h"
#import "Utils.h"

@implementation ConnectionEndpointStore
static const NSString* HTTP_PORT = @"47989";
static const NSString* HTTPS_PORT = @"47984";

+ (NSString *)manualEndpointsKeyForHost:(NSString *)hostId {
    return [NSString stringWithFormat:@"manualEndpoints.%@", hostId ?: @""];
}

+ (NSString *)networkInterfaceKeyForHost:(NSString *)hostId {
    return [NSString stringWithFormat:@"networkInterface.%@", hostId ?: @""];
}

+ (NSString *)networkInterfaceForHost:(NSString *)hostId {
    if (hostId.length == 0) return nil;
    NSString *name = [[NSUserDefaults standardUserDefaults] stringForKey:[self networkInterfaceKeyForHost:hostId]];
    return name.length > 0 ? name : nil;
}

+ (void)setNetworkInterface:(NSString *)name forHost:(NSString *)hostId {
    if (hostId.length == 0) return;
    NSString *key = [self networkInterfaceKeyForHost:hostId];
    if (name.length == 0 || [name isEqualToString:@"Auto"]) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];
    } else {
        [[NSUserDefaults standardUserDefaults] setObject:name forKey:key];
    }
}

+ (NSString *)endpointOrderKeyForHost:(NSString *)hostId {
    return [NSString stringWithFormat:@"endpointOrder.%@", hostId ?: @""];
}

/// host:port with the default port written out, lowercased, no trailing dot: the key an order entry and an endpoint share.
+ (NSString *)canonicalKey:(NSString *)address {
    NSString *host = nil, *port = nil;
    [Utils parseAddress:address intoHost:&host andPort:&port];
    if (host.length == 0) return @"";
    while ([host hasSuffix:@"."]) host = [host substringToIndex:host.length - 1];
    NSString *shown = [host containsString:@":"] ? [NSString stringWithFormat:@"[%@]", host.lowercaseString] : host.lowercaseString;
    return [NSString stringWithFormat:@"%@:%@", shown, port.length > 0 ? port : @"47989"];
}

+ (NSArray<NSString *> *)endpointOrderForHost:(NSString *)hostId {
    if (hostId.length == 0) return @[];
    NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:[self endpointOrderKeyForHost:hostId]];
    return [stored isKindOfClass:[NSArray class]] ? stored : @[];
}

+ (void)setEndpointOrder:(NSArray<NSString *> *)order forHost:(NSString *)hostId {
    if (hostId.length == 0) return;
    NSMutableArray *keys = [NSMutableArray array];
    for (NSString *entry in order) {
        NSString *key = [self canonicalKey:entry];
        if (key.length > 0 && ![keys containsObject:key]) [keys addObject:key];
    }
    [[NSUserDefaults standardUserDefaults] setObject:keys forKey:[self endpointOrderKeyForHost:hostId]];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ConnectionEndpointsUpdated" object:nil userInfo:@{ @"uuid": hostId ?: @"" }];
}

+ (BOOL)replaceManualEndpoint:(NSString *)oldAddress with:(NSString *)newAddress forHost:(NSString *)hostId {
    NSString *oldNormalized = [self normalizedAddress:oldAddress];
    NSString *newNormalized = [self normalizedAddress:newAddress];
    if (hostId.length == 0 || oldNormalized.length == 0 || newNormalized.length == 0) return NO;
    NSMutableArray *manual = [[self manualEndpointsForHost:hostId] mutableCopy] ?: [NSMutableArray array];
    NSUInteger index = [manual indexOfObject:oldNormalized];
    if (index == NSNotFound) return NO;
    if (![oldNormalized isEqualToString:newNormalized] && [manual containsObject:newNormalized]) return NO;
    manual[index] = newNormalized;
    [[NSUserDefaults standardUserDefaults] setObject:manual forKey:[self manualEndpointsKeyForHost:hostId]];
    // the declaration and the place in the order follow the address
    NSString *kind = [self declaredPathForEndpoint:oldNormalized forHost:hostId];
    NSMutableDictionary *declared = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:[self declaredPathKeyForHost:hostId]] mutableCopy] ?: [NSMutableDictionary dictionary];
    [declared removeObjectForKey:oldNormalized];
    if (kind.length > 0) declared[newNormalized] = kind;
    [[NSUserDefaults standardUserDefaults] setObject:declared forKey:[self declaredPathKeyForHost:hostId]];
    NSString *oldKey = [self canonicalKey:oldNormalized], *newKey = [self canonicalKey:newNormalized];
    NSMutableArray *order = [[self endpointOrderForHost:hostId] mutableCopy];
    NSUInteger at = [order indexOfObject:oldKey];
    if (at != NSNotFound) { order[at] = newKey; [[NSUserDefaults standardUserDefaults] setObject:order forKey:[self endpointOrderKeyForHost:hostId]]; }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ConnectionEndpointsUpdated" object:nil userInfo:@{ @"uuid": hostId ?: @"" }];
    return YES;
}

+ (NSString *)declaredPathKeyForHost:(NSString *)hostId {
    return [NSString stringWithFormat:@"declaredPaths.%@", hostId ?: @""];
}

+ (NSString *)declaredPathForEndpoint:(NSString *)address forHost:(NSString *)hostId {
    NSString *normalized = [self normalizedAddress:address];
    if (hostId.length == 0 || normalized.length == 0) return nil;
    NSDictionary *stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:[self declaredPathKeyForHost:hostId]];
    NSString *kind = stored[normalized];
    return [kind isKindOfClass:[NSString class]] && kind.length > 0 ? kind : nil;
}

+ (void)setDeclaredPath:(NSString *)kind forEndpoint:(NSString *)address forHost:(NSString *)hostId {
    NSString *normalized = [self normalizedAddress:address];
    if (hostId.length == 0 || normalized.length == 0) return;
    NSMutableDictionary *stored = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:[self declaredPathKeyForHost:hostId]] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (kind.length == 0) { [stored removeObjectForKey:normalized]; } else { stored[normalized] = kind; }
    [[NSUserDefaults standardUserDefaults] setObject:stored forKey:[self declaredPathKeyForHost:hostId]];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ConnectionEndpointsUpdated" object:nil userInfo:@{ @"uuid": hostId ?: @"" }];
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
    // an address that is gone has no declaration either
    NSMutableDictionary *declared = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:[self declaredPathKeyForHost:hostId]] mutableCopy];
    if (declared[normalized] != nil) {
        [declared removeObjectForKey:normalized];
        [[NSUserDefaults standardUserDefaults] setObject:declared forKey:[self declaredPathKeyForHost:hostId]];
    }
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

    // Discovery often stores a bare local address while the paired host
    // advertises a custom HTTP port (for example host.example:57989). The
    // bare address would make HttpManager fall back to 47984 and look online
    // to ICMP while every HTTPS capability request fails. Derive the custom
    // port once and test each bare address with that port first.
    NSString *customPort = nil;
    for (NSString *candidate in candidates) {
        NSString *parsedHost = nil;
        NSString *parsedPort = nil;
        [Utils parseAddress:candidate intoHost:&parsedHost andPort:&parsedPort];
        if (parsedPort.length > 0 &&
            ![parsedPort isEqualToString:(NSString *)HTTP_PORT] &&
            ![parsedPort isEqualToString:(NSString *)HTTPS_PORT]) {
            customPort = parsedPort;
            break;
        }
    }

    void (^appendEndpoint)(NSString *) = ^(NSString *addr) {
        NSString *normalized = [self normalizedAddress:addr];
        if (normalized.length > 0 && ![disabledSet containsObject:normalized]) {
            [ordered addObject:normalized];
        }
    };

    for (NSString *addr in candidates) {
        if (customPort.length > 0) {
            NSString *parsedHost = nil;
            NSString *parsedPort = nil;
            [Utils parseAddress:addr intoHost:&parsedHost andPort:&parsedPort];
            if (parsedHost.length > 0 && parsedPort.length == 0) {
                NSString *withPort = [parsedHost containsString:@":"] && ![parsedHost hasPrefix:@"["]
                    ? [NSString stringWithFormat:@"[%@]:%@", parsedHost, customPort]
                    : [NSString stringWithFormat:@"%@:%@", parsedHost, customPort];
                appendEndpoint(withPort);
            }
        }
        appendEndpoint(addr);
    }

    for (NSString *manual in [self manualEndpointsForHost:host.uuid]) {
        NSString *normalized = [self normalizedAddress:manual];
        if (normalized.length > 0 && ![disabledSet containsObject:normalized]) {
            [ordered addObject:normalized];
        }
    }

    // the order the user gave (主机信息 > 地址): listed first, in that order; the rest keep their place after them
    NSArray<NSString *> *userOrder = [self endpointOrderForHost:host.uuid];
    if (userOrder.count == 0) {
        return [ordered array];
    }
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    NSMutableArray<NSString *> *rest = [[ordered array] mutableCopy];
    for (NSString *key in userOrder) {
        for (NSString *endpoint in [rest copy]) {
            if ([[self canonicalKey:endpoint] isEqualToString:key]) {
                [result addObject:endpoint];
                [rest removeObject:endpoint];
            }
        }
    }
    [result addObjectsFromArray:rest];
    return result;
}

+ (NSString *)streamEndpointForHost:(TemporaryHost *)host connectionMethod:(NSString *)method {
    // Explicit routes must never silently fall back to a different network.
    if (method.length > 0 && ![method isEqualToString:@"Auto"]) {
        return method;
    }

    NSArray<NSString *> *endpoints = [self allEndpointsForHost:host];
    NSString *active = [self normalizedAddress:host.activeAddress];
    if ([endpoints containsObject:active] &&
        (host.addressStates[active] == nil || host.addressStates[active].boolValue)) {
        // a stream on this path failed in the last 30 minutes (high loss, control stream gone): Auto takes another answering path
        // when there is one. A path the user pinned never reaches this branch.
        if ([StreamPathHealth shouldAvoidHost:host.uuid address:active]) {
            for (NSString *endpoint in endpoints) {
                if (![endpoint isEqualToString:active] && host.addressStates[endpoint].boolValue &&
                    ![StreamPathHealth shouldAvoidHost:host.uuid address:endpoint]) {
                    NSDictionary *why = [StreamPathHealth recentFailureForHost:host.uuid address:active];
                    Log(LOG_W, @"[route] Auto avoids %@ (last stream failed: %@ %@), uses %@", active, why[@"reason"], why[@"detail"], endpoint);
                    return endpoint;
                }
            }
        }
        return active;
    }
    // Persisted app snapshots do not contain activeAddress. Prefer an endpoint
    // already verified by discovery instead of attempting HTTP with a nil host.
    for (NSString *endpoint in endpoints) {
        if (host.addressStates[endpoint].boolValue) {
            return endpoint;
        }
    }
    // Discovery may still be starting; allow enabled routes not yet probed.
    for (NSString *endpoint in endpoints) {
        if (host.addressStates[endpoint] == nil) {
            return endpoint;
        }
    }
    return nil;
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
        if ([host containsString:@":"] && ![host hasPrefix:@"["]) {
            return [NSString stringWithFormat:@"[%@]:%@", host, port];
        }
        return [NSString stringWithFormat:@"%@:%@", host, port];
    }

    return host;
}

@end
