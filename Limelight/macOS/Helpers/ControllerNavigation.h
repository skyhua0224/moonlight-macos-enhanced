//
//  ControllerNavigation.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 13/1/2022.
//  Copyright © 2022 Moonlight Game Streaming Project. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ControllerNavigation : NSObject
#ifdef MLC_CONCEPT_HARNESS
/// Where the scripted pad's focus is (harness logs).
+ (NSString *)harnessState;
+ (NSString *)harnessFocusedKey;
+ (NSString *)harnessTargets;
#endif
@end

NS_ASSUME_NONNULL_END
