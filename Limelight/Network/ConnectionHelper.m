//
//  ConnectionHelper.m
//  Moonlight macOS
//
//  Created by Felix Kratz on 22.03.18.
//  Copyright © 2018 Felix Kratz. All rights reserved.
//

#import "ConnectionHelper.h"
#import "ServerInfoResponse.h"
#import "HttpManager.h"
#import "PairManager.h"
#import "DiscoveryManager.h"
#import "ConnectionEndpointStore.h"
#import "Utils.h"

@implementation ConnectionHelper

+(AppListResponse*) getAppListForHostWithHostIP:(NSString*) hostIP serverCert:(NSData*) cert uniqueID:(NSString*) uniqueId tries:(int)tries {
    if (hostIP.length == 0 || cert.length == 0) {
        // The app list is an HTTPS request: without a pinned certificate there is nothing to ask.
        Log(LOG_W, @"Not fetching the app list: no server certificate on record for %@", hostIP ?: @"(no address)");
        return nil;
    }
    HttpManager* hMan = [[HttpManager alloc] initWithHost:hostIP uniqueId:uniqueId serverCert:cert];
    
    AppListResponse* appListResp = nil;
    for (int i = 0; i < tries; i++) {
        appListResp = [[AppListResponse alloc] init];
        [hMan executeRequestSynchronously:[HttpRequest requestForResponse:appListResp withUrlRequest:[hMan newAppListRequest]]];
        if (![appListResp isStatusOk] || [appListResp getAppList] == nil) {
            Log(LOG_W, @"Failed to get applist on try %d at %@: %@", i, hostIP, appListResp.statusMessage);
            
            // Wait for one second then retry
            if (i + 1 < tries) [NSThread sleepForTimeInterval:1];
        }
        else {
            Log(LOG_I, @"App list successfully retreived at %@ - took %d tries", hostIP, i);
            break;
        }
    }
    
    return appListResp;
}

+(AppListResponse*) getAppListForHostWithHostIP:(NSString*) hostIP serverCert:(NSData*) cert uniqueID:(NSString*) uniqueId {
    return [self getAppListForHostWithHostIP:hostIP serverCert:cert uniqueID:uniqueId tries:5];
}

+(AppListResponse*) getAppListForHost:(TemporaryHost*)host uniqueID:(NSString*)uniqueId {
    NSData *cert = host.serverCert;
    if (cert.length == 0) {
        Log(LOG_W, @"Not fetching the app list: no server certificate on record for %@", host.name ?: @"(unknown)");
        return nil;
    }
    NSArray<NSString *> *endpoints = [ConnectionEndpointStore allEndpointsForHost:host];
    NSMutableOrderedSet<NSString *> *order = [NSMutableOrderedSet orderedSet];
    NSString *active = host.activeAddress;
    NSString *activeHost = nil;
    if (active.length > 0) [Utils parseAddress:active intoHost:&activeHost andPort:nil];
    // the address in use, with the port the host really listens on (allEndpointsForHost derives it from the host's own address)
    for (NSString *endpoint in endpoints) {
        NSString *h = nil, *p = nil;
        [Utils parseAddress:endpoint intoHost:&h andPort:&p];
        if (activeHost.length > 0 && h.length > 0 && [h caseInsensitiveCompare:activeHost] == NSOrderedSame && p.length > 0) [order addObject:endpoint];
    }
    if (active.length > 0) [order addObject:active];
    NSDictionary<NSString *, NSNumber *> *states = host.addressStates;
    for (NSString *endpoint in endpoints) {
        if (states[endpoint].boolValue) [order addObject:endpoint];   // discovery has had an answer there
    }
    for (NSString *endpoint in endpoints) [order addObject:endpoint];

    AppListResponse *last = nil;
    int tried = 0;
    for (NSString *address in order) {
        if (tried >= 6) break;
        // the first candidate gets the old tries, the others one: a dead port must not hold the page up
        AppListResponse *resp = [self getAppListForHostWithHostIP:address serverCert:cert uniqueID:uniqueId tries:(tried == 0 ? 3 : 1)];
        tried++;
        if (resp != nil && [resp isStatusOk] && [resp getAppList] != nil) {
            if (tried > 1) Log(LOG_I, @"[apps] the app list answered at %@ (the address in use, %@, did not)", address, active ?: @"-");
            return resp;
        }
        last = resp;
    }
    return last;
}

@end
