//
//  ServerInfoResponse.m
//  Moonlight
//
//  Created by Diego Waxemberg on 2/1/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "ServerInfoResponse.h"
#import <libxml2/libxml/xmlreader.h>
#import "MoonlightEnhanced-Swift.h"

@implementation ServerInfoResponse
@synthesize data, statusCode, statusMessage;

- (void) populateWithData:(NSData *)xml {
    self.data = xml;
    [super parseData];
}

- (void) populateHost:(TemporaryHost*)host {
    [self populateHost:host updatePairState:YES];
}

- (void) populateHost:(TemporaryHost*)host updatePairState:(BOOL)updatePairState {
    host.name = [[self getStringTag:TAG_HOSTNAME] trim];
    host.uuid = [[self getStringTag:TAG_UNIQUE_ID] trim];
    host.mac = [[self getStringTag:TAG_MAC_ADDRESS] trim];
    host.currentGame = [[self getStringTag:TAG_CURRENT_GAME] trim];
    
    // We might get an IPv4 loopback address if we're using GS IPv6 Forwarder
    NSString *lanAddr = [[self getStringTag:TAG_LOCAL_IP] trim];
    if (![lanAddr hasPrefix:@"127."]) {
        host.localAddress = lanAddr;
    }
    
    // Modern GFE versions don't actually give us a WAN address anymore
    // so we leave the one that we populated from mDNS discovery via STUN.
    NSString *wanAddr = [[self getStringTag:TAG_EXTERNAL_IP] trim];
    if (wanAddr) {
        host.externalAddress = wanAddr;
    }
    
    NSString *state = [[self getStringTag:TAG_STATE] trim];
    if (![state hasSuffix:@"_SERVER_BUSY"]) {
        // GFE 2.8 started keeping currentgame set to the last game played. As a result, it no longer
        // has the semantics that its name would indicate. To contain the effects of this change as much
        // as possible, we'll force the current game to zero if the server isn't in a streaming session.
        host.currentGame = @"0";
    }
    
    NSInteger pairStatus;
    if (!updatePairState) {
        // left as it is
    } else if ([self getIntTag:TAG_PAIR_STATUS value:&pairStatus]) {
        host.pairState = pairStatus ? PairStatePaired : PairStateUnpaired;
    } else {
        host.pairState = PairStateUnknown;
    }
    
    NSString *serverCodecModeString = [self getStringTag:@"ServerCodecModeSupport"];
    if (serverCodecModeString != nil) {
        host.serverCodecModeSupport = [[serverCodecModeString trim] intValue];
    }

    host.appVersion = [[self getStringTag:@"appversion"] trim];
    host.gfeVersion = [[self getStringTag:@"GfeVersion"] trim];

    // Foundation Sunshine announces itself with FsCapabilityVersion (absent on Sunshine and GFE).
    NSMutableDictionary<NSString *, NSString *> *fs = [NSMutableDictionary dictionary];
    for (NSString *tag in @[@"FsCapabilityVersion", @"FsFeatures", @"FsPlatform", @"FsOsVersion", @"FsGpu",
                            @"FsDisplayModes", @"FsHostIcon", @"FsHostAvatarVersion", @"FsEventSeq", @"FsSessionStarted",
                            @"VddCapabilityVersion", @"SunshineVersion", @"state", @"GfeVersion", @"appListEtag"]) {
        NSString *value = [[self getStringTag:tag] trim];
        if (value.length > 0) {
            fs[tag] = value;
        }
    }
    if (host.uuid.length > 0) {
        [MLDeckActivity ingestServerInfoWithHostUUID:host.uuid fields:fs];
    }
}

@end
