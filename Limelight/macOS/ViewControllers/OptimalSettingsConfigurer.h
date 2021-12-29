//
//  OptimalSettingsConfigurer.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 28/12/2021.
//  Copyright © 2021 Moonlight Game Streaming Project. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "TemporaryApp.h"

@interface OptimalSettingsConfigurer : NSViewController
- (instancetype)initWithApp:(TemporaryApp *)app andPrivateId:(NSString *)appId;
+ (NSDictionary *)getSavedOptimalSettingsForApp:(NSString *)appId withInitialSettingsIndex:(int)index andIntialDisplayMode:(NSString *)displayMode;
@end
