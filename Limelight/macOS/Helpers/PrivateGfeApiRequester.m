//
//  PrivateGfeApiRequester.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 29/12/2021.
//  Copyright © 2021 Moonlight Game Streaming Project. All rights reserved.
//

#import "PrivateGfeApiRequester.h"
#import "AppsViewController.h"
#import "OptimalSettingsConfigurer.h"

@implementation PrivateGfeApiRequester

+ (void)fetchPrivateAppsJSONForHostIP:(NSString *)hostIP WithCompletionBlock:(void (^)(NSArray<NSDictionary<NSString *, id> *> *))completion {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%@/Applications/v.1.0/", hostIP, @(CUSTOM_PRIVATE_GFE_PORT)]];
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSLog(@"PrivateGFE fetchPrivateAppsJSONForHostIP error: %@, statusCode: %@", error, @(httpResponse.statusCode));
        if (error == nil) {
            if (httpResponse.statusCode / 100 == 2) {
                completion([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]);
            }
        }
    }];
    [task resume];
}

+ (void)resetSettingsForPrivateApp:(NSString *)appId hostIP:(NSString *)hostIP {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%@/Applications/v.1.0/%@/targetACPosition", hostIP, @(CUSTOM_PRIVATE_GFE_PORT), appId]];
    
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url];
    request.HTTPMethod = @"POST";
    NSDictionary<NSString *, id> *body = @{};
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSLog(@"PrivateGFE resetSettingsForPrivateApp error: %@, statusCode: %@", error, @(httpResponse.statusCode));
    }];
    [task resume];
}

+ (void)getSettingsJSONForApp:(NSString *)appId hostIP:(NSString *)hostIP resolutionWidth:(int)width height:(int)height withCompletionBlock:(void (^)(NSDictionary *))completion {
    NSDictionary<NSString *, NSString *> *requestDictionary = @{
        @"resolution": [NSString stringWithFormat:@"%@x%@", @(width), @(height)],
        @"displayMode": @"Full-screen",
    };
    NSString *requestJSON = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:requestDictionary options:0 error:nil] encoding:NSUTF8StringEncoding];
    NSString *request = [requestJSON stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLHostAllowedCharacterSet]];
    
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%@/Applications/v.1.0/%@/settingsSpace/%@", hostIP, @(CUSTOM_PRIVATE_GFE_PORT), appId, request]];
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSLog(@"PrivateGFE getSettingsJSONForApp error: %@, statusCode: %@", error, @(httpResponse.statusCode));
        if (error == nil) {
            if (httpResponse.statusCode / 100 == 2) {
                completion([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]);
            }
        }
    }];
    [task resume];
}

+ (void)getRecommendedSettingsIndexForApp:(NSString *)appId hostIP:(NSString *)hostIP withCompletionBlock:(void (^)(int, BOOL))completion {
    [self requestStateOfApp:appId hostIP:hostIP withCompletionBlock:^(NSDictionary<NSString *,id> *stateJSON) {
        int index = ((NSNumber *)stateJSON[@"REGULAR"][@"recommendationAC"][@"recommendedIndex"]).intValue;
        
        completion(index, YES);
        return;
    }];
}

+ (void)requestOptimalResolutionWithWidth:(int)width andHeight:(int)height hostIP:(NSString *)hostIP forPrivateApp:(NSString *)appId withCompletionBlock:(void (^)(void))completion {
    [PrivateGfeApiRequester getRecommendedSettingsIndexForApp:appId hostIP:hostIP withCompletionBlock:^(int index, BOOL success) {
        if (!success) {
            completion();
            return;
        }
        
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%@/Applications/v.1.0/%@/targetACPosition", hostIP, @(CUSTOM_PRIVATE_GFE_PORT), appId]];

        NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url];
        request.HTTPMethod = @"POST";
        
        NSDictionary *appSettings = [OptimalSettingsConfigurer getSavedOptimalSettingsForApp:appId withInitialSettingsIndex:index andIntialDisplayMode:@"Full-screen"];
        NSString *displayMode = appSettings[@"displayMode"];
        int savedIndex = ((NSNumber *)appSettings[@"settingsIndex"]).intValue;

        NSDictionary<NSString *, id> *body = @{
            @"tweak": @{
                @"resolution": [NSString stringWithFormat:@"%@x%@", @(width), @(height)],
                @"displayMode": displayMode,
            },
            @"settingsIndex": @(savedIndex),
        };
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

        NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            NSLog(@"PrivateGFE requestOptimalResolutionForPrivateApp error: %@, statusCode: %@", error, @(httpResponse.statusCode));
            completion();
        }];
        [task resume];
    }];
}

+ (void)requestLaunchOfPrivateApp:(NSString *)appId hostIP:(NSString *)hostIP {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%@/Applications/v.1.0/%@/launch", hostIP, @(CUSTOM_PRIVATE_GFE_PORT), appId]];
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url];
    request.HTTPMethod = @"POST";
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSLog(@"PrivateGFE requestLaunchOfPrivateApp error: %@, statusCode: %@", error, @(httpResponse.statusCode));
    }];
    [task resume];
}

+ (void)requestStateOfApp:(NSString *)appId hostIP:(NSString *)hostIP withCompletionBlock:(void (^)(NSDictionary<NSString *, id> *))completion {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%@/Applications/v.1.0/%@/state", hostIP, @(CUSTOM_PRIVATE_GFE_PORT), appId]];
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSLog(@"PrivateGFE requestStateOfApp error: %@, statusCode: %@", error, @(httpResponse.statusCode));
        if (error == nil) {
            if (httpResponse.statusCode / 100 == 2) {
                completion([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]);
            }
        }
    }];
    [task resume];
}

@end
