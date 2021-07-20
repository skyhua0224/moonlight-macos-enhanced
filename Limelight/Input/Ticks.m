//
//  Ticks.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 19/7/21.
//  Copyright © 2021 Moonlight Game Streaming Project. All rights reserved.
//

#import "Ticks.h"
#include <sys/time.h>

mach_timebase_info_data_t machBaseInfo;
static struct timeval startTV;

@interface Ticks ()
@property (atomic) uint64_t startMach;
@property (nonatomic) BOOL hasMonotonicTime;
@end

@implementation Ticks

- (instancetype)init
{
    self = [super init];
    if (self) {
        kern_return_t ret = mach_timebase_info(&machBaseInfo);
        if (ret == 0) {
            self.hasMonotonicTime = YES;
            self.startMach = mach_absolute_time();
        } else {
            gettimeofday(&startTV, NULL);
        }
    }
    return self;
}

- (UInt32)getTicks {
    UInt32 ticks;
    
    if (self.hasMonotonicTime) {
        uint64_t now = mach_absolute_time();
        ticks = (UInt32)((((now - self.startMach) * machBaseInfo.numer) / machBaseInfo.denom) / 1000000);
    } else {
        struct timeval now;

        gettimeofday(&now, NULL);
        ticks = (UInt32)((now.tv_sec - startTV.tv_sec) * 1000 + (now.tv_usec - startTV.tv_usec) / 1000);
    }
    
    return ticks;
}

@end
