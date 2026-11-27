//
//  MDNSManager.m
//  Moonlight
//
//  Created by Diego Waxemberg on 10/14/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "MDNSManager.h"
#import "TemporaryHost.h"
#import "MoonlightEnhanced-Swift.h"

#include <arpa/inet.h>

#include <Limelight.h>

#import <AppKit/AppKit.h>

static NSString * const MDNSAutoDiscoverNewHostsKey = @"autoDiscoverNewHosts";
static NSString * const MDNSDiscoveryPreferencesChangedName = @"MoonlightDiscoveryPreferencesChanged";

// The host list is on screen when the app is in front and one of its windows can be seen. Nothing else needs the
// Bonjour browser: the stored computers are polled over HTTP, which is unicast.
static BOOL MDNSDefaultForeground(void) {
    if (NSApp == nil) {
        return YES;
    }
    if (!NSApp.isActive || NSApp.isHidden) {
        return NO;
    }
    for (NSWindow *window in NSApp.windows) {
        if (window.isVisible && !window.isMiniaturized && (window.occlusionState & NSWindowOcclusionStateVisible) && window.canBecomeMainWindow) {
            return YES;
        }
    }
    return NO;
}

@implementation MDNSManager {
    NSNetServiceBrowser* mDNSBrowser;
    NSMutableArray* services;
    NSMutableDictionary<NSString *, NSDate *> *failedResolveUntil;
    BOOL scanActive;        // discovery asked for a search (startDiscovery); policy decides whether it really runs
    BOOL searching;         // the browser is being restarted by the schedule below
    BOOL browserStarted;
    NSUInteger searchRound;
    NSTimer *searchTimer;
}

static NSString* NV_SERVICE_TYPE = @"_nvstream._tcp";

+ (BOOL)autoDiscoveryEnabledInDefaults:(NSUserDefaults *)defaults {
    if ([defaults objectForKey:MDNSAutoDiscoverNewHostsKey] == nil) {
        return YES;
    }
    return [defaults boolForKey:MDNSAutoDiscoverNewHostsKey];
}

// Apple's NSNetServiceBrowser documentation: the browser keeps its own Bonjour query schedule once started, and
// stop ends it. RFC 6762 section 5.2 asks a continuous querier to send its second query at least one second after
// the first and to double the interval each time, up to at least 60 minutes between queries. The host page wants
// quick results when it opens, so the first six restarts stay five seconds apart (30 s); after that the interval
// doubles to a 60 s cap, and a restart that finds nothing new costs one packet per minute.
+ (NSTimeInterval)restartIntervalForRound:(NSUInteger)round {
    if (round < 6) {
        return 5.0;
    }
    NSTimeInterval interval = 5.0 * (NSTimeInterval)(1u << MIN(round - 5, (NSUInteger)10));
    return MIN(interval, 60.0);
}

- (NSTimeInterval)restartIntervalForRound:(NSUInteger)round {
    return [MDNSManager restartIntervalForRound:round];
}

- (NSNetServiceBrowser *)makeBrowser {
    return [[NSNetServiceBrowser alloc] init];
}

static void MDNSRunOnMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

- (id) initWithCallback:(id<MDNSCallback>)callback {
    self = [super init];
    
    self.callback = callback;
    
    scanActive = FALSE;
    _defaults = [NSUserDefaults standardUserDefaults];
    _foregroundProvider = ^BOOL { return MDNSDefaultForeground(); };
    
    services = [[NSMutableArray alloc] init];
    failedResolveUntil = [[NSMutableDictionary alloc] init];

    // The switch, the window and the app being in front all change what may be searched; each takes effect at once.
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    for (NSNotificationName name in @[MDNSDiscoveryPreferencesChangedName,
                                      NSApplicationDidBecomeActiveNotification, NSApplicationDidResignActiveNotification,
                                      NSApplicationDidHideNotification, NSApplicationDidUnhideNotification,
                                      NSWindowDidChangeOcclusionStateNotification, NSWindowWillCloseNotification,
                                      NSWindowDidMiniaturizeNotification, NSWindowDidDeminiaturizeNotification]) {
        [center addObserver:self selector:@selector(searchPolicyInputChanged:) name:name object:nil];
    }
    
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [searchTimer invalidate];
    [mDNSBrowser setDelegate:nil];
    [mDNSBrowser stop];
}

- (BOOL)searchRunning {
    return searching;
}

- (void)searchPolicyInputChanged:(NSNotification *)note {
    // WillClose and the occlusion change arrive before the window state settles: look again on the next turn.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshSearchPolicy];
    });
}

- (void)refreshSearchPolicy {
    MDNSRunOnMain(^{
        [self reconcileSearch];
    });
}

// The one place that starts or stops the browser. Main thread only.
- (void)reconcileSearch {
    BOOL want = scanActive
        && [MDNSManager autoDiscoveryEnabledInDefaults:self.defaults]
        && (self.foregroundProvider == nil || self.foregroundProvider());
    if (want == searching) {
        return;
    }
    if (want) {
        Log(LOG_I, @"Starting mDNS search");
        searching = YES;
        searchRound = 0;
        [self runSearchRound];
    } else {
        Log(LOG_I, @"Stopping mDNS search (discovery %@, switch %@)", scanActive ? @"on" : @"off",
            [MDNSManager autoDiscoveryEnabledInDefaults:self.defaults] ? @"on" : @"off");
        searching = NO;
        [self stopBrowser];
    }
}

- (void)stopBrowser {
    [searchTimer invalidate];
    searchTimer = nil;
    if (browserStarted) {
        browserStarted = NO;
        [mDNSBrowser stop];
    }
}

- (void) searchForHosts {
    MDNSRunOnMain(^{
        if (scanActive) {
            return;
        }
        Log(LOG_I, @"Starting mDNS discovery");
        scanActive = TRUE;
        [self reconcileSearch];
    });
}

- (void) stopSearching {
    MDNSRunOnMain(^{
        if (!scanActive) {
            return;
        }
        Log(LOG_I, @"Stopping mDNS discovery");
        scanActive = FALSE;
        [self reconcileSearch];
    });
}

- (void) forgetHosts {
    [services removeAllObjects];
}

+ (NSString*)sockAddrToString:(NSData*)addrData {
    if (addrData.length < sizeof(struct sockaddr)) {
        return nil;
    }
    char addrStr[INET6_ADDRSTRLEN];
    memset(addrStr, 0, sizeof(addrStr));
    struct sockaddr* addr = (struct sockaddr*)[addrData bytes];
    if (addr->sa_family == AF_INET) {
        if (addrData.length < sizeof(struct sockaddr_in)) {
            return nil;
        }
        if (inet_ntop(addr->sa_family, &((struct sockaddr_in*)addr)->sin_addr, addrStr, sizeof(addrStr)) == NULL) {
            return nil;
        }
    } else if (addr->sa_family == AF_INET6) {
        if (addrData.length < sizeof(struct sockaddr_in6)) {
            return nil;
        }
        struct sockaddr_in6* sin6 = (struct sockaddr_in6*)addr;
        if (inet_ntop(addr->sa_family, &sin6->sin6_addr, addrStr, sizeof(addrStr)) == NULL) {
            return nil;
        }
        if (sin6->sin6_scope_id != 0) {
            // Link-local addresses with scope IDs are special
            return [NSString stringWithFormat: @"%s%%%u", addrStr, sin6->sin6_scope_id];
        }
    } else {
        return nil;
    }
    return [NSString stringWithFormat: @"%s", addrStr];
}

+ (BOOL)isAddress:(uint8_t*)address inSubnet:(uint8_t*)subnet netmask:(int)bits {
    for (int i = 0; i < bits; i++) {
        uint8_t mask = 1 << (i % 8);
        if ((address[i / 8] & mask) != (subnet[i / 8] & mask)) {
            return NO;
        }
    }
    return YES;
}

+ (BOOL)isLocalIpv6Address:(NSData*)addrData {
    struct sockaddr_in6* sin6 = (struct sockaddr_in6*)[addrData bytes];
    if (sin6->sin6_family != AF_INET6) {
        return NO;
    }
    
    uint8_t* addrBytes = sin6->sin6_addr.s6_addr;
    uint8_t prefix[2];
    
    // fe80::/10
    prefix[0] = 0xfe;
    prefix[1] = 0x80;
    if ([MDNSManager isAddress:addrBytes inSubnet:prefix netmask:10]) {
        // Link-local
        return YES;
    }
    
    // fec0::/10
    prefix[0] = 0xfe;
    prefix[1] = 0xc0;
    if ([MDNSManager isAddress:addrBytes inSubnet:prefix netmask:10]) {
        // Site local
        return YES;
    }
    
    // fc00::/7
    prefix[0] = 0xfc;
    prefix[1] = 0x00;
    if ([MDNSManager isAddress:addrBytes inSubnet:prefix netmask:7]) {
        // ULA
        return YES;
    }
    
    return NO;
}

+ (NSString*)getBestIpv6Address:(NSArray<NSData*>*)addresses {
    for (NSData* addrData in addresses) {
        struct sockaddr_in6* sin6 = (struct sockaddr_in6*)[addrData bytes];
        if (sin6->sin6_family != AF_INET6) {
            continue;
        }
        
        if ([MDNSManager isLocalIpv6Address:addrData]) {
            // Skip non-global addresses
            continue;
        }
        
        uint8_t* addrBytes = sin6->sin6_addr.s6_addr;
        uint8_t prefix[2];
        
        // 2002::/16
        prefix[0] = 0x20;
        prefix[1] = 0x02;
        if ([MDNSManager isAddress:addrBytes inSubnet:prefix netmask:16]) {
            Log(LOG_I, @"Ignoring 6to4 address: %@", [MDNSManager sockAddrToString:addrData]);
            continue;
        }
        
        // 2001::/32
        prefix[0] = 0x20;
        prefix[1] = 0x01;
        if ([MDNSManager isAddress:addrBytes inSubnet:prefix netmask:32]) {
            Log(LOG_I, @"Ignoring Teredo address: %@", [MDNSManager sockAddrToString:addrData]);
            continue;
        }
        
        NSString *candidate = [MDNSManager sockAddrToString:addrData];
        struct in6_addr parsed;
        if (candidate.length == 0 || inet_pton(AF_INET6, candidate.UTF8String, &parsed) != 1) {
            Log(LOG_W, @"Ignoring invalid global IPv6 mDNS address: %@", candidate ?: @"(null)");
            continue;
        }
        return candidate;
    }
    
    return nil;
}

- (void)netServiceDidResolveAddress:(NSNetService *)service {
    NSString *serviceKey = [NSString stringWithFormat:@"%@|%@|%@", service.name ?: @"", service.type ?: @"", service.domain ?: @""];
    [failedResolveUntil removeObjectForKey:serviceKey];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray<NSData*>* addresses = [service addresses];
        
        for (NSData* addrData in addresses) {
            Log(LOG_I, @"Resolved address: %@ -> %@", [service hostName], [MDNSManager sockAddrToString: addrData]);
        }
        
        TemporaryHost* host = [[TemporaryHost alloc] init];
        
        // First, look for an IPv4 record for the local address
        for (NSData* addrData in addresses) {
            struct sockaddr_in* sin = (struct sockaddr_in*)[addrData bytes];
            if (sin->sin_family != AF_INET) {
                continue;
            }
            
            // Don't send a STUN request if we're connected to a VPN. We'll likely get the VPN
            // gateway's external address rather than the external address of the LAN.
            if (![Utils isActiveNetworkVPN]) {
                // Since we discovered this host over IPv4 mDNS, we know we're on the same network
                // as the PC and we can use our current WAN address as a likely candidate
                // for our PC's external address.
                struct in_addr wanAddr;
                int err = LiFindExternalAddressIP4("stun.moonlight-stream.org", 3478, &wanAddr.s_addr);
                if (err == 0) {
                    char addrStr[INET_ADDRSTRLEN];
                    inet_ntop(AF_INET, &wanAddr, addrStr, sizeof(addrStr));
                    host.externalAddress = [NSString stringWithFormat: @"%s", addrStr];
                    Log(LOG_I, @"External IPv4 address (STUN): %@ -> %@", [service hostName], host.externalAddress);
                }
                else {
                    Log(LOG_E, @"STUN failed to get WAN address: %d", err);
                }
            }
            
            host.localAddress = [MDNSManager sockAddrToString:addrData];
            Log(LOG_I, @"Local address chosen: %@ -> %@", [service hostName], host.localAddress);
            break;
        }
        
        if (host.localAddress == nil) {
            // If we didn't find an IPv4 record, look for a local IPv6 record
            for (NSData* addrData in addresses) {
                if ([MDNSManager isLocalIpv6Address:addrData]) {
                    host.localAddress = [MDNSManager sockAddrToString:addrData];
                    Log(LOG_I, @"Local address chosen: %@ -> %@", [service hostName], host.localAddress);
                    break;
                }
            }
        }
        
        host.ipv6Address = [MDNSManager getBestIpv6Address:addresses];
        host.address = service.port > 0 && service.hostName.length > 0
            ? [NSString stringWithFormat:@"%@:%ld", service.hostName, (long)service.port]
            : service.hostName;
        Log(LOG_I, @"IPv6 address chosen: %@ -> %@", [service hostName], host.ipv6Address);
        
        host.activeAddress = host.localAddress;
        host.name = service.hostName;
        [self.callback updateHost:host];
    });
}

- (void)netService:(NSNetService *)sender didNotResolve:(NSDictionary *)errorDict {
    Log(LOG_W, @"Did not resolve address for: %@\n%@", sender, [errorDict description]);

    // Keep the failed service cached. The browser may return a fresh
    // NSNetService instance on every search cycle; removing it here caused the
    // same unresolved service to be resolved again every five seconds.
    // Bonjour will call didRemoveService when it truly disappears.
    NSString *serviceKey = [NSString stringWithFormat:@"%@|%@|%@", sender.name ?: @"", sender.type ?: @"", sender.domain ?: @""];
    failedResolveUntil[serviceKey] = [NSDate dateWithTimeIntervalSinceNow:60.0];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)aNetServiceBrowser didFindService:(NSNetService *)aNetService moreComing:(BOOL)moreComing {
    Log(LOG_D, @"Found service: %@", aNetService);
    
    NSString *serviceKey = [NSString stringWithFormat:@"%@|%@|%@", aNetService.name ?: @"", aNetService.type ?: @"", aNetService.domain ?: @""];
    NSDate *cooldown = failedResolveUntil[serviceKey];
    if (cooldown != nil && [cooldown timeIntervalSinceNow] > 0) {
        return;
    }
    [failedResolveUntil removeObjectForKey:serviceKey];

    BOOL knownService = NO;
    for (NSNetService *known in services) {
        if ([known.name isEqualToString:aNetService.name] &&
            [known.type isEqualToString:aNetService.type] &&
            [known.domain isEqualToString:aNetService.domain]) {
            knownService = YES;
            break;
        }
    }
    if (!knownService) {
        Log(LOG_I, @"Found new host: %@", aNetService.name);
        [aNetService setDelegate:self];
        [aNetService resolveWithTimeout:5];
        [services addObject:aNetService];
    }
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)aNetServiceBrowser didRemoveService:(NSNetService *)aNetService moreComing:(BOOL)moreComing {
    Log(LOG_I, @"Removing service: %@", aNetService);
    [services removeObject:aNetService];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)aNetServiceBrowser didNotSearch:(NSDictionary *)errorDict {
    Log(LOG_W, @"Did not perform search: \n%@", [errorDict description]);
    
    // The next round of the schedule (runSearchRound) tries again.
}

// One round of the schedule: restart the browser unless a launch or stream owns the network, then wait for the next
// round. A stream or launch stops the browser (the stored computers keep being polled over HTTP) and the schedule
// begins again at five seconds once the app is quiet.
- (void)runSearchRound {
    searchTimer = nil;
    if (!searching) {
        return;
    }
    if ([MLNetworkQuiet isQuiet]) {
        [self stopBrowser];
        searchRound = 0;
    } else {
        Log(LOG_D, @"Restarting mDNS search (round %lu)", (unsigned long)searchRound);
        if (mDNSBrowser == nil) {
            mDNSBrowser = [self makeBrowser];
            [mDNSBrowser setDelegate:self];
        }
        [mDNSBrowser stop];
        [mDNSBrowser searchForServicesOfType:NV_SERVICE_TYPE inDomain:@""];
        browserStarted = YES;
    }

    NSTimeInterval interval = [self restartIntervalForRound:searchRound];
    if (searchRound < NSUIntegerMax) {
        searchRound++;
    }
    __weak MDNSManager *weakSelf = self;
    searchTimer = [NSTimer scheduledTimerWithTimeInterval:interval repeats:NO block:^(NSTimer *timer) {
        [weakSelf runSearchRound];
    }];
}

- (void)retryResolveTimerCallback:(NSTimer *)timer {
    // Kept for ABI/source compatibility with older callers. Failed services
    // are retried by the next browser search rather than by a timer storm.
}

@end
