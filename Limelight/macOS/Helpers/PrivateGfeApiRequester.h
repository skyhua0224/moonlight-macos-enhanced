//
//  PrivateGfeApiRequester.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 29/12/2021.
//  Copyright © 2021 Moonlight Game Streaming Project. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface PrivateGfeApiRequester : NSObject

+ (void)fetchPrivateAppsJSONForHostIP:(NSString *)hostIP WithCompletionBlock:(void (^)(NSArray<NSDictionary<NSString *, id> *> *))completion;
+ (void)resetSettingsForPrivateApp:(NSString *)appId hostIP:(NSString *)hostIP;

+ (void)getRecommendedSettingsIndexForApp:(NSString *)appId hostIP:(NSString *)hostIP withCompletionBlock:(void (^)(int, BOOL))completion;
+ (void)requestOptimalResolutionWithWidth:(int)width andHeight:(int)height hostIP:(NSString *)hostIP forPrivateApp:(NSString *)appId withCompletionBlock:(void (^)(void))completion;
+ (void)requestLaunchOfPrivateApp:(NSString *)appId hostIP:(NSString *)hostIP;

+ (void)requestStateOfApp:(NSString *)appId hostIP:(NSString *)hostIP withCompletionBlock:(void (^)(NSDictionary<NSString *, id> *))completion;

@end
