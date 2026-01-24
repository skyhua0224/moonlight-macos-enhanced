//
//  DiscoveryWorker.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/2/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "DiscoveryWorker.h"
#import "Utils.h"
#import "ConnectionEndpointStore.h"
#import "LatencyProbe.h"
#import "HttpManager.h"
#import "ServerInfoResponse.h"
#import "HttpRequest.h"
#import "DataManager.h"
#import "StreamingSessionManager.h" // Import for streaming state check

@implementation DiscoveryWorker {
    TemporaryHost* _host;
    NSString* _uniqueId;
}

static const float POLL_RATE = 2.0f; // Poll every 2 seconds
static const NSTimeInterval ADDRESS_FAILURE_COOLDOWN_SEC = 30.0;
static NSMutableDictionary<NSString*, NSMutableDictionary<NSString*, NSNumber*>*> *gAddressCooldownByHost = nil;
static NSObject *gAddressCooldownLock = nil;
static const double AUTO_SWITCH_PING_IMPROVEMENT_MS = 20.0;
static const NSTimeInterval AUTO_SWITCH_COOLDOWN_SEC = 30.0;
static NSMutableDictionary<NSString*, NSNumber*> *gAutoSwitchCooldownByHost = nil;
static NSObject *gAutoSwitchCooldownLock = nil;

- (id) initWithHost:(TemporaryHost*)host uniqueId:(NSString*)uniqueId {
    self = [super init];
    _host = host;
    _uniqueId = uniqueId;
    return self;
}

- (TemporaryHost*) getHost {
    return _host;
}

- (void)main {
    while (!self.cancelled) {
        [self discoverHost];
        if (!self.cancelled) {
            [NSThread sleepForTimeInterval:POLL_RATE];
        }
    }
}

- (NSArray*) getHostAddressList {
    NSMutableOrderedSet *orderedSet = [[NSMutableOrderedSet alloc] initWithCapacity:5];

    // Try the active address first if we have one. This prevents
    // waiting for timeouts on unreachable local addresses when
    // we're connected remotely.
    if (_host.activeAddress != nil) {
        [orderedSet addObject:_host.activeAddress];
    }
    if (_host.localAddress != nil) {
        [orderedSet addObject:_host.localAddress];
    }
    if (_host.address != nil) {
        [orderedSet addObject:_host.address];
    }
    if (_host.externalAddress != nil) {
        [orderedSet addObject:_host.externalAddress];
    }
    if (_host.ipv6Address != nil) {
        [orderedSet addObject:_host.ipv6Address];
    }

    // Append manual endpoints from editor
    NSArray<NSString *> *manualEndpoints = [ConnectionEndpointStore manualEndpointsForHost:_host.uuid];
    for (NSString *endpoint in manualEndpoints) {
        if (endpoint.length > 0) {
            [orderedSet addObject:endpoint];
        }
    }

    return [orderedSet array];
}

- (BOOL)shouldBypassCooldownForAddress:(NSString *)address {
    if (address.length == 0) {
        return NO;
    }
    if (_host.activeAddress != nil && [_host.activeAddress isEqualToString:address]) {
        return YES;
    }
    return NO;
}

- (BOOL)shouldSkipAddressDueToCooldown:(NSString *)address {
    if (address.length == 0) {
        return YES;
    }
    if ([self shouldBypassCooldownForAddress:address]) {
        return NO;
    }

    if (gAddressCooldownByHost == nil) {
        gAddressCooldownByHost = [NSMutableDictionary dictionary];
    }
    if (gAddressCooldownLock == nil) {
        gAddressCooldownLock = [[NSObject alloc] init];
    }

    NSString *hostUUID = _host.uuid ?: @"";
    if (hostUUID.length == 0) {
        return NO;
    }

    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    @synchronized (gAddressCooldownLock) {
        NSMutableDictionary<NSString*, NSNumber*> *hostMap = gAddressCooldownByHost[hostUUID];
        if (!hostMap) {
            return NO;
        }
        NSNumber *nextAllowed = hostMap[address];
        if (!nextAllowed) {
            return NO;
        }
        if (now < nextAllowed.doubleValue) {
            return YES;
        }
    }
    return NO;
}

- (void)recordAddress:(NSString *)address success:(BOOL)success {
    if (address.length == 0) {
        return;
    }

    if (gAddressCooldownByHost == nil) {
        gAddressCooldownByHost = [NSMutableDictionary dictionary];
    }
    if (gAddressCooldownLock == nil) {
        gAddressCooldownLock = [[NSObject alloc] init];
    }

    NSString *hostUUID = _host.uuid ?: @"";
    if (hostUUID.length == 0) {
        return;
    }

    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    @synchronized (gAddressCooldownLock) {
        NSMutableDictionary<NSString*, NSNumber*> *hostMap = gAddressCooldownByHost[hostUUID];
        if (!hostMap) {
            hostMap = [NSMutableDictionary dictionary];
            gAddressCooldownByHost[hostUUID] = hostMap;
        }
        if (success) {
            [hostMap removeObjectForKey:address];
        } else {
            hostMap[address] = @(now + ADDRESS_FAILURE_COOLDOWN_SEC);
        }
    }
}

- (void) discoverHost {
    NSArray *addresses = [self getHostAddressList];
    NSMutableArray<NSString *> *filteredAddresses = [addresses mutableCopy];
    
    Log(LOG_D, @"%@ has %d unique addresses", _host.name, [filteredAddresses count]);
    
    dispatch_group_t group = dispatch_group_create();
    NSMutableDictionary *latencies = [[NSMutableDictionary alloc] init];
    NSMutableDictionary *states = [[NSMutableDictionary alloc] init];
    NSLock *lock = [[NSLock alloc] init];
    
    __block BOOL receivedResponse = NO;
    __block double minLatency = DBL_MAX;
    __block NSString *bestAddress = nil;
    __block ServerInfoResponse *bestResp = nil;

    __weak typeof(self) weakSelf = self;
    for (NSString *address in filteredAddresses) {
        if (self.cancelled) break;
        
        dispatch_group_enter(group);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                dispatch_group_leave(group);
                return;
            }

            NSDate *start = [NSDate date];
            ServerInfoResponse* serverInfoResp = [strongSelf requestInfoAtAddress:address cert:[strongSelf getHost].serverCert];
            NSTimeInterval rtt = -[start timeIntervalSinceNow] * 1000.0;
            
            BOOL success = [strongSelf checkResponse:serverInfoResp];
            
            [lock lock];
            if (success) {
                receivedResponse = YES;
                NSNumber *pingMs = [LatencyProbe icmpPingMsForAddress:address];
                if (pingMs != nil) {
                    [latencies setObject:pingMs forKey:address];
                } else {
                    [latencies setObject:@((int)rtt) forKey:address];
                }
                [states setObject:@(1) forKey:address];

                double bestMetric = pingMs != nil ? pingMs.doubleValue : rtt;
                if (bestMetric < minLatency) {
                    minLatency = bestMetric;
                    bestAddress = address;
                    bestResp = serverInfoResp;
                }
                [strongSelf recordAddress:address success:YES];
            } else {
                [states setObject:@(0) forKey:address];
                [strongSelf recordAddress:address success:NO];
            }
            [lock unlock];
            
            dispatch_group_leave(group);
        });
    }
    
    // Wait for requests to complete, checking for cancellation periodically
    // This allows stopDiscoveryBlocking to return quickly even if network requests are hanging
    while (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC)) != 0) {
        if (self.cancelled) {
            return;
        }
    }
    
    if (self.cancelled) return;

    _host.addressLatencies = latencies;
    _host.addressStates = states;

    // Check if this host is currently streaming
    BOOL isStreamingThisHost = [[StreamingSessionManager shared] isStreamingHost:_host.uuid];

    NSString *firstOnlineAddress = nil;
    int onlineCount = 0;
    for (NSString *addr in filteredAddresses) {
        NSNumber *state = states[addr];
        if (state && state.intValue == 1) {
            onlineCount++;
            if (!firstOnlineAddress) {
                firstOnlineAddress = addr;
            }
        }
    }
    int totalCount = (int)filteredAddresses.count;
    int offlineCount = totalCount - onlineCount;

    if (receivedResponse) {
        _host.state = StateOnline;
    } else if (isStreamingThisHost) {
        // If we are currently streaming from this host, assume it is online even if discovery fails.
        // Discovery often fails during streaming because the host is busy or ports are in use.
        _host.state = StateOnline;
        Log(LOG_I, @"Discovery failed for %@ but keeping Online because streaming is active", _host.name);
    } else {
        _host.state = StateOffline;
    }

    if (receivedResponse && bestResp) {
        [bestResp populateHost:_host];
        if (firstOnlineAddress != nil) {
            _host.activeAddress = firstOnlineAddress;
        } else if (bestAddress != nil) {
            _host.activeAddress = bestAddress;
        }

        Log(LOG_D, @"Received response from: %@\n{\n\t address:%@ \n\t localAddress:%@ \n\t externalAddress:%@ \n\t ipv6Address:%@ \n\t uuid:%@ \n\t mac:%@ \n\t pairState:%d \n\t online:%d \n\t activeAddress:%@ \n\t latency:%f ms\n}", _host.name, _host.address, _host.localAddress, _host.externalAddress, _host.ipv6Address, _host.uuid, _host.mac, _host.pairState, _host.state, _host.activeAddress, minLatency);
    }

    if (totalCount > 0) {
        if (onlineCount > 0) {
            Log(LOG_I, @"Discovery summary for %@: %d/%d online", _host.name, onlineCount, totalCount);
        } else {
            Log(LOG_W, @"Discovery summary for %@: %d online, %d offline", _host.name, onlineCount, offlineCount);
        }
    }

    // Auto-switch to a significantly lower-latency address (>= 20ms improvement)
    if (receivedResponse && !isStreamingThisHost && bestAddress != nil && _host.activeAddress != nil) {
        if (![bestAddress isEqualToString:_host.activeAddress]) {
            NSNumber *currentLatency = latencies[_host.activeAddress];
            NSNumber *bestLatency = latencies[bestAddress];
            if (currentLatency && bestLatency && (currentLatency.doubleValue - bestLatency.doubleValue) >= AUTO_SWITCH_PING_IMPROVEMENT_MS) {
                if (gAutoSwitchCooldownByHost == nil) {
                    gAutoSwitchCooldownByHost = [NSMutableDictionary dictionary];
                }
                if (gAutoSwitchCooldownLock == nil) {
                    gAutoSwitchCooldownLock = [[NSObject alloc] init];
                }

                NSString *hostUUID = _host.uuid ?: @"";
                NSTimeInterval now = CFAbsoluteTimeGetCurrent();
                BOOL canSwitch = YES;
                @synchronized (gAutoSwitchCooldownLock) {
                    NSNumber *nextAllowed = gAutoSwitchCooldownByHost[hostUUID];
                    if (nextAllowed && now < nextAllowed.doubleValue) {
                        canSwitch = NO;
                    } else if (hostUUID.length > 0) {
                        gAutoSwitchCooldownByHost[hostUUID] = @(now + AUTO_SWITCH_COOLDOWN_SEC);
                    }
                }

                if (canSwitch) {
                    NSString *oldAddress = _host.activeAddress;
                    _host.activeAddress = bestAddress;
                    Log(LOG_I, @"Auto-switched %@ from %@ (%.0fms) to %@ (%.0fms)", _host.name, oldAddress, currentLatency.doubleValue, bestAddress, bestLatency.doubleValue);

                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[NSNotificationCenter defaultCenter] postNotificationName:@"HostAutoAddressSwitched" object:nil userInfo:@{
                            @"uuid": _host.uuid ?: @"",
                            @"hostName": _host.name ?: @"",
                            @"oldAddress": oldAddress ?: @"",
                            @"newAddress": bestAddress ?: @"",
                            @"oldLatency": currentLatency ?: @(-1),
                            @"newLatency": bestLatency ?: @(-1)
                        }];
                    });
                }
            }
        }
    }

    // Persist state changes (including offline) so UI stays in sync
    DataManager *dataManager = [[DataManager alloc] init];
    [dataManager updateHost:_host];

    // Broadcast latency update for UI (SettingsModel)
    __weak typeof(self) weakSelf2 = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf2) strongSelf = weakSelf2;
        if (strongSelf) {
            NSString *uuid = [strongSelf getHost].uuid;
            if (uuid) {
                [[NSNotificationCenter defaultCenter] postNotificationName:@"HostLatencyUpdated" object:nil userInfo:@{
                    @"uuid": uuid,
                    @"latencies": latencies,
                    @"states": states
                }];
            }
        }
    });
}

- (ServerInfoResponse*) requestInfoAtAddress:(NSString*)address cert:(NSData*)cert {
    @autoreleasepool {
        HttpManager* hMan = [[HttpManager alloc] initWithHost:address
                                                     uniqueId:_uniqueId
                                                         serverCert:cert];
        ServerInfoResponse* response = [[ServerInfoResponse alloc] init];
        [hMan executeRequestSynchronously:[HttpRequest requestForResponse:response
                                                           withUrlRequest:[hMan newServerInfoRequest:true]
                                           fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
        return response;
    }
}

- (BOOL) checkResponse:(ServerInfoResponse*)response {
    if ([response isStatusOk]) {
        // If the response is from a different host then do not update this host
        if ((_host.uuid == nil || [[response getStringTag:TAG_UNIQUE_ID] isEqualToString:_host.uuid])) {
            return YES;
        } else {
            Log(LOG_I, @"Received response from incorrect host: %@ expected: %@", [response getStringTag:TAG_UNIQUE_ID], _host.uuid);
        }
    }
    return NO;
}

@end
