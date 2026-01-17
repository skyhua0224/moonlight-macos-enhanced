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

@end

NS_ASSUME_NONNULL_END
