//
//  Utils.m
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "Utils.h"

#include <arpa/inet.h>
#include <netdb.h>
#include <net/if.h>
#include <netinet/in.h>
#include <ifaddrs.h>
#include <sys/socket.h>
#include <string.h>
#include <unistd.h>

static BOOL isDecimalPort(NSString *port) {
    if (port.length == 0 || port.length > 5) {
        return NO;
    }
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    return [port rangeOfCharacterFromSet:[digits invertedSet]].location == NSNotFound;
}

static BOOL isValidIPv6Literal(NSString *addr) {
    if (addr.length == 0) {
        return NO;
    }
    struct in6_addr sa6;
    return inet_pton(AF_INET6, addr.UTF8String, &sa6) == 1;
}

static BOOL interfaceNameLooksLikeTunnel(NSString *ifname) {
    NSString *name = ifname.lowercaseString;
    if (name.length == 0) {
        return NO;
    }

    // Common tunnel interfaces:
    // - utun*: NetworkExtension/PacketTunnel (WireGuard, Tailscale, etc.)
    // - tun*/tap*: classic VPN/tunnel adapters
    // - ppp*/ipsec*: legacy VPN stacks
    // - wg*: explicit WireGuard interfaces on some systems
    return [name containsString:@"utun"] ||
           [name containsString:@"wireguard"] ||
           [name hasPrefix:@"wg"] ||
           [name containsString:@"tap"] ||
           [name containsString:@"tun"] ||
           [name containsString:@"ppp"] ||
           [name containsString:@"ipsec"];
}

static BOOL isSockaddrIpEqual(const struct sockaddr *left, const struct sockaddr *right) {
    if (left == NULL || right == NULL || left->sa_family != right->sa_family) {
        return NO;
    }

    if (left->sa_family == AF_INET) {
        const struct sockaddr_in *l = (const struct sockaddr_in *)left;
        const struct sockaddr_in *r = (const struct sockaddr_in *)right;
        return l->sin_addr.s_addr == r->sin_addr.s_addr;
    }

    if (left->sa_family == AF_INET6) {
        const struct sockaddr_in6 *l = (const struct sockaddr_in6 *)left;
        const struct sockaddr_in6 *r = (const struct sockaddr_in6 *)right;
        return memcmp(&l->sin6_addr, &r->sin6_addr, sizeof(struct in6_addr)) == 0;
    }

    return NO;
}

static NSString *ipStringFromSockaddr(const struct sockaddr *address) {
    if (address == NULL) {
        return nil;
    }

    char ipBuffer[INET6_ADDRSTRLEN] = {0};
    if (address->sa_family == AF_INET) {
        const struct sockaddr_in *in = (const struct sockaddr_in *)address;
        if (inet_ntop(AF_INET, &in->sin_addr, ipBuffer, sizeof(ipBuffer)) != NULL) {
            return [NSString stringWithUTF8String:ipBuffer];
        }
    } else if (address->sa_family == AF_INET6) {
        const struct sockaddr_in6 *in6 = (const struct sockaddr_in6 *)address;
        if (inet_ntop(AF_INET6, &in6->sin6_addr, ipBuffer, sizeof(ipBuffer)) != NULL) {
            return [NSString stringWithUTF8String:ipBuffer];
        }
    }

    return nil;
}

static NSString *interfaceNameForLocalSockaddr(const struct sockaddr *localAddress) {
    if (localAddress == NULL) {
        return nil;
    }

    struct ifaddrs *ifaddr = NULL;
    if (getifaddrs(&ifaddr) != 0 || ifaddr == NULL) {
        return nil;
    }

    NSString *iface = nil;
    for (struct ifaddrs *ifa = ifaddr; ifa != NULL; ifa = ifa->ifa_next) {
        if (ifa->ifa_addr == NULL || ifa->ifa_name == NULL) {
            continue;
        }
        if (!(ifa->ifa_flags & IFF_UP)) {
            continue;
        }
        if (isSockaddrIpEqual(ifa->ifa_addr, localAddress)) {
            iface = [NSString stringWithUTF8String:ifa->ifa_name];
            break;
        }
    }

    freeifaddrs(ifaddr);
    return iface;
}

static NSString *outboundInterfaceNameForHost(NSString *host, NSString *port, NSString **sourceAddress) {
    if (sourceAddress) {
        *sourceAddress = nil;
    }
    if (host.length == 0) {
        return nil;
    }

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
    hints.ai_protocol = IPPROTO_UDP;

    struct addrinfo *result = NULL;
    int gaiErr = getaddrinfo(host.UTF8String, port.UTF8String, &hints, &result);
    if (gaiErr != 0 || result == NULL) {
        return nil;
    }

    NSString *iface = nil;
    NSString *src = nil;

    for (struct addrinfo *rp = result; rp != NULL; rp = rp->ai_next) {
        int fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (fd < 0) {
            continue;
        }

        if (connect(fd, rp->ai_addr, (socklen_t)rp->ai_addrlen) == 0) {
            struct sockaddr_storage localStorage;
            memset(&localStorage, 0, sizeof(localStorage));
            socklen_t localLen = sizeof(localStorage);
            if (getsockname(fd, (struct sockaddr *)&localStorage, &localLen) == 0) {
                src = ipStringFromSockaddr((const struct sockaddr *)&localStorage);
                iface = interfaceNameForLocalSockaddr((const struct sockaddr *)&localStorage);
            }
        }

        close(fd);

        if (iface.length > 0) {
            break;
        }
    }

    freeaddrinfo(result);

    if (sourceAddress) {
        *sourceAddress = src;
    }
    return iface;
}

@implementation Utils
NSString *const deviceName = @"roth";

+ (NSData*) randomBytes:(NSInteger)length {
    char* bytes = malloc(length);
    arc4random_buf(bytes, length);
    NSData* randomData = [NSData dataWithBytes:bytes length:length];
    free(bytes);
    return randomData;
}

+ (NSData*) hexToBytes:(NSString*) hex {
    unsigned long len = [hex length];
    NSMutableData* data = [NSMutableData dataWithCapacity:len / 2];
    char byteChars[3] = {'\0','\0','\0'};
    unsigned long wholeByte;
    
    const char *chars = [hex UTF8String];
    int i = 0;
    while (i < len) {
        byteChars[0] = chars[i++];
        byteChars[1] = chars[i++];
        wholeByte = strtoul(byteChars, NULL, 16);
        [data appendBytes:&wholeByte length:1];
    }
    
    return data;
}

+ (NSString*) bytesToHex:(NSData*)data {
    const unsigned char* bytes = [data bytes];
    NSMutableString *hex = [[NSMutableString alloc] init];
    for (int i = 0; i < [data length]; i++) {
        [hex appendFormat:@"%02X" , bytes[i]];
    }
    return hex;
}

+ (void) parseAddress:(NSString*)address intoHost:(NSString**)host andPort:(NSString**)port {
    NSString* hostStr = address;
    NSString* portStr = nil;
    
    if ([address hasPrefix:@"["] && [address containsString:@"]"]) {
        // IPv6 enclosed in brackets
        NSRange closingBracket = [address rangeOfString:@"]"];
        if (closingBracket.location != NSNotFound && closingBracket.location < address.length - 1) {
            NSString* suffix = [address substringFromIndex:closingBracket.location + 1];
            if ([suffix hasPrefix:@":"]) {
                hostStr = [address substringWithRange:NSMakeRange(1, closingBracket.location - 1)];
                portStr = [suffix substringFromIndex:1];
            } else {
                 hostStr = [address substringWithRange:NSMakeRange(1, closingBracket.location - 1)];
            }
        } else if (closingBracket.location != NSNotFound) {
             hostStr = [address substringWithRange:NSMakeRange(1, closingBracket.location - 1)];
        }
    } else if ([address containsString:@":"]) {
        // Determine if this is IPv6 literal or Host/IPv4 + port.
        // For bare IPv6 with a custom port (legacy stored format like "2001:db8::1:57989"),
        // parse the final segment as the port only if the full address is NOT valid IPv6.
        NSArray* components = [address componentsSeparatedByString:@":"];
        if (components.count == 2) {
            hostStr = components[0];
            portStr = components[1];
        } else if (!isValidIPv6Literal(address)) {
            NSRange lastColon = [address rangeOfString:@":" options:NSBackwardsSearch];
            if (lastColon.location != NSNotFound && lastColon.location < address.length - 1) {
                NSString *candidateHost = [address substringToIndex:lastColon.location];
                NSString *candidatePort = [address substringFromIndex:lastColon.location + 1];
                if (isDecimalPort(candidatePort) && isValidIPv6Literal(candidateHost)) {
                    hostStr = candidateHost;
                    portStr = candidatePort;
                }
            }
        }
    }
    
    if (host) *host = hostStr;
    if (port) *port = portStr;
}

+ (BOOL)isActiveNetworkVPN {
    NSDictionary *dict = CFBridgingRelease(CFNetworkCopySystemProxySettings());
    NSArray *keys = [dict[@"__SCOPED__"] allKeys];
    for (NSString *key in keys) {
        if ([self isTunnelInterfaceName:key]) {
            return YES;
        }
    }
    return NO;
}

+ (BOOL)isTunnelInterfaceName:(NSString *)ifname {
    return interfaceNameLooksLikeTunnel(ifname);
}

+ (nullable NSString *)outboundInterfaceNameForAddress:(NSString *)address
                                         sourceAddress:(NSString * _Nullable * _Nullable)sourceAddress {
    if (sourceAddress) {
        *sourceAddress = nil;
    }
    if (address.length == 0) {
        return nil;
    }

    NSString *host = nil;
    NSString *port = nil;
    [self parseAddress:address intoHost:&host andPort:&port];
    if (host.length == 0) {
        host = address;
    }

    // This helper is called from stream-window setup on the main thread.
    // Resolving a Bonjour/WireGuard hostname synchronously can block the UI
    // for several seconds. Route classification is only advisory, so return
    // unknown for hostnames and let the actual connection perform resolution.
    struct in_addr ipv4;
    struct in6_addr ipv6;
    BOOL numericAddress = [host cStringUsingEncoding:NSASCIIStringEncoding] != NULL &&
        (inet_pton(AF_INET, host.UTF8String, &ipv4) == 1 ||
         inet_pton(AF_INET6, host.UTF8String, &ipv6) == 1);
    if (!numericAddress) {
        return nil;
    }

    NSString *probePort = @"47984";
    if (isDecimalPort(port)) {
        NSInteger parsedPort = [port integerValue];
        if (parsedPort > 0 && parsedPort <= 65535) {
            probePort = port;
        }
    }

    return outboundInterfaceNameForHost(host, probePort, sourceAddress);
}

#if TARGET_OS_IPHONE
+ (void) addHelpOptionToDialog:(UIAlertController*)dialog {
#if !TARGET_OS_TV
    // tvOS doesn't have a browser
    [dialog addAction:[UIAlertAction actionWithTitle:@"Help" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/moonlight-stream/moonlight-docs/wiki/Troubleshooting"]];
    }]];
#endif
}
#endif

@end

@implementation NSString (NSStringWithTrim)

- (NSString *)trim {
    return [self stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

@end
