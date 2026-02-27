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
#include <CommonCrypto/CommonDigest.h>

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

// Fallback: import PKCS12 into a temporary file-based keychain.
// This bypasses the default Data Protection keychain which may require
// entitlements not available to the app (-34018 errSecMissingEntitlement).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (SecIdentityRef)importP12ViaTemporaryKeychain:(NSData *)p12Obj {
    // Keep the keychain alive as a static - the SecIdentityRef references it
    static SecKeychainRef persistentKeychain = NULL;

    NSArray *docPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *keychainPath = [[docPaths objectAtIndex:0] stringByAppendingPathComponent:@"moonlight.keychain"];
    const char *cPath = keychainPath.UTF8String;

    // Clean up previous keychain to avoid stale key material
    if (persistentKeychain) {
        SecKeychainDelete(persistentKeychain);
        CFRelease(persistentKeychain);
        persistentKeychain = NULL;
    }
    [[NSFileManager defaultManager] removeItemAtPath:keychainPath error:nil];

    // Remove any leftover moonlight.keychain from the system search list.
    // Previous versions (or previous runs) may have added it, causing macOS
    // to prompt "wants to use moonlight's keychain" when the keychain is locked.
    CFArrayRef currentSearchList = NULL;
    SecKeychainCopySearchList(&currentSearchList);
    if (currentSearchList) {
        NSMutableArray *cleanedList = [NSMutableArray array];
        BOOL dirty = NO;
        for (CFIndex i = 0; i < CFArrayGetCount(currentSearchList); i++) {
            SecKeychainRef kc = (SecKeychainRef)CFArrayGetValueAtIndex(currentSearchList, i);
            char kcPath[1024];
            UInt32 kcPathLen = sizeof(kcPath);
            if (SecKeychainGetPath(kc, &kcPathLen, kcPath) == errSecSuccess) {
                NSString *kcPathStr = [[NSString alloc] initWithBytes:kcPath length:kcPathLen encoding:NSUTF8StringEncoding];
                if ([kcPathStr hasSuffix:@"moonlight.keychain"]) {
                    dirty = YES;
                    continue; // skip — remove from search list
                }
            }
            [cleanedList addObject:(__bridge id)kc];
        }
        if (dirty) {
            SecKeychainSetSearchList((__bridge CFArrayRef)cleanedList);
            Log(LOG_I, @"Removed leftover moonlight.keychain from system search list");
        }
        CFRelease(currentSearchList);
    }

    OSStatus status = SecKeychainCreate(cPath, 9, "limelight", FALSE, NULL, &persistentKeychain);
    if (status != errSecSuccess) {
        Log(LOG_E, @"Temp keychain fallback: creation failed (%d)", (int)status);
        persistentKeychain = NULL;
        return nil;
    }

    // SecKeychainCreate auto-appends to the search list; remove it immediately
    CFArrayRef postCreateList = NULL;
    SecKeychainCopySearchList(&postCreateList);
    if (postCreateList) {
        NSMutableArray *filteredList = [NSMutableArray array];
        for (CFIndex i = 0; i < CFArrayGetCount(postCreateList); i++) {
            SecKeychainRef kc = (SecKeychainRef)CFArrayGetValueAtIndex(postCreateList, i);
            char kcPath[1024];
            UInt32 kcPathLen = sizeof(kcPath);
            if (SecKeychainGetPath(kc, &kcPathLen, kcPath) == errSecSuccess) {
                NSString *kcPathStr = [[NSString alloc] initWithBytes:kcPath length:kcPathLen encoding:NSUTF8StringEncoding];
                if ([kcPathStr hasSuffix:@"moonlight.keychain"]) {
                    continue;
                }
            }
            [filteredList addObject:(__bridge id)kc];
        }
        SecKeychainSetSearchList((__bridge CFArrayRef)filteredList);
        CFRelease(postCreateList);
    }

    const void *optKeys[] = { kSecImportExportPassphrase, kSecImportExportKeychain };
    const void *optValues[] = { CFSTR("limelight"), persistentKeychain };
    CFDictionaryRef options = CFDictionaryCreate(NULL, optKeys, optValues, 2, NULL, NULL);

    CFArrayRef items = NULL;
    OSStatus importStatus = SecPKCS12Import((__bridge CFDataRef)p12Obj, options, &items);
    CFRelease(options);

    SecIdentityRef identity = nil;
    if (importStatus == errSecSuccess && items != NULL) {
        for (CFIndex i = 0; i < CFArrayGetCount(items); i++) {
            CFDictionaryRef dict = CFArrayGetValueAtIndex(items, i);
            SecIdentityRef candidate = (SecIdentityRef)CFDictionaryGetValue(dict, kSecImportItemIdentity);
            if (candidate != NULL) {
                identity = candidate;
                CFRetain(identity);
                break;
            }
        }
    }
    if (items != NULL) {
        CFRelease(items);
    }

    if (identity != nil) {
        Log(LOG_I, @"Temp keychain fallback: successfully created identity");
    } else {
        Log(LOG_E, @"Temp keychain fallback: import failed (%d) or no identity returned", (int)importStatus);
    }
    return identity;
}
#pragma clang diagnostic pop

// Returns the identity, with caching to avoid recreating the keychain on every TLS challenge
- (SecIdentityRef)getClientCertificate {
    // Serialize certificate import + regeneration across all concurrent TLS challenges
    static NSObject *certLock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        certLock = [[NSObject alloc] init];
    });

    // Cache: reuse identity if the P12 file hasn't changed
    static SecIdentityRef cachedIdentity = NULL;
    static NSData *cachedP12Hash = nil;

    SecIdentityRef identityApp = nil;

    @synchronized(certLock) {
        NSData *p12Obj = [CryptoManager readP12FromFile];

        // Quick hash to detect P12 changes (regeneration or first launch)
        NSData *currentHash = nil;
        if (p12Obj != nil && [p12Obj length] > 0) {
            unsigned char digest[CC_SHA256_DIGEST_LENGTH];
            CC_SHA256(p12Obj.bytes, (CC_LONG)p12Obj.length, digest);
            currentHash = [NSData dataWithBytes:digest length:sizeof(digest)];
        }

        // Return cached identity if P12 unchanged
        if (cachedIdentity != NULL && cachedP12Hash != nil &&
            currentHash != nil && [currentHash isEqualToData:cachedP12Hash]) {
            CFRetain(cachedIdentity);
            return cachedIdentity;
        }

        // P12 changed or no cache — clear old cache
        if (cachedIdentity != NULL) {
            CFRelease(cachedIdentity);
            cachedIdentity = NULL;
        }
        cachedP12Hash = nil;

        for (int attempt = 0; attempt < 2 && identityApp == nil; attempt++) {
            if (attempt > 0) {
                // Re-read after regeneration
                p12Obj = [CryptoManager readP12FromFile];
                if (p12Obj != nil && [p12Obj length] > 0) {
                    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
                    CC_SHA256(p12Obj.bytes, (CC_LONG)p12Obj.length, digest);
                    currentHash = [NSData dataWithBytes:digest length:sizeof(digest)];
                }
            }

            if (p12Obj == nil || [p12Obj length] == 0) {
                Log(LOG_E, @"Error opening Certificate: client.p12 is missing or empty");
                if (attempt == 0) {
                    [CryptoManager regenerateKeyPairUsingSSL];
                    continue;
                }
                break;
            }

            CFDataRef p12Data = (__bridge CFDataRef)p12Obj;

            const void *keys[] = { kSecImportExportPassphrase };
            const void *values[] = { CFSTR("limelight") };
            CFDictionaryRef options = CFDictionaryCreate(NULL, keys, values, 1, NULL, NULL);

            CFArrayRef items = NULL;
            OSStatus securityError = SecPKCS12Import(p12Data, options, &items);

            if (securityError == errSecSuccess && items != NULL) {
                CFIndex count = CFArrayGetCount(items);
                for (CFIndex i = 0; i < count; i++) {
                    CFDictionaryRef identityDict = CFArrayGetValueAtIndex(items, i);
                    SecIdentityRef candidateIdentity = (SecIdentityRef)CFDictionaryGetValue(identityDict, kSecImportItemIdentity);
                    if (candidateIdentity != NULL) {
                        identityApp = candidateIdentity;
                        CFRetain(identityApp);
                        break;
                    }
                }
            }

            if (items != NULL) {
                CFRelease(items);
            }
            CFRelease(options);

            // Fallback: if default keychain import failed or returned no identity,
            // try importing into a temporary file-based keychain we fully control.
            if (identityApp == nil) {
                if (securityError == errSecSuccess) {
                    Log(LOG_W, @"PKCS12 import succeeded (status=0) but no identity returned, trying temp keychain fallback");
                } else {
                    Log(LOG_E, @"PKCS12 import failed (status=%d), trying temp keychain fallback", (int)securityError);
                }

                identityApp = [self importP12ViaTemporaryKeychain:p12Obj];

                if (identityApp == nil && attempt == 0) {
                    // Only regenerate if the P12 file is missing or corrupt.
                    // If import keeps failing with a valid file, regenerating
                    // would destroy the existing pairing for no benefit.
                    if (![CryptoManager keyPairExists]) {
                        Log(LOG_W, @"Temp keychain fallback failed and cert files missing, regenerating certificates");
                        [CryptoManager regenerateKeyPairUsingSSL];
                    } else {
                        Log(LOG_E, @"Temp keychain fallback failed but cert files exist on disk; skipping regeneration to preserve pairing");
                    }
                }
            }
        }

        // Update cache
        if (identityApp != NULL && currentHash != nil) {
            cachedIdentity = identityApp;
            CFRetain(cachedIdentity);
            cachedP12Hash = currentHash;
        }
    }

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
        if (identity == nil) {
            Log(LOG_E, @"No client certificate identity available for TLS client auth challenge");
            completionHandler(NSURLSessionAuthChallengeRejectProtectionSpace, NULL);
            return;
        }
        NSArray* certArray = [self getCertificate:identity];
        // Use ForSession persistence to avoid macOS prompting for keychain password.
        // We manage identity caching ourselves in getClientCertificate.
        NSURLCredential* newCredential = [NSURLCredential credentialWithIdentity:identity certificates:certArray persistence:NSURLCredentialPersistenceForSession];
        completionHandler(NSURLSessionAuthChallengeUseCredential, newCredential);
        if (identity != nil) {
            CFRelease(identity);
        }
    }
    else
    {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, NULL);
    }
}

@end
