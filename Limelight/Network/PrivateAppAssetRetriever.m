//
//  PrivateAppAssetRetriever.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 22/12/2021.
//  Copyright © 2021 Moonlight Game Streaming Project. All rights reserved.
//

#import "PrivateAppAssetRetriever.h"
#import "HttpManager.h"
#import "CryptoManager.h"
#import "AppAssetResponse.h"
#import "HttpRequest.h"
#import "IdManager.h"

#import "F.h"

@implementation PrivateAppAssetRetriever

- (void)getAppBoxArtUrlFromAppId:(NSString *)appId withCompletionBlock:(void (^)(NSURL *))completion {
    NSURL *detailsUrl = [NSURL URLWithString:[NSString stringWithFormat:@"https://static.nvidiagrid.net/apps/%@/US/%@_US.json", appId, appId]];
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithURL:detailsUrl completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (error == nil) {
            if (httpResponse.statusCode == 200) {
                NSDictionary<NSString *, id> *responseObject = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSArray<NSDictionary<NSString *, id> *> *assets = responseObject[@"assets"];
                [F eachInArray:assets withBlock:^(NSDictionary<NSString *, id> *obj) {
                    NSString *name = obj[@"name"];
                    if ([name hasPrefix:@"GAME_BOX_ART"]) {
                        completion([NSURL URLWithString:obj[@"url"]]);
                        return;
                    }
                }];
            }
        }
    }];
    [task resume];
}

- (void)main {
    [self getAppBoxArtUrlFromAppId:self.app.id withCompletionBlock:^(NSURL *url) {
        NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            if (error == nil) {
                if (data != nil) {
                    NSString* boxArtPath = [AppAssetManager boxArtPathForApp:self.app];
                    [[NSFileManager defaultManager] createDirectoryAtPath:[boxArtPath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
                    [data writeToFile:boxArtPath atomically:NO];

                    [self.callback receivedPrivateAssetForApp:self.app];
                }
            }
        }];
        [task resume];
    }];
}

@end
