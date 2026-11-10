//
//  LatencyProbe.h
//  Moonlight for macOS
//
//  Created by GitHub SkyHua on 2026/01/16.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LatencyProbe : NSObject

+ (NSNumber * _Nullable)icmpPingMsForAddress:(NSString *)address;

/// The latency of an address in the sense a user means it: the application-layer round trip (HostPathRank.h,
/// host_app_rtt_measure) on an open connection, in milliseconds; nil when it could not be measured. Never the time of a whole
/// /serverinfo request, never a TCP connect time. Remembered for 15 s per address. `probeTotalMs` is the old figure (the whole
/// serverinfo request), given only so the log shows both: `[latency] <address> probe total X ms / app RTT Y ms`.
+ (NSNumber * _Nullable)appRttMsForAddress:(NSString *)address probeTotalMs:(int)probeTotalMs;

/// The round trip Moonlight measured during a real stream (the control stream's estimated RTT), per computer and address.
/// Samples arrive about once a second; the median of the recent ones is kept and saved.
+ (void)noteStreamRttMs:(uint32_t)rttMs forHost:(NSString *)uuid address:(NSString *)address;
/// A new stream starts: its samples are not mixed with those of the previous one.
+ (void)resetStreamRttWindowForHost:(NSString *)uuid address:(NSString *)address;
/// @{@"ms": NSNumber, @"when": NSDate} of the last stream on that address, nil if none.
+ (NSDictionary * _Nullable)lastStreamRttForHost:(NSString *)uuid address:(NSString *)address;

@end

/// What happened to the streams that ran over each address of a computer (HostPathRank.h: the "health of the path" rules).
@interface StreamPathHealth : NSObject
/// reason: @"loss" or @"control"; detail: a short text such as "73%" or "error 4".
+ (void)recordFailureForHost:(NSString *)uuid address:(NSString *)address reason:(NSString *)reason detail:(NSString *)detail;
+ (void)recordSuccessForHost:(NSString *)uuid address:(NSString *)address;
/// YES when the newest word on this address is a failure younger than 30 minutes.
+ (BOOL)shouldAvoidHost:(NSString *)uuid address:(NSString *)address;
/// @{@"reason", @"detail", @"when": NSDate} of that failure, nil when the address is not in disgrace.
+ (NSDictionary * _Nullable)recentFailureForHost:(NSString *)uuid address:(NSString *)address;
/// Failed streams in a row on this computer (any address); a good stream or a manual route change resets it.
+ (NSInteger)consecutiveFailuresForHost:(NSString *)uuid;
+ (void)resetConsecutiveForHost:(NSString *)uuid;
@end

NS_ASSUME_NONNULL_END
