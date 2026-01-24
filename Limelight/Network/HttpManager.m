//
//  HttpManager.m
//  Moonlight
//
//  Created by Diego Waxemberg on 10/16/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "HttpManager.h"
#import "HttpRequest.h"
#import "CryptoManager.h"
#import "TemporaryApp.h"
#import "Moonlight-Swift.h"

#include <libxml2/libxml/xmlreader.h>
#include <string.h>

#include <Limelight.h>

#define SHORT_TIMEOUT_SEC 2
#define NORMAL_TIMEOUT_SEC 5
#define LONG_TIMEOUT_SEC 60
#define EXTRA_LONG_TIMEOUT_SEC 180

@implementation HttpManager {
    NSString* _baseHTTPURL;
    NSString* _baseHTTPSURL;
    NSString* _uniqueId;
    NSString* _deviceName;
    NSData* _serverCert;
    
    NSError* _error;
}

static uint64_t gLastServerInfoErrorLogMs = 0;
static int gSuppressedServerInfoErrorLogs = 0;

static BOOL IsServerInfoRequest(NSURL *url) {
    if (!url) {
        return NO;
    }
    NSString *abs = url.absoluteString.lowercaseString;
    return [abs containsString:@"/serverinfo"];
}

static void LogServerInfoFallbackError(NSInteger code, NSURL *url) {
    uint64_t nowMs = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0);
    if (nowMs - gLastServerInfoErrorLogMs < 1000) {
        gSuppressedServerInfoErrorLogs++;
        return;
    }

    if (gSuppressedServerInfoErrorLogs > 0) {
        Log(LOG_W, @"Request failed with error %ld, attempting fallback (suppressed %d repeats in last 1.0s)", (long)code, gSuppressedServerInfoErrorLogs);
        gSuppressedServerInfoErrorLogs = 0;
    } else {
        Log(LOG_W, @"Request failed with error %ld, attempting fallback", (long)code);
    }
    gLastServerInfoErrorLogMs = nowMs;
}

static const NSString* HTTP_PORT = @"47989";
static const NSString* HTTPS_PORT = @"47984";

+ (NSData*) fixXmlVersion:(NSData*) xmlData {
    NSString* dataString = [[NSString alloc] initWithData:xmlData encoding:NSUTF8StringEncoding];
    NSString* xmlString = [dataString stringByReplacingOccurrencesOfString:@"UTF-16" withString:@"UTF-8" options:NSCaseInsensitiveSearch range:NSMakeRange(0, [dataString length])];
    
    return [xmlString dataUsingEncoding:NSUTF8StringEncoding];
}

- (void) setServerCert:(NSData*) serverCert {
    _serverCert = serverCert;
}

- (id) initWithHost:(NSString*) host uniqueId:(NSString*) uniqueId serverCert:(NSData*) serverCert {
    self = [super init];
    // Use the same UID for all Moonlight clients to allow them
    // quit games started on another Moonlight client.
    _uniqueId = @"0123456789ABCDEF";
    _deviceName = deviceName;
    _serverCert = serverCert;
    
    NSString* hostAddress;
    NSString* customPort;
    
    [Utils parseAddress:host intoHost:&hostAddress andPort:&customPort];
    
    NSString* httpPort = (NSString*)HTTP_PORT;
    NSString* httpsPort = (NSString*)HTTPS_PORT;
    
    if (customPort != nil) {
        // When a custom port is specified, we assume it's the HTTP port
        // because that's what we use for initial discovery/pairing.
        // We derive the HTTPS port by subtracting 5 (standard offset).
        httpPort = customPort;
        httpsPort = [NSString stringWithFormat:@"%d", [customPort intValue] - 5];
    }

    // If this is an IPv6 literal, we must properly enclose it in brackets
    NSString* urlSafeHost;
    if ([hostAddress containsString:@":"]) {
        urlSafeHost = [NSString stringWithFormat:@"[%@]", hostAddress];
    } else {
        urlSafeHost = hostAddress;
    }
    
    _baseHTTPURL = [NSString stringWithFormat:@"http://%@:%@", urlSafeHost, httpPort];
    _baseHTTPSURL = [NSString stringWithFormat:@"https://%@:%@", urlSafeHost, httpsPort];

    return self;
}

- (void) executeRequestSynchronously:(HttpRequest*)request {
    NSURLSessionConfiguration* config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession* urlSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];

    __block NSMutableData* respData = [[NSMutableData alloc] init];
    __block NSError* requestError = nil;
    __block NSData* requestResp = nil;
    dispatch_semaphore_t requestLock = dispatch_semaphore_create(0);
    
    Log(LOG_D, @"Making Request: %@", request);
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask* task = [urlSession dataTaskWithRequest:request.request completionHandler:^(NSData * __nullable data, NSURLResponse * __nullable response, NSError * __nullable error) {
        
        assert(weakSelf != nil);
        typeof(self) strongSelf = weakSelf;
        
        if (error != NULL) {
            Log(LOG_D, @"Connection error: %@", error);
            requestError = error;
        }
        else {
            Log(LOG_D, @"Received response: %@", response);

            if (data != NULL) {
                Log(LOG_D, @"\n\nReceived data: %@\n\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
                [respData appendData:data];
                if ([[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding] != nil) {
                    requestResp = [HttpManager fixXmlVersion:respData];
                } else {
                    requestResp = respData;
                }
            }
        }
        
        (void)strongSelf; // Keep strongSelf alive during callback
        dispatch_semaphore_signal(requestLock);
    }];
    [task resume];

    // Bound the synchronous wait. We've seen cases where the completion handler
    // never runs (e.g., during teardown or certain TLS failure modes), which
    // would otherwise deadlock the calling thread indefinitely.
    NSTimeInterval timeout = request.request.timeoutInterval;
    if (timeout <= 0) {
        timeout = NORMAL_TIMEOUT_SEC;
    }
    dispatch_time_t waitTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 2.0) * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(requestLock, waitTime) != 0) {
        Log(LOG_E, @"Request timed out waiting for completion handler: %@", request.request.URL);
        [urlSession invalidateAndCancel];
        requestError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil];
    } else {
        [urlSession finishTasksAndInvalidate];
    }

    _error = requestError;

    if (!_error && request.response) {
        [request.response populateWithData:requestResp];
        
        // If the fallback error code was detected, issue the fallback request
        if (request.response.statusCode == request.fallbackError && request.fallbackRequest != NULL) {
            Log(LOG_D, @"Request failed with fallback error code: %d", request.fallbackError);
            request.request = request.fallbackRequest;
            request.fallbackError = 0;
            request.fallbackRequest = NULL;
            [self executeRequestSynchronously:request];
        }
    }
    else if (_error && request.fallbackRequest) {
        // Fallback on any error if fallback is present (e.g. HTTP fallback for HTTPS discovery)
        // This handles cases like certificate mismatches (-1202) or other TLS errors
        if (IsServerInfoRequest(request.request.URL)) {
            LogServerInfoFallbackError([_error code], request.request.URL);
        } else {
            Log(LOG_W, @"Request failed with error %ld, attempting fallback", (long)[_error code]);
        }
        request.request = request.fallbackRequest;
        request.fallbackError = 0;
        request.fallbackRequest = NULL;
        [self executeRequestSynchronously:request];
    }
    else if (_error && request.response) {
        request.response.statusCode = [_error code];
        request.response.statusMessage = [_error localizedDescription];
    }
}

- (NSURLRequest*) createRequestFromString:(NSString*) urlString timeout:(int)timeout {
    NSURL* url = [[NSURL alloc] initWithString:urlString];
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
    [request setTimeoutInterval:timeout];
    return request;
}

- (NSURLRequest*) newPairRequest:(NSData*)salt clientCert:(NSData*)clientCert {
    NSString* urlString = [NSString stringWithFormat:@"%@/pair?uniqueid=%@&devicename=%@&updateState=1&phrase=getservercert&salt=%@&clientcert=%@",
                           _baseHTTPURL, _uniqueId, _deviceName, [self bytesToHex:salt], [self bytesToHex:clientCert]];
    // This call blocks while waiting for the user to input the PIN on the PC
    return [self createRequestFromString:urlString timeout:EXTRA_LONG_TIMEOUT_SEC];
}

- (NSURLRequest*) newUnpairRequest {
    NSString* urlString = [NSString stringWithFormat:@"%@/unpair?uniqueid=%@", _baseHTTPURL, _uniqueId];
    return [self createRequestFromString:urlString timeout:NORMAL_TIMEOUT_SEC];
}

- (NSURLRequest*) newChallengeRequest:(NSData*)challenge {
    NSString* urlString = [NSString stringWithFormat:@"%@/pair?uniqueid=%@&devicename=%@&updateState=1&clientchallenge=%@",
                           _baseHTTPURL, _uniqueId, _deviceName, [self bytesToHex:challenge]];
    return [self createRequestFromString:urlString timeout:NORMAL_TIMEOUT_SEC];
}

- (NSURLRequest*) newChallengeRespRequest:(NSData*)challengeResp {
    NSString* urlString = [NSString stringWithFormat:@"%@/pair?uniqueid=%@&devicename=%@&updateState=1&serverchallengeresp=%@",
                           _baseHTTPURL, _uniqueId, _deviceName, [self bytesToHex:challengeResp]];
    return [self createRequestFromString:urlString timeout:NORMAL_TIMEOUT_SEC];
}

- (NSURLRequest*) newClientSecretRespRequest:(NSString*)clientPairSecret {
    NSString* urlString = [NSString stringWithFormat:@"%@/pair?uniqueid=%@&devicename=%@&updateState=1&clientpairingsecret=%@", _baseHTTPURL, _uniqueId, _deviceName, clientPairSecret];
    return [self createRequestFromString:urlString timeout:NORMAL_TIMEOUT_SEC];
}

- (NSURLRequest*) newPairChallenge {
    NSString* urlString = [NSString stringWithFormat:@"%@/pair?uniqueid=%@&devicename=%@&updateState=1&phrase=pairchallenge", _baseHTTPSURL, _uniqueId, _deviceName];
    return [self createRequestFromString:urlString timeout:NORMAL_TIMEOUT_SEC];
}

- (NSURLRequest *)newAppListRequest {
    NSString* urlString = [NSString stringWithFormat:@"%@/applist?uniqueid=%@", _baseHTTPSURL, _uniqueId];
    return [self createRequestFromString:urlString timeout:NORMAL_TIMEOUT_SEC];
}

- (NSURLRequest *)newServerInfoRequest:(bool)fastFail {
    if (_serverCert == nil) {
        // Use HTTP if the cert is not pinned yet
        return [self newHttpServerInfoRequest:fastFail];
    }
    
    NSString* urlString = [NSString stringWithFormat:@"%@/serverinfo?uniqueid=%@", _baseHTTPSURL, _uniqueId];
    return [self createRequestFromString:urlString timeout:(fastFail ? SHORT_TIMEOUT_SEC : NORMAL_TIMEOUT_SEC)];
}

- (NSURLRequest *)newHttpServerInfoRequest:(bool)fastFail {
    NSString* urlString = [NSString stringWithFormat:@"%@/serverinfo", _baseHTTPURL];
    return [self createRequestFromString:urlString timeout:(fastFail ? SHORT_TIMEOUT_SEC : NORMAL_TIMEOUT_SEC)];
}

- (NSURLRequest *)newHttpServerInfoRequest {
    return [self newHttpServerInfoRequest:false];
}

- (NSURLRequest*) newLaunchRequest:(StreamConfiguration*)config {
    BOOL sops = config.optimizeGameSettings;

    NSMutableString* extraParams = [NSMutableString string];

#if defined(VIDEO_FORMAT_H264_HIGH8_444)
    // Newer moonlight-common-c provides recommended query parameters for Sunshine extensions.
    const char* launchParams = LiGetLaunchUrlQueryParameters();
    if (launchParams != NULL && launchParams[0] != '\0') {
        [extraParams appendString:[NSString stringWithUTF8String:launchParams]];
    }
#endif

    int modeWidth = config.width;
    int modeHeight = config.height;
    int modeFps = config.frameRate;

    // Remote host mode overrides (mirrors moonlight-qt behavior): override only the /launch mode
    // parameter without changing the local client's configured stream settings.
    @try {
        NSString* uuid = nil;
        if (config.host != nil) {
            uuid = [SettingsClass getHostUUIDFrom:config.host];
        }

        NSString* settingsKey = uuid != nil ? uuid : @"__global__";
        NSDictionary* settings = [SettingsClass getSettingsFor:settingsKey];

        if (settings != nil) {
            NSNumber* remoteResolution = settings[@"remoteResolution"];
            if (remoteResolution != nil && [remoteResolution boolValue]) {
                int rw = [settings[@"remoteResolutionWidth"] intValue];
                int rh = [settings[@"remoteResolutionHeight"] intValue];
                if (rw > 0 && rh > 0) {
                    modeWidth = rw;
                    modeHeight = rh;
                }
            }

            NSNumber* remoteFps = settings[@"remoteFps"];
            if (remoteFps != nil && [remoteFps boolValue]) {
                int rfps = [settings[@"remoteFpsRate"] intValue];
                if (rfps > 0) {
                    modeFps = rfps;
                }
            }

            // Optional Sunshine protocol extensions (best-effort)
            if ([settings[@"yuv444"] boolValue]) {
                [extraParams appendString:@"&yuv444=1"];
            }
            if ([settings[@"microphone"] boolValue]) {
                [extraParams appendString:@"&microphone=1"];
            }
        }
    } @catch (NSException* exception) {
        // Best-effort only; keep defaults on any failure.
    }

    // Ensure even dimensions (some encoders/decoders require this)
    modeWidth &= ~1;
    modeHeight &= ~1;
    
    // Using an FPS value over 60 causes SOPS to default to 720p60.
    // We used to set it to 60, but that stopped working in GFE 3.20.3.
    // Disabling SOPS allows the actual game frame rate to exceed 60.
    if (modeFps > 60) {
        sops = NO;
    }
    
    NSString* urlString = [NSString stringWithFormat:@"%@/launch?uniqueid=%@&appid=%@&mode=%dx%dx%d&additionalStates=1&sops=%d&rikey=%@&rikeyid=%d%@%@&localAudioPlayMode=%d&surroundAudioInfo=%d",
                           _baseHTTPSURL, _uniqueId,
                           config.appID,
                           modeWidth, modeHeight, modeFps,
                           sops ? 1 : 0,
                           [Utils bytesToHex:config.riKey], config.riKeyId,
                           config.enableHdr ? @"&hdrMode=1&clientHdrCapVersion=0&clientHdrCapSupportedFlagsInUint32=0&clientHdrCapMetaDataId=NV_STATIC_METADATA_TYPE_1&clientHdrCapDisplayData=0x0x0x0x0x0x0x0x0x0x0": @"",
                           extraParams,
                           config.playAudioOnPC ? 1 : 0,
                           SURROUNDAUDIOINFO_FROM_AUDIO_CONFIGURATION(config.audioConfiguration)];
    Log(LOG_I, @"Requesting: %@", urlString);
    // This blocks while the app is launching
    return [self createRequestFromString:urlString timeout:LONG_TIMEOUT_SEC];
}

- (NSURLRequest*) newResumeRequest:(StreamConfiguration*)config {
    BOOL sops = config.optimizeGameSettings;

    NSMutableString* extraParams = [NSMutableString string];

#if defined(VIDEO_FORMAT_H264_HIGH8_444)
    // Newer moonlight-common-c provides recommended query parameters for Sunshine extensions.
    const char* launchParams = LiGetLaunchUrlQueryParameters();
    if (launchParams != NULL && launchParams[0] != '\0') {
        [extraParams appendString:[NSString stringWithUTF8String:launchParams]];
    }
#endif

    int modeWidth = config.width;
    int modeHeight = config.height;
    int modeFps = config.frameRate;

    @try {
        NSString* uuid = nil;
        if (config.host != nil) {
            uuid = [SettingsClass getHostUUIDFrom:config.host];
        }

        NSString* settingsKey = uuid != nil ? uuid : @"__global__";
        NSDictionary* settings = [SettingsClass getSettingsFor:settingsKey];

        if (settings != nil) {
            NSNumber* remoteResolution = settings[@"remoteResolution"];
            if (remoteResolution != nil && [remoteResolution boolValue]) {
                int rw = [settings[@"remoteResolutionWidth"] intValue];
                int rh = [settings[@"remoteResolutionHeight"] intValue];
                if (rw > 0 && rh > 0) {
                    modeWidth = rw;
                    modeHeight = rh;
                }
            }

            NSNumber* remoteFps = settings[@"remoteFps"];
            if (remoteFps != nil && [remoteFps boolValue]) {
                int rfps = [settings[@"remoteFpsRate"] intValue];
                if (rfps > 0) {
                    modeFps = rfps;
                }
            }

            // Optional Sunshine protocol extensions (best-effort)
            if ([settings[@"yuv444"] boolValue]) {
                [extraParams appendString:@"&yuv444=1"];
            }
            if ([settings[@"microphone"] boolValue]) {
                [extraParams appendString:@"&microphone=1"];
            }
        }
    } @catch (NSException* exception) {
    }

    modeWidth &= ~1;
    modeHeight &= ~1;
    
    // Using an FPS value over 60 causes SOPS to default to 720p60.
    // We used to set it to 60, but that stopped working in GFE 3.20.3.
    // Disabling SOPS allows the actual game frame rate to exceed 60.
    if (modeFps > 60) {
        sops = NO;
    }
    
    NSString* urlString = [NSString stringWithFormat:@"%@/resume?uniqueid=%@&appid=%@&mode=%dx%dx%d&additionalStates=1&sops=%d&rikey=%@&rikeyid=%d%@%@&localAudioPlayMode=%d&surroundAudioInfo=%d",
                           _baseHTTPSURL, _uniqueId,
                           config.appID,
                           modeWidth, modeHeight, modeFps,
                           sops ? 1 : 0,
                           [Utils bytesToHex:config.riKey], config.riKeyId,
                           config.enableHdr ? @"&hdrMode=1&clientHdrCapVersion=0&clientHdrCapSupportedFlagsInUint32=0&clientHdrCapMetaDataId=NV_STATIC_METADATA_TYPE_1&clientHdrCapDisplayData=0x0x0x0x0x0x0x0x0x0x0": @"",
                           extraParams,
                           config.playAudioOnPC ? 1 : 0,
                           SURROUNDAUDIOINFO_FROM_AUDIO_CONFIGURATION(config.audioConfiguration)];
    Log(LOG_I, @"Requesting: %@", urlString);
    // This blocks while the app is resuming
    return [self createRequestFromString:urlString timeout:LONG_TIMEOUT_SEC];
}

- (NSURLRequest*) newQuitAppRequest {
    NSString* urlString = [NSString stringWithFormat:@"%@/cancel?uniqueid=%@", _baseHTTPSURL, _uniqueId];
    return [self createRequestFromString:urlString timeout:LONG_TIMEOUT_SEC];
}

- (NSURLRequest*) newAppAssetRequestWithAppId:(NSString *)appId {
    NSString* urlString = [NSString stringWithFormat:@"%@/appasset?uniqueid=%@&appid=%@&AssetType=2&AssetIdx=0", _baseHTTPSURL, _uniqueId, appId];
    return [self createRequestFromString:urlString timeout:NORMAL_TIMEOUT_SEC];
}

- (NSString*) bytesToHex:(NSData*)data {
    const unsigned char* bytes = [data bytes];
    NSMutableString *hex = [[NSMutableString alloc] init];
    for (int i = 0; i < [data length]; i++) {
        [hex appendFormat:@"%02X" , bytes[i]];
    }
    return hex;
}

// Returns an array containing the certificate
- (NSArray*)getCertificate:(SecIdentityRef) identity {
    SecCertificateRef certificate = nil;
    
    SecIdentityCopyCertificate(identity, &certificate);
    
    return [[NSArray alloc] initWithObjects:CFBridgingRelease(certificate), nil];
}

// Returns the identity
- (SecIdentityRef)getClientCertificate {
    SecIdentityRef identityApp = nil;
    CFDataRef p12Data = (__bridge CFDataRef)[CryptoManager readP12FromFile];

    CFStringRef password = CFSTR("limelight");
    const void *keys[] = { kSecImportExportPassphrase };
    const void *values[] = { password };
    CFDictionaryRef options = CFDictionaryCreate(NULL, keys, values, 1, NULL, NULL);
    CFArrayRef items;
    OSStatus securityError = SecPKCS12Import(p12Data, options, &items);

    if (securityError == errSecSuccess && CFArrayGetCount(items) > 0) {
        //Log(LOG_D, @"Success opening p12 certificate. Items: %ld", CFArrayGetCount(items));
        CFDictionaryRef identityDict = CFArrayGetValueAtIndex(items, 0);
        identityApp = (SecIdentityRef)CFDictionaryGetValue(identityDict, kSecImportItemIdentity);
        CFRetain(identityApp);
    } else {
        Log(LOG_E, @"Error opening Certificate.");
    }
    
    CFRelease(items);
    CFRelease(options);
    CFRelease(password);
    
    return identityApp;
}

- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(nonnull void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * __nullable))completionHandler {
    // Allow untrusted server certificates
    if([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust])
    {
        if (SecTrustGetCertificateCount(challenge.protectionSpace.serverTrust) != 1) {
            Log(LOG_E, @"Server certificate count mismatch");
            completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, NULL);
            return;
        }
        
        SecCertificateRef actualCert = NULL;
        if (@available(macOS 12.0, *)) {
            CFArrayRef certs = SecTrustCopyCertificateChain(challenge.protectionSpace.serverTrust);
            if (certs) {
                if (CFArrayGetCount(certs) > 0) {
                    actualCert = (SecCertificateRef)CFArrayGetValueAtIndex(certs, 0);
                }
                CFRelease(certs);
            }
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            actualCert = SecTrustGetCertificateAtIndex(challenge.protectionSpace.serverTrust, 0);
#pragma clang diagnostic pop
        }

        if (actualCert == nil) {
            Log(LOG_E, @"Server certificate parsing error");
            completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, NULL);
            return;
        }
        
        CFDataRef actualCertData = SecCertificateCopyData(actualCert);
        if (actualCertData == nil) {
            Log(LOG_E, @"Server certificate data parsing error");
            completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, NULL);
            return;
        }
        
        if (!CFEqual(actualCertData, (__bridge CFDataRef)_serverCert)) {
            Log(LOG_W, @"Server certificate mismatch");
            CFRelease(actualCertData);
            completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, NULL);
            return;
        }
        
        CFRelease(actualCertData);
        
        // Allow TLS handshake to proceed
        completionHandler(NSURLSessionAuthChallengeUseCredential,
                          [NSURLCredential credentialForTrust: challenge.protectionSpace.serverTrust]);
    }
    // Respond to client certificate challenge with our certificate
    else if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodClientCertificate])
    {
        SecIdentityRef identity = [self getClientCertificate];
        NSArray* certArray = [self getCertificate:identity];
        NSURLCredential* newCredential = [NSURLCredential credentialWithIdentity:identity certificates:certArray persistence:NSURLCredentialPersistencePermanent];
        completionHandler(NSURLSessionAuthChallengeUseCredential, newCredential);
        CFRelease(identity);
    }
    else
    {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, NULL);
    }
}

@end
