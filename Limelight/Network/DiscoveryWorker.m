//
//  DiscoveryWorker.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/2/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "DiscoveryWorker.h"
#import "LatencyProbe.h"
#import "ConceptHarness.h"
#import "Utils.h"
#import "ConnectionEndpointStore.h"
#import "HttpManager.h"
#import "ServerInfoResponse.h"
#import "HttpRequest.h"
#import "DataManager.h"
#import "StreamingSessionManager.h" // Import for streaming state check
#import "MoonlightEnhanced-Swift.h"

#import "HostPathRank.h"
#import "HostPathRoute.h"
#include <stdlib.h>
#include <string.h>

static dispatch_semaphore_t gProbeSlots = NULL;
static dispatch_once_t gProbeSlotsOnce;
static const int kProbeSlots = 8;

@implementation DiscoveryWorker {
    TemporaryHost* _host;
    NSString* _uniqueId;
    int _stablePolls;
    int _offlinePolls;
    BOOL _fsEvents;
    NSInteger _fsSeq;
    NSInteger _raceEpoch;
}

static const NSTimeInterval ADDRESS_FAILURE_COOLDOWN_SEC = 30.0;
static NSMutableDictionary<NSString*, NSMutableDictionary<NSString*, NSNumber*>*> *gAddressCooldownByHost = nil;
static NSObject *gAddressCooldownLock = nil;
static dispatch_once_t gAddressCooldownOnceToken;
// Paired -> Unpaired: a TLS answer must say PairStatus=0 in this round and in the next one as well
static const NSInteger PAIR_DOWNGRADE_CONFIRMATIONS_REQUIRED = 2;
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
    [[MLHostPathSignals shared] start];
    while (!self.cancelled) {
        // A launch is pending or a stream is open: nothing is asked of any computer until it is over (probes on
        // five addresses, latency probes and the events wait all shared the link with the stream).
        if ([MLNetworkQuiet isQuiet]) {
            [NSThread sleepForTimeInterval:0.25];
            continue;
        }
        NSInteger wake = [[MLHostPathSignals shared] generation];
        [self discoverHost];
        if (!self.cancelled) {
            if ([self fsEventsEnabled] && [self longPollEvents]) {
                continue;
            }
            NSTimeInterval wait = [self backoffInterval];
            for (NSTimeInterval waited = 0; waited < wait && !self.cancelled; waited += 0.1) {
                if ([[MLHostPathSignals shared] generation] != wake) {
                    break;
                }
                [NSThread sleepForTimeInterval:0.1];
            }
        }
    }
}

/// _fsEvents is written by the commit of a round (another thread) and read by this worker's loop: read it under the
/// same lock the writers hold. Nothing is called while it is held.
- (BOOL)fsEventsEnabled {
    @synchronized (self) {
        return _fsEvents;
    }
}

- (NSTimeInterval)backoffInterval {
    if (_host.state != StateOnline) {
        _stablePolls = 0;
        _offlinePolls++;
        if (_offlinePolls <= 1) {
            return 5.0;
        }
        if (_offlinePolls == 2) {
            return 10.0;
        }
        if (_offlinePolls == 3) {
            return 20.0;
        }
        return 30.0;
    }
    _offlinePolls = 0;
    _stablePolls++;
    /* Failure backoff is only for an offline host. An online host stays on the
       event long-poll, or on this quiet refresh when the host has no events.
       A wake, focus, mDNS result, or the host page ends the wait immediately. */
    return [MLHostEventsRules refreshIntervalWithEventsEnabled:[self fsEventsEnabled]];
}

- (void)releaseProbeSlot:(BOOL)held group:(dispatch_group_t)group {
    if (held && gProbeSlots != NULL) {
        dispatch_semaphore_signal(gProbeSlots);
    }
    dispatch_group_leave(group);
}

- (int)smoothedRttMsForAddress:(NSString *)address sample:(int)sample success:(BOOL)success {
    static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *memory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ memory = [NSMutableDictionary dictionary]; });
    NSString *uuid = _host.uuid ?: @"";
    if (uuid.length == 0 || address.length == 0 || !success || sample < 0) {
        return sample;
    }
    @synchronized (memory) {
        NSMutableDictionary *host = memory[uuid];
        if (host == nil) {
            host = [NSMutableDictionary dictionary];
            memory[uuid] = host;
        }
        double previous = host[address] != nil ? [host[address] doubleValue] : -1;
        double next = host_path_smooth_rtt(previous, sample);
        host[address] = @(next);
        return (int)(next + 0.5);
    }
}

- (BOOL)longPollEvents {
    NSString *address = nil;
    NSData *cert = nil;
    NSInteger seqSnapshot = 0;
    @synchronized (self) {
        address = _host.activeAddress;
        cert = _host.serverCert;
        seqSnapshot = _fsSeq;
    }
    if (address.length == 0) {
        return NO;
    }
    NSDate *started = [NSDate date];
    HttpManager *manager = [[HttpManager alloc] initWithHost:address uniqueId:_uniqueId serverCert:cert];
    ServerInfoResponse *response = [[ServerInfoResponse alloc] init];
    NSURLRequest *request = [manager newServerInfoWaitRequestAfterSeq:seqSnapshot timeoutSec:25];
    [manager executeRequestSynchronously:[HttpRequest requestForResponse:response
                                                          withUrlRequest:request
                                           fallbackError:401
                                           fallbackRequest:[manager newHttpServerInfoRequest:YES]]];
    NSTimeInterval elapsed = -[started timeIntervalSinceNow];
    @synchronized (self) {
        BOOL valid = [self checkResponse:response];
        MLHostEventsAnswer *answer = [MLHostEventsRules answerWithValid:valid
                                                            previousSeq:_fsSeq
                                                            answeredSeq:valid ? [MLHostEventsRules integer:[response getStringTag:@"FsEventSeq"]] : 0
                                                                elapsed:elapsed];
        if (!answer.accepted) {
            if (!answer.eventsStillEnabled) {
                _fsEvents = NO;
            }
            return NO;
        }
        _fsSeq = answer.nextSeq;
        if (!answer.eventsStillEnabled) {
            /* The host ignored fsWait and answered immediately. Fall back to probes. */
            _fsEvents = NO;
            return NO;
        }
        if (answer.changed) {
            // an events answer can be the plain-HTTP fallback: it never decides the pair state (the discovery round does)
            [response populateHost:_host updatePairState:NO];
            _stablePolls = 0;
        }
        return answer.changed;
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
    if ([ConceptHarness networkMocked]) {
        return;
    }
    // also for the callers outside the worker loop (an mDNS answer, the page's own timer)
    if ([MLNetworkQuiet isQuiet]) {
        return;
    }
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
                // The pinned address is probed with the others. It does not go first:
                // a user-chosen default overrides 自动 only when connecting.
                if (![probeAddresses containsObject:selectedConnectionMethod]) {
                    [probeAddresses addObject:selectedConnectionMethod];
                }
            }
        }
    }
    
    Log(LOG_D, @"%@ has %d unique addresses (selected=%@)", _host.name, [probeAddresses count],
        selectedConnectionMethod ?: @"Auto");
    int lastGood = [self lastGoodIndexInAddresses:probeAddresses];
    [self orderProbesForHappyEyeballs:probeAddresses lastGood:lastGood];
    
    dispatch_group_t group = dispatch_group_create();
    // Start from the last round's results: an address that answers (or fails) is overwritten the moment its own
    // probe ends, and the others keep their last value instead of vanishing from the page for the length of
    // the round (a dead route takes a full timeout).
    NSMutableDictionary *latencies = [_host.addressLatencies mutableCopy] ?: [[NSMutableDictionary alloc] init];
    NSMutableDictionary *states = [_host.addressStates mutableCopy] ?: [[NSMutableDictionary alloc] init];
    // `lock` guards the two dictionaries and the flags below and nothing else: nothing is called while it is held
    NSLock *lock = [[NSLock alloc] init];
    NSString *notifyUUID = _host.uuid ?: @"";
    // One address' result, published at once: copied under the lock, merged into the host as immutable copies and
    // broadcast on the main queue, so 局域网 shows its latency after one round trip and a dead route turns 超时 when
    // its own timeout ends, not when the round does.
    void (^publishPartial)(void) = ^{
        NSDictionary *statesCopy = nil, *latenciesCopy = nil;
        [lock lock];
        statesCopy = [states copy];
        latenciesCopy = [latencies copy];
        [lock unlock];
        TemporaryHost *hostForPartial = [self getHost];
        hostForPartial.addressStates = statesCopy;
        hostForPartial.addressLatencies = latenciesCopy;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (notifyUUID.length > 0) {
                [[NSNotificationCenter defaultCenter] postNotificationName:@"HostLatencyUpdated" object:nil userInfo:@{
                    @"uuid": notifyUUID, @"latencies": latenciesCopy, @"states": statesCopy
                }];
            }
        });
    };
    
    __block BOOL receivedResponse = NO;
    __block BOOL publishedOnline = NO;
    __block double minLatency = DBL_MAX;
    __block NSString *bestAddress = nil;
    __block ServerInfoResponse *bestResp = nil;
    __block BOOL sawExplicitPairedStatus = NO;
    __block BOOL sawExplicitUnpairedStatus = NO;
    __block int attempted = 0;

    __weak typeof(self) weakSelf = self;
    NSInteger wakeGen = [[MLHostPathSignals shared] generation];
    _raceEpoch += 1;
    NSInteger epoch = _raceEpoch;
    NSUInteger probePosition = 0;
    for (NSString *address in probeAddresses) {
        if (self.cancelled) break;
        
        if ([self shouldSkipAddressDueToCooldown:address]) {
            Log(LOG_D, @"Skipping %@ for %@ (cooldown active)", address, _host.name);
            continue;
        }
        
        NSTimeInterval delay = host_path_presence_start_ms((int)probePosition) / 1000.0;
        probePosition++;
        dispatch_group_enter(group);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                dispatch_group_leave(group);
                return;
            }
            dispatch_once(&gProbeSlotsOnce, ^{
                gProbeSlots = dispatch_semaphore_create(kProbeSlots);
            });
            int timeoutMs = [strongSelf presenceTimeoutMsForAddress:address];
            NSDate *budgetStarted = [NSDate date];
            if (dispatch_semaphore_wait(gProbeSlots, dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeoutMs * NSEC_PER_MSEC)) != 0) {
                Log(LOG_D, @"Skipping %@ for %@ (probe slots busy)", address, [strongSelf getHost].name);
                dispatch_group_leave(group);
                return;
            }
            NSTimeInterval budget = (timeoutMs / 1000.0) - (-[budgetStarted timeIntervalSinceNow]);
            if (budget < 0.05) {
                [strongSelf releaseProbeSlot:YES group:group];
                return;
            }
            [lock lock];
            attempted++;
            [lock unlock];

            NSDate *start = [NSDate date];
            ServerInfoResponse* serverInfoResp = [strongSelf requestInfoAtAddress:address cert:[strongSelf getHost].serverCert budget:budget];
            NSTimeInterval rtt = -[start timeIntervalSinceNow] * 1000.0;
            if (strongSelf.cancelled) {
                [strongSelf releaseProbeSlot:YES group:group];
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
                    // no latency yet: the time of this whole serverinfo request is not a latency (see LatencyProbe)
                    earlyStates = [states copy];
                    earlyLatencies = [latencies copy];
                }
                [lock unlock];
                if (publish) {
                    // takes the worker's own lock: called after the results lock is released, never nested
                    [strongSelf noteEventsFromResponse:serverInfoResp];
                    TemporaryHost *host = [strongSelf getHost];
                    BOOL wasOnline = NO;
                    @synchronized (strongSelf) {
                        wasOnline = host.state == StateOnline;
                        host.state = StateOnline;
                        host.addressStates = earlyStates;
                        host.addressLatencies = earlyLatencies;
                        if (autoConnectionMode && (!wasOnline || host.activeAddress.length == 0) &&
                            ![[StreamingSessionManager shared] isStreamingHost:host.uuid]) {
                            host.activeAddress = address;
                        }
                    }
                    if (!wasOnline && strongSelf.onlineHandler && !strongSelf.probeOnly) strongSelf.onlineHandler(host);
                    Log(LOG_I, @"[discovery] First verified endpoint: host=%@ elapsedMs=%.0f", host.name, rtt);
                }
            }
            // the probe slot is free as soon as the answer is in: the round-trip measurement below can take seconds on a slow path
            // and must not make the other addresses wait for a slot
            if (gProbeSlots != NULL) {
                dispatch_semaphore_signal(gProbeSlots);
            }
            // the latency: the application round trip, measured after the answer, outside every lock
            NSNumber *appRtt = nil;
            if (success && !strongSelf.cancelled) {
                appRtt = [LatencyProbe appRttMsForAddress:address probeTotalMs:(int)rtt];
            }
            [lock lock];
            if (success) {
                receivedResponse = YES;
                NSInteger rawPairStatus = 0;
                BOOL hasPairTag = [serverInfoResp getIntTag:TAG_PAIR_STATUS value:&rawPairStatus];
                // With a pinned certificate only an answer over HTTPS with our client certificate is evidence about pairing;
                // a plain-HTTP answer (HTTPS failed or ran out of budget) says PairStatus=0 to everybody.
                BOOL evidence = hasPairTag && (serverInfoResp.receivedOverClientTLS || [strongSelf getHost].serverCert == nil);
                if (evidence) {
                    if (rawPairStatus == 0) {
                        sawExplicitUnpairedStatus = YES;
                    } else {
                        sawExplicitPairedStatus = YES;
                    }
                }
                Log(LOG_I, @"[pair] %@ %@ via %@: PairStatus=%@ -> %@", [strongSelf getHost].name, address,
                    serverInfoResp.receivedOverClientTLS ? @"HTTPS+cert" : @"HTTP",
                    hasPairTag ? [NSString stringWithFormat:@"%ld", (long)rawPairStatus] : @"absent",
                    evidence ? @"evidence" : @"ignored for pairing");
                if (appRtt != nil) {
                    [latencies setObject:appRtt forKey:address];
                } else {
                    [latencies removeObjectForKey:address];
                }
                [states setObject:@(1) forKey:address];

                double bestMetric = appRtt != nil ? appRtt.doubleValue : rtt;
                if (bestMetric < minLatency) {
                    minLatency = bestMetric;
                    bestAddress = address;
                    bestResp = serverInfoResp;
                }
            } else {
                [states setObject:@(0) forKey:address];
            }
            [lock unlock];
            // the address cooldown has its own lock: taken here, after the results lock is released, never nested
            [strongSelf recordAddress:address success:success];
            if (!strongSelf.cancelled) {
                publishPartial();
            }
            
            [strongSelf releaseProbeSlot:NO group:group];   // the slot itself was released after the answer
        });
    }
    
    __block BOOL committed = NO;
    NSLock *commitLock = [[NSLock alloc] init];
    void (^commit)(void) = ^{
        [commitLock lock];
        BOOL run = !committed;
        committed = YES;
        [commitLock unlock];
        if (!run || _raceEpoch != epoch) {
            return;
        }
        [lock lock];
        int tries = attempted;
        BOOL any = receivedResponse;
        [lock unlock];
        if (tries == 0 && !any) {
            // Cooldown or a busy probe slot skipped every address. Leave the
            // current state alone. An empty address list is still offline.
            if (probeAddresses.count > 0) {
                return;
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
