//
//  LatencyProbe.m
//  Moonlight for macOS
//
//  Created by GitHub Copilot on 2026/01/16.
//

#import "LatencyProbe.h"
#import "Utils.h"

@implementation LatencyProbe

+ (NSNumber * _Nullable)icmpPingMsForAddress:(NSString *)address {
    if (![address isKindOfClass:[NSString class]] || address.length == 0) {
        return nil;
    }

    NSString *host = nil;
    NSString *port = nil;
    [Utils parseAddress:address intoHost:&host andPort:&port];
    if (host.length == 0) {
        return nil;
    }

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/sbin/ping";
    task.arguments = @[ @"-c", @"1", @"-W", @"1000", host ];

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;

    @try {
        [task launch];
    } @catch (NSException *exception) {
        return nil;
    }

    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];

    if (data.length == 0 || task.terminationStatus != 0) {
        return nil;
    }

    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (output.length == 0) {
        return nil;
    }

    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"time=([0-9.]+)\\s*ms" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:output options:0 range:NSMakeRange(0, output.length)];
    if (!match || match.numberOfRanges < 2) {
        return nil;
    }

    NSString *value = [output substringWithRange:[match rangeAtIndex:1]];
    double ms = [value doubleValue];
    if (ms <= 0) {
        return nil;
    }

    return @( (int)llround(ms) );
}

@end
