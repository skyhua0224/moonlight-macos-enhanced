//
//  DiscoveryWorker.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/2/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "DiscoveryWorker.h"
#import "Utils.h"
#import "HttpManager.h"
#import "ServerInfoResponse.h"
#import "HttpRequest.h"
#import "DataManager.h"

@implementation DiscoveryWorker {
    TemporaryHost* _host;
    NSString* _uniqueId;
}

static const float POLL_RATE = 2.0f; // Poll every 2 seconds

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

    return [orderedSet array];
}

- (void) discoverHost {
    NSArray *addresses = [self getHostAddressList];
    
    Log(LOG_D, @"%@ has %d unique addresses", _host.name, [addresses count]);
    
    dispatch_group_t group = dispatch_group_create();
    NSMutableDictionary *latencies = [[NSMutableDictionary alloc] init];
    NSMutableDictionary *states = [[NSMutableDictionary alloc] init];
    NSLock *lock = [[NSLock alloc] init];
    
    __block BOOL receivedResponse = NO;
    __block double minLatency = DBL_MAX;
    __block NSString *bestAddress = nil;
    __block ServerInfoResponse *bestResp = nil;
    
    __weak typeof(self) weakSelf = self;
    for (NSString *address in addresses) {
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
                [latencies setObject:@((int)rtt) forKey:address];
                [states setObject:@(1) forKey:address];
                
                if (rtt < minLatency) {
                    minLatency = rtt;
                    bestAddress = address;
                    bestResp = serverInfoResp;
                }
            } else {
                [states setObject:@(0) forKey:address];
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
    
    _host.state = receivedResponse ? StateOnline : StateOffline;
    
    if (receivedResponse && bestResp) {
        [bestResp populateHost:_host];
        _host.activeAddress = bestAddress;
        
        DataManager *dataManager = [[DataManager alloc] init];
        [dataManager updateHost:_host];
        
        Log(LOG_D, @"Received response from: %@\n{\n\t address:%@ \n\t localAddress:%@ \n\t externalAddress:%@ \n\t ipv6Address:%@ \n\t uuid:%@ \n\t mac:%@ \n\t pairState:%d \n\t online:%d \n\t activeAddress:%@ \n\t latency:%f ms\n}", _host.name, _host.address, _host.localAddress, _host.externalAddress, _host.ipv6Address, _host.uuid, _host.mac, _host.pairState, _host.state, _host.activeAddress, minLatency);
    }

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
