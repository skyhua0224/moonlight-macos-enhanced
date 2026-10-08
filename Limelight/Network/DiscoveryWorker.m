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
#import "MoonlightEnhanced-Swift.h"

@implementation DiscoveryWorker {
    TemporaryHost* _host;
    NSString* _uniqueId;
}

static const float POLL_RATE = 2.0f; // Poll every 2 seconds
static const NSTimeInterval ADDRESS_FAILURE_COOLDOWN_SEC = 30.0;
static NSMutableDictionary<NSString*, NSMutableDictionary<NSString*, NSNumber*>*> *gAddressCooldownByHost = nil;
static NSObject *gAddressCooldownLock = nil;
static dispatch_once_t gAddressCooldownOnceToken;
static const double AUTO_SWITCH_PING_IMPROVEMENT_MS = 20.0;
static const NSTimeInterval AUTO_SWITCH_COOLDOWN_SEC = 30.0;
static NSMutableDictionary<NSString*, NSNumber*> *gAutoSwitchCooldownByHost = nil;
static NSObject *gAutoSwitchCooldownLock = nil;
static dispatch_once_t gAutoSwitchCooldownOnceToken;
static const NSInteger PAIR_DOWNGRADE_CONFIRMATIONS_REQUIRED = 3;
static NSMutableDictionary<NSString*, NSNumber*> *gUnpairedObservationCountByHost = nil;
static NSObject *gUnpairedObservationLock = nil;
static dispatch_once_t gUnpairedObservationOnceToken;

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
            // Keep cancellation responsive even between discovery cycles.
            for (float waited = 0; waited < POLL_RATE && !self.cancelled; waited += 0.1f)
                [NSThread sleepForTimeInterval:0.1];
        }
    }
}

- (NSArray*) getHostAddressList {
    // Use the shared endpoint store so custom HTTP ports are propagated to
    // bare local/external addresses. A host may advertise 192.168.x.x while
    // its paired GameStream endpoint is actually 192.168.x.x:57989.
    return [ConnectionEndpointStore allEndpointsForHost:_host];
}

- (BOOL)shouldBypassCooldownForAddress:(NSString *)address {
    if (address.length == 0) {
        return NO;
    }
    if (_host.state != StateOnline) return YES;
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

    // Thread-safe initialization using dispatch_once
    dispatch_once(&gAddressCooldownOnceToken, ^{
        gAddressCooldownLock = [[NSObject alloc] init];
        gAddressCooldownByHost = [NSMutableDictionary dictionary];
    });

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

    // Thread-safe initialization using dispatch_once
    dispatch_once(&gAddressCooldownOnceToken, ^{
        gAddressCooldownLock = [[NSObject alloc] init];
        gAddressCooldownByHost = [NSMutableDictionary dictionary];
    });

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
    // Probe every known endpoint for host liveness even when the user pinned
    // one connection method. A pinned route controls streaming, but it must
    // not hide a reachable alternate route from the host status indicator.
    NSMutableArray<NSString *> *probeAddresses = [addresses mutableCopy];

    NSDictionary *hostSettings = nil;
    NSString *selectedConnectionMethod = nil;
    BOOL autoConnectionMode = YES;
    if (_host.uuid.length > 0) {
        hostSettings = [SettingsClass getSettingsFor:_host.uuid];
        if ([hostSettings isKindOfClass:[NSDictionary class]]) {
            selectedConnectionMethod = hostSettings[@"connectionMethod"];
            if (selectedConnectionMethod.length > 0 && ![selectedConnectionMethod isEqualToString:@"Auto"]) {
                autoConnectionMode = NO;
                if (![probeAddresses containsObject:selectedConnectionMethod]) {
                    [probeAddresses insertObject:selectedConnectionMethod atIndex:0];
                } else {
                    NSUInteger selectedIndex = [probeAddresses indexOfObject:selectedConnectionMethod];
                    if (selectedIndex != 0) {
                        [probeAddresses exchangeObjectAtIndex:0 withObjectAtIndex:selectedIndex];
                    }
                }
            }
        }
    }
    
    Log(LOG_D, @"%@ has %d unique addresses (selected=%@)", _host.name, [probeAddresses count],
        selectedConnectionMethod ?: @"Auto");
    
    dispatch_group_t group = dispatch_group_create();
    NSMutableDictionary *latencies = [[NSMutableDictionary alloc] init];
    NSMutableDictionary *states = [[NSMutableDictionary alloc] init];
    NSLock *lock = [[NSLock alloc] init];
    
    __block BOOL receivedResponse = NO;
    __block BOOL publishedOnline = NO;
    __block double minLatency = DBL_MAX;
    __block NSString *bestAddress = nil;
    __block ServerInfoResponse *bestResp = nil;
    __block BOOL sawExplicitPairedStatus = NO;
    __block BOOL sawExplicitUnpairedStatus = NO;

    __weak typeof(self) weakSelf = self;
    for (NSString *address in probeAddresses) {
        if (self.cancelled) break;
        
        if ([self shouldSkipAddressDueToCooldown:address]) {
            Log(LOG_D, @"Skipping %@ for %@ (cooldown active)", address, _host.name);
            continue;
        }
        
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
            if (strongSelf.cancelled) {
                dispatch_group_leave(group);
                return;
            }
            
            BOOL success = [strongSelf checkResponse:serverInfoResp];
            if (!success) {
                Log(LOG_D, @"Discovery probe failed: host=%@ address=%@ status=%ld message=%@",
                    [strongSelf getHost].name,
                    address,
                    (long)serverInfoResp.statusCode,
                    serverInfoResp.statusMessage ?: @"unknown");
            }
            
            // Host availability must not wait for unrelated dead routes or
            // ICMP. Only a serverinfo response for the expected UUID qualifies.
            BOOL publish = NO;
            NSDictionary *earlyStates = nil;
            NSDictionary *earlyLatencies = nil;
            if (success && !strongSelf.cancelled) {
                [lock lock];
                if (!publishedOnline) {
                    publishedOnline = YES;
                    publish = YES;
                    states[address] = @1;
                    latencies[address] = @((int)rtt);
                    earlyStates = [states copy];
                    earlyLatencies = [latencies copy];
                }
                [lock unlock];
                if (publish) {
                    TemporaryHost *host = [strongSelf getHost];
                    BOOL wasOnline = host.state == StateOnline;
                    host.state = StateOnline;
                    host.addressStates = earlyStates;
                    host.addressLatencies = earlyLatencies;
                    if (autoConnectionMode && (!wasOnline || host.activeAddress.length == 0) &&
                        ![[StreamingSessionManager shared] isStreamingHost:host.uuid]) {
                        host.activeAddress = address;
                    }
                    if (!wasOnline && strongSelf.onlineHandler) strongSelf.onlineHandler(host);
                    Log(LOG_I, @"[discovery] First verified endpoint: host=%@ elapsedMs=%.0f", host.name, rtt);
                }
            }
            NSNumber *pingMs = success ? [LatencyProbe icmpPingMsForAddress:address] : nil;
            [lock lock];
            if (success) {
                receivedResponse = YES;
                NSInteger rawPairStatus = 0;
                if ([serverInfoResp getIntTag:TAG_PAIR_STATUS value:&rawPairStatus]) {
                    if (rawPairStatus == 0) {
                        sawExplicitUnpairedStatus = YES;
                    } else {
                        sawExplicitPairedStatus = YES;
                    }
                }
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
    for (NSString *addr in probeAddresses) {
        NSNumber *state = states[addr];
        if (state && state.intValue == 1) {
            onlineCount++;
            if (!firstOnlineAddress) {
                firstOnlineAddress = addr;
            }
        }
    }
    int totalCount = (int)probeAddresses.count;
    int offlineCount = totalCount - onlineCount;

    NSInteger previousState = _host.state;
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
        PairState previousPairState = _host.pairState;
        BOOL hadPinnedCert = (_host.serverCert != nil);

        [bestResp populateHost:_host];

        // Guard against transient discovery responses falsely downgrading a paired host.
        // Evaluate pair status across all successful responses in this poll cycle,
        // not only the lowest-latency one, to avoid single-endpoint false downgrades.
        if (hadPinnedCert && previousPairState == PairStatePaired) {
            if (sawExplicitPairedStatus) {
                _host.pairState = PairStatePaired;
                dispatch_once(&gUnpairedObservationOnceToken, ^{
                    gUnpairedObservationLock = [[NSObject alloc] init];
                    gUnpairedObservationCountByHost = [NSMutableDictionary dictionary];
                });
                NSString *hostUUID = _host.uuid ?: @"";
                @synchronized (gUnpairedObservationLock) {
                    [gUnpairedObservationCountByHost removeObjectForKey:hostUUID];
                }
            } else if (!sawExplicitUnpairedStatus) {
                if (_host.pairState != PairStatePaired) {
                    Log(LOG_W, @"Ignoring pairState downgrade for %@ (missing PairStatus; keeping Paired)", _host.name);
                }
                _host.pairState = PairStatePaired;
            } else {
                dispatch_once(&gUnpairedObservationOnceToken, ^{
                    gUnpairedObservationLock = [[NSObject alloc] init];
                    gUnpairedObservationCountByHost = [NSMutableDictionary dictionary];
                });

                NSString *hostUUID = _host.uuid ?: @"";
                NSInteger observationCount = 0;
                @synchronized (gUnpairedObservationLock) {
                    NSNumber *existing = gUnpairedObservationCountByHost[hostUUID];
                    observationCount = existing.integerValue + 1;
                    gUnpairedObservationCountByHost[hostUUID] = @(observationCount);
                }

                if (observationCount < PAIR_DOWNGRADE_CONFIRMATIONS_REQUIRED) {
                    Log(LOG_W, @"Ignoring transient unpaired state for %@ (%ld/%ld confirmations)",
                        _host.name,
                        (long)observationCount,
                        (long)PAIR_DOWNGRADE_CONFIRMATIONS_REQUIRED);
                    _host.pairState = PairStatePaired;
                } else {
                    Log(LOG_I, @"Accepting Paired->Unpaired for %@ after %ld confirmations",
                        _host.name,
                        (long)observationCount);
                }
            }
        }

        if (autoConnectionMode && !isStreamingThisHost) {
            if (firstOnlineAddress != nil) {
                _host.activeAddress = firstOnlineAddress;
            } else if (bestAddress != nil) {
                _host.activeAddress = bestAddress;
            }
        } else if (!autoConnectionMode && !isStreamingThisHost && selectedConnectionMethod.length > 0) {
            // Keep the user's selected route even when it is currently down.
            // The host stays online if another endpoint answered; the stream
            // launch path can then offer to switch routes explicitly.
            _host.activeAddress = selectedConnectionMethod;
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
    if (autoConnectionMode && receivedResponse && !isStreamingThisHost && bestAddress != nil && _host.activeAddress != nil) {
        if (![bestAddress isEqualToString:_host.activeAddress]) {
            NSNumber *currentLatency = latencies[_host.activeAddress];
            NSNumber *bestLatency = latencies[bestAddress];
            if (currentLatency && bestLatency && (currentLatency.doubleValue - bestLatency.doubleValue) >= AUTO_SWITCH_PING_IMPROVEMENT_MS) {
                // Thread-safe initialization using dispatch_once
                dispatch_once(&gAutoSwitchCooldownOnceToken, ^{
                    gAutoSwitchCooldownLock = [[NSObject alloc] init];
                    gAutoSwitchCooldownByHost = [NSMutableDictionary dictionary];
                });

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

                    NSString *uuidForNotification = _host.uuid ?: @"";
                    NSString *hostNameForNotification = _host.name ?: @"";
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[NSNotificationCenter defaultCenter] postNotificationName:@"HostAutoAddressSwitched" object:nil userInfo:@{
                            @"uuid": uuidForNotification,
                            @"hostName": hostNameForNotification,
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
    if (_host.state != previousState && self.onlineHandler) self.onlineHandler(_host);

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
                                           fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest:true]]];
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
