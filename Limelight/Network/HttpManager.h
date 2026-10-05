//
//  HttpManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/16/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "HttpResponse.h"
#import "HttpRequest.h"
#import "StreamConfiguration.h"

@interface HttpManager : NSObject <NSURLSessionDelegate>

typedef void (^MLHttpDataCompletion)(NSData * _Nullable data,
                                     NSHTTPURLResponse * _Nullable response,
                                     NSError * _Nullable error);

- (id) initWithHost:(NSString*) host uniqueId:(NSString*) uniqueId serverCert:(NSData*) serverCert;
- (void) setServerCert:(NSData*) serverCert;
- (NSURLRequest*) newPairRequest:(NSData*)salt clientCert:(NSData*)clientCert;
- (NSURLRequest*) newUnpairRequest;
- (NSURLRequest*) newChallengeRequest:(NSData*)challenge;
- (NSURLRequest*) newChallengeRespRequest:(NSData*)challengeResp;
- (NSURLRequest*) newClientSecretRespRequest:(NSString*)clientPairSecret;
- (NSURLRequest*) newPairChallenge;
- (NSURLRequest*) newAppListRequest;
- (NSURLRequest*) newServerInfoRequest:(bool)fastFail;
- (NSURLRequest*) newHttpServerInfoRequest:(bool)fastFail;
- (NSURLRequest*) newHttpServerInfoRequest;
- (NSURLRequest*) newLaunchRequest:(StreamConfiguration*)config;
- (NSURLRequest*) newResumeRequest:(StreamConfiguration*)config;
- (NSURLRequest*) newDisplaysRequest;
- (NSURLRequest*) newQuitAppRequest;
- (NSURLRequest*) newAppAssetRequestWithAppId:(NSString*)appId;
- (NSArray<NSDictionary<NSString*, id>*>*) fetchSunshineDisplays;
- (NSDictionary<NSString*, id>*) fetchSunshineDisplaySnapshot;
- (NSDictionary<NSString*, id>*) fetchSunshineUSBForwardingCapability;
- (NSDictionary<NSString*, id>*) fetchSunshineFileMappingCapability;
- (void) executeRequestSynchronously:(HttpRequest*)request;
- (NSURLRequest *)newClipboardRequestWithPath:(NSString *)path;
- (void)executeDataRequest:(NSURLRequest *)request completion:(MLHttpDataCompletion)completion;

@end
