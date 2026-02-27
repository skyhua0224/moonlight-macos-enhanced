//
//  Utils.m
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "Utils.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netdb.h>

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
        if ([key containsString:@"tap"] ||
            [key containsString:@"tun"] ||
            [key containsString:@"ppp"] ||
            [key containsString:@"ipsec"]) {
            return YES;
        }
    }
    return NO;
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
