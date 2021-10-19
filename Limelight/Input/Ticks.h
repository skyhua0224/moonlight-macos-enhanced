//
//  Ticks.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 19/7/21.
//  Copyright © 2021 Moonlight Game Streaming Project. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#define TICKS_PASSED(A, B) ((int32_t)((B) - (A)) <= 0)

@interface Ticks : NSObject
- (UInt32)getTicks;
@end

NS_ASSUME_NONNULL_END
