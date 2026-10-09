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
- (NSURLRequest*) newSuperCommandRequestWithId:(NSString*)commandId;
- (NSURLRequest*) newPcSleepRequest;
// Synchronous conveniences over the two requests above; do not call on the main thread.
- (BOOL) executeSuperCommandWithId:(NSString*)commandId;
- (BOOL) requestHostSleep;
- (NSURLRequest*) newAppAssetRequestWithAppId:(NSString*)appId;
- (NSArray<NSDictionary<NSString*, id>*>*) fetchSunshineDisplays;
- (NSDictionary<NSString*, id>*) fetchSunshineDisplaySnapshot;
- (NSDictionary<NSString*, id>*) fetchSunshineUSBForwardingCapability;
- (NSDictionary<NSString*, id>*) fetchSunshineFileMappingCapability;
- (void) executeRequestSynchronously:(HttpRequest*)request;
- (NSURLRequest *)newClipboardRequestWithPath:(NSString *)path;
// Foundation Sunshine JSON API (/api/abr/*) over a persistent mTLS session so a 1 Hz
// feedback loop does not repeat the handshake. Synchronous; do not call on the main
// thread. Returns the parsed JSON object (empty on failure) and the HTTP status, or a
// negative NSURLError code on transport failure.
- (NSDictionary<NSString*, id>*) sunshineAPIRequestWithPath:(NSString*)path
                                                     method:(NSString*)method
                                                       body:(NSDictionary<NSString*, id>*)body
                                                    timeout:(NSTimeInterval)timeout
                                                 httpStatus:(NSInteger*)httpStatus;
- (void) invalidateSunshineAPISession;
// Foundation Sunshine pre-stream bandwidth probe (/api/network/*). Synchronous.
// Keys: ok, error (reason), retryAfterMs, bandwidthMbps, latencyMs, jitterMs, bytes,
// partial (host cut the transfer short; bandwidth is then a lower bound).
- (NSDictionary<NSString*, id>*) runSunshineBandwidthProbe;
- (void)executeDataRequest:(NSURLRequest *)request completion:(MLHttpDataCompletion)completion;

@end
