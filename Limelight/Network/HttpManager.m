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
#import "MoonlightEnhanced-Swift.h"

#include <libxml2/libxml/xmlreader.h>
#include <string.h>
#include <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>

#include <Limelight.h>

#define SHORT_TIMEOUT_SEC 2
#define NORMAL_TIMEOUT_SEC 5
#define DISPLAY_TOPOLOGY_TIMEOUT_SEC 15
#define FILE_MAPPING_TIMEOUT_SEC 10
#define LONG_TIMEOUT_SEC 60
#define EXTRA_LONG_TIMEOUT_SEC 180

@interface MLSunshineDisplaysResponse : NSObject <Response>
@property (nonatomic) NSInteger statusCode;
@property (nonatomic, strong) NSString *statusMessage;
@property (nonatomic, strong) NSData *data;
@property (nonatomic, copy) NSArray<NSDictionary<NSString*, id>*> *displays;
@property (nonatomic, strong) NSDictionary<NSString *, id> *vdd;
@property (nonatomic) NSInteger count;
@end

@interface MLSunshineJSONResponse : NSObject <Response>
@property (nonatomic) NSInteger statusCode;
@property (nonatomic, strong) NSString *statusMessage;
@property (nonatomic, strong) NSData *data;
@end

@implementation MLSunshineJSONResponse

- (instancetype)init {
    self = [super init];
    if (self) {
        _statusCode = 500;
        _statusMessage = @"Server Error";
    }
    return self;
}

- (void)populateWithData:(NSData *)data {
    self.data = data ?: [NSData data];
    NSError *error = nil;
    id object = self.data.length > 0
        ? [NSJSONSerialization JSONObjectWithData:self.data options:0 error:&error] : nil;
    if (![object isKindOfClass:[NSDictionary class]]) {
        self.statusCode = 500;
        self.statusMessage = error.localizedDescription ?: @"Invalid JSON response";
    } else {
        NSDictionary *json = (NSDictionary *)object;
        self.statusCode = [json[@"status_code"] respondsToSelector:@selector(integerValue)]
            ? [json[@"status_code"] integerValue] : 200;
        self.statusMessage = [json[@"status_message"] isKindOfClass:[NSString class]]
            ? json[@"status_message"] : @"";
    }
}

@end

@implementation MLSunshineDisplaysResponse

- (instancetype)init {
    self = [super init];
    if (self) {
        _statusCode = 500;
        _statusMessage = @"Server Error";
        _displays = @[];
        _vdd = @{};
        _count = 0;
    }
    return self;
}

- (void)populateWithData:(NSData *)data {
    self.data = data;
    if (data.length == 0) {
        self.statusCode = 500;
        self.statusMessage = @"Empty response";
        self.displays = @[];
        self.vdd = @{};
        self.count = 0;
        return;
    }

    NSError *jsonError = nil;
    id jsonObject = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![jsonObject isKindOfClass:[NSDictionary class]]) {
        self.statusCode = 500;
        self.statusMessage = jsonError.localizedDescription ?: @"Invalid Sunshine displays response";
        self.displays = @[];
        self.vdd = @{};
        self.count = 0;
        return;
    }

    NSDictionary *json = (NSDictionary *)jsonObject;
    NSNumber *statusCode = json[@"status_code"];
    NSString *statusMessage = json[@"status_message"];
    NSArray *displays = json[@"displays"];
    NSDictionary *vdd = [json[@"vdd"] isKindOfClass:[NSDictionary class]] ? json[@"vdd"] : @{};

    self.statusCode = statusCode != nil ? statusCode.integerValue : 500;
    self.statusMessage = statusMessage.length > 0 ? statusMessage : @"Server Error";
    self.vdd = vdd;
    self.count = [json[@"count"] respondsToSelector:@selector(integerValue)]
        ? [json[@"count"] integerValue] : 0;
    if ([displays isKindOfClass:[NSArray class]]) {
        NSMutableArray<NSDictionary<NSString*, id>*> *parsedDisplays = [NSMutableArray arrayWithCapacity:displays.count];
        for (id entry in displays) {
            if (![entry isKindOfClass:[NSDictionary class]]) {
                continue;
            }

            NSString *displayName = [entry[@"display_name"] isKindOfClass:[NSString class]] ? entry[@"display_name"] : @"";
            NSString *deviceId = [entry[@"device_id"] isKindOfClass:[NSString class]] ? entry[@"device_id"] : displayName;
            NSString *friendlyName = [entry[@"friendly_name"] isKindOfClass:[NSString class]] ? entry[@"friendly_name"] : deviceId;
            NSNumber *index = [entry[@"index"] isKindOfClass:[NSNumber class]] ? entry[@"index"] : @(parsedDisplays.count);
            NSMutableDictionary *parsedEntry = [@{
                @"index": index,
                @"display_name": displayName ?: @"",
                @"device_id": deviceId ?: @"",
                @"friendly_name": friendlyName ?: @"",
            } mutableCopy];
            for (NSString *key in @[@"is_primary", @"current_scale_percent",
                                    @"recommended_scale_percent", @"supported_scale_percents",
                                    @"scale_set_supported"]) {
                if (entry[key] != nil) {
                    parsedEntry[key] = entry[key];
                }
            }
            [parsedDisplays addObject:parsedEntry];
        }
        self.displays = parsedDisplays;
    } else {
        self.displays = @[];
    }
}

@end

// Streams the probe body so the transfer can be timed from the first response byte,
// excluding connection setup. Challenges are answered by the owning HttpManager.
@interface MLSunshineProbeCollector : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, weak) HttpManager *manager;
@property (nonatomic, copy) NSString *expectedNonce;
@property (nonatomic) NSInteger statusCode;
@property (nonatomic, copy) NSString *failure;
@property (nonatomic) uint64_t receivedBytes;
@property (nonatomic) uint64_t startNs;
@property (nonatomic) uint64_t endNs;
@property (nonatomic, strong) NSMutableData *errorBody;
@property (nonatomic, strong) NSError *transportError;
@property (nonatomic, strong) dispatch_semaphore_t done;
@end

@implementation MLSunshineProbeCollector

- (instancetype)init {
    self = [super init];
    if (self) {
        _done = dispatch_semaphore_create(0);
        _errorBody = [NSMutableData data];
    }
    return self;
}

- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler {
    HttpManager *manager = self.manager;
    if (manager == nil) {
        completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
        return;
    }
    [manager URLSession:session didReceiveChallenge:challenge completionHandler:completionHandler];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    self.statusCode = http.statusCode;
    if (http.statusCode == 200) {
        NSString *nonce = http.allHeaderFields[@"X-Bandwidth-Probe-Nonce"];
        NSString *version = http.allHeaderFields[@"X-Bandwidth-Probe-Version"];
        if (![version isEqualToString:@"1"] || ![nonce isEqualToString:self.expectedNonce]) {
            self.failure = @"invalid_response";
            completionHandler(NSURLSessionResponseCancel);
            return;
        }
        self.startNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (self.statusCode == 200) {
        self.receivedBytes += data.length;
        self.endNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    } else if (self.errorBody.length < 4096) {
        [self.errorBody appendData:data];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    self.transportError = error;
    dispatch_semaphore_signal(self.done);
}

@end

@implementation HttpManager {
    NSString* _baseHTTPURL;
    NSString* _baseHTTPSURL;
    NSString* _clientUniqueId;
    NSString* _sharedStreamUniqueId;
    NSString* _deviceName;
    NSData* _serverCert;
    
    NSError* _error;
    NSURLSession* _apiSession;
}

static uint64_t gLastServerInfoErrorLogMs = 0;
static int gSuppressedServerInfoErrorLogs = 0;
static const char *kTempKeychainPassword = "limelight";
static NSString * const kSharedStreamSessionUniqueId = @"0123456789ABCDEF";
// Not always exposed as a named constant in older SDKs.
static const OSStatus kErrSecPkcs12VerifyFailure = -25264;
static SecKeychainRef gTempClientKeychain = NULL;
static NSString *gTempClientKeychainPath = nil;

static CFStringRef GetImportToMemoryOnlyKey(void) {
    static CFStringRef key = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *sym = dlsym(RTLD_DEFAULT, "kSecImportToMemoryOnly");
        if (sym != NULL) {
            key = *(CFStringRef *)sym;
        }
    });
    return key;
}

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
    // Use a per-client ID for pairing/discovery so different Moonlight installs
    // don't overwrite each other's pairing state on the host.
    _clientUniqueId = uniqueId.length > 0 ? uniqueId : kSharedStreamSessionUniqueId;
    // Keep the historical shared stream session ID so another Moonlight client
    // can still stop a session started elsewhere.
    _sharedStreamUniqueId = kSharedStreamSessionUniqueId;
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

- (NSURLRequest *)newClipboardRequestWithPath:(NSString *)path {
    if (path.length == 0 || ![path hasPrefix:@"/"]) {
        return nil;
    }
    NSString *urlString = [NSString stringWithFormat:@"%@%@", _baseHTTPSURL, path];
    return [self createRequestFromString:urlString timeout:EXTRA_LONG_TIMEOUT_SEC];
}

- (void)executeDataRequest:(NSURLRequest *)request completion:(MLHttpDataCompletion)completion {
    if (request == nil || completion == nil) {
        return;
    }

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(data, (NSHTTPURLResponse *)response, error);
            [session finishTasksAndInvalidate];
        });
    }];
    [task resume];
}

- (NSURLRequest*) newPairRequest:(NSData*)salt clientCert:(NSData*)clientCert {
    NSString* urlString = [NSString stringWithFormat:@"%@/pair?uniqueid=%@&devicename=%@&updateState=1&phrase=getservercert&salt=%@&clientcert=%@",
                           _baseHTTPURL, _clientUniqueId, _deviceName, [self bytesToHex:salt], [self bytesToHex:clientCert]];
    // This call blocks while waiting for the user to input the PIN on the PC
    return [self createRequestFromString:urlString timeout:EXTRA_LONG_TIMEOUT_SEC];
}

- (NSURLRequest*) newUnpairRequest {
    NSString* urlString = [NSString stringWithFormat:@"%@/unpair?uniqueid=%@", _baseHTTPURL, _clientUniqueId];
    return [self createRequestFromString:urlString timeout:DISPLAY_TOPOLOGY_TIMEOUT_SEC];
}

- (NSURLRequest*) newChallengeRequest:(NSData*)challenge {
    NSString* urlString = [NSString stringWithFormat:@"%@/pair?uniqueid=%@&devicename=%@&updateState=1&clientchallenge=%@",
                           _baseHTTPURL, _clientUniqueId, _deviceName, [self bytesToHex:challenge]];
    return [self createRequestFromString:urlString timeout:NORMAL_TIMEOUT_SEC];
}

- (NSURLRequest*) newChallengeRespRequest:(NSData*)challengeResp {
    NSString* urlString = [NSString stringWithFormat:@"%@/pair?uniqueid=%@&devicename=%@&updateState=1&serverchallengeresp=%@",
                           _baseHTTPURL, _clientUniqueId, _deviceName, [self bytesToHex:challengeResp]];
    return [self createRequestFromString:urlString timeout:NORMAL_TIMEOUT_SEC];
}

- (NSURLRequest*) newClientSecretRespRequest:(NSString*)clientPairSecret {
    NSString* urlString = [NSString stringWithFormat:@"%@/pair?uniqueid=%@&devicename=%@&updateState=1&clientpairingsecret=%@", _baseHTTPURL, _clientUniqueId, _deviceName, clientPairSecret];
    return [self createRequestFromString:urlString timeout:NORMAL_TIMEOUT_SEC];
}

- (NSURLRequest*) newPairChallenge {
    NSString* urlString = [NSString stringWithFormat:@"%@/pair?uniqueid=%@&devicename=%@&updateState=1&phrase=pairchallenge", _baseHTTPSURL, _clientUniqueId, _deviceName];
    return [self createRequestFromString:urlString timeout:NORMAL_TIMEOUT_SEC];
}

- (NSURLRequest *)newAppListRequest {
    NSString* urlString = [NSString stringWithFormat:@"%@/applist?uniqueid=%@", _baseHTTPSURL, _clientUniqueId];
    return [self createRequestFromString:urlString timeout:NORMAL_TIMEOUT_SEC];
}

- (NSURLRequest *)newServerInfoRequest:(bool)fastFail {
    if (_serverCert == nil) {
        // Use HTTP if the cert is not pinned yet
        return [self newHttpServerInfoRequest:fastFail];
    }
    
    NSString* urlString = [NSString stringWithFormat:@"%@/serverinfo?uniqueid=%@", _baseHTTPSURL, _clientUniqueId];
    return [self createRequestFromString:urlString timeout:(fastFail ? SHORT_TIMEOUT_SEC : NORMAL_TIMEOUT_SEC)];
}

- (NSURLRequest *)newHttpServerInfoRequest:(bool)fastFail {
    // Keep uniqueid on HTTP fallback too; some legacy hosts report PairStatus
    // against the supplied client ID and may otherwise default to unpaired.
    NSString* urlString = [NSString stringWithFormat:@"%@/serverinfo?uniqueid=%@", _baseHTTPURL, _clientUniqueId];
    return [self createRequestFromString:urlString timeout:(fastFail ? SHORT_TIMEOUT_SEC : NORMAL_TIMEOUT_SEC)];
}

- (NSURLRequest *)newHttpServerInfoRequest {
    return [self newHttpServerInfoRequest:false];
}

- (NSURLRequest *)newDisplaysRequest {
    NSString *urlString = [NSString stringWithFormat:@"%@/displays?uniqueid=%@", _baseHTTPSURL, _clientUniqueId];
    // Foundation Sunshine queries the host display driver and VDD state while
    // building this response. That can legitimately take longer than the
    // fast server-info probe, especially while a virtual display is starting.
    // Keep the capability request bounded, but do not turn driver latency into
    // a false "topology unavailable" result.
    return [self createRequestFromString:urlString timeout:NORMAL_TIMEOUT_SEC];
}

- (NSArray<NSDictionary<NSString*, id>*>*)fetchSunshineDisplays {
    return [self fetchSunshineDisplaySnapshot][@"displays"] ?: @[];
}

- (NSDictionary<NSString*, id>*)fetchSunshineDisplaySnapshot {
    MLSunshineDisplaysResponse *response = [[MLSunshineDisplaysResponse alloc] init];
    HttpRequest *request = [HttpRequest requestForResponse:response withUrlRequest:[self newDisplaysRequest]];
    [self executeRequestSynchronously:request];

    if (response.statusCode != 200) {
        Log(LOG_W, @"[sunshine] Display list request failed: %ld %@", (long)response.statusCode, response.statusMessage ?: @"");
        return @{
            @"statusCode": @(response.statusCode),
            @"statusMessage": response.statusMessage ?: @"",
            @"displays": @[],
            @"count": @(response.count),
            @"vdd": response.vdd ?: @{}
        };
    }

    Log(LOG_I, @"[sunshine] Loaded %lu host displays", (unsigned long)response.displays.count);
    return @{
        @"statusCode": @(response.statusCode),
        @"statusMessage": response.statusMessage ?: @"",
        @"displays": response.displays ?: @[],
        @"count": @(response.count),
        @"vdd": response.vdd ?: @{}
    };
}

- (NSDictionary<NSString*, id>*)fetchSunshineUSBForwardingCapability {
    NSString *urlString = [NSString stringWithFormat:@"%@/api/v1/usb-forwarding?uniqueid=%@",
                           _baseHTTPSURL, _clientUniqueId];
    NSURLRequest *requestURL = [self createRequestFromString:urlString timeout:NORMAL_TIMEOUT_SEC];
    MLSunshineJSONResponse *response = [[MLSunshineJSONResponse alloc] init];
    HttpRequest *request = [HttpRequest requestForResponse:response withUrlRequest:requestURL];
    [self executeRequestSynchronously:request];

    NSMutableDictionary *result = [@{
        @"statusCode": @(response.statusCode),
        @"statusMessage": response.statusMessage ?: @"",
        @"available": @NO,
        @"enabled": @NO
    } mutableCopy];
    if (response.statusCode != 200 || response.data.length == 0) {
        return result;
    }

    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:response.data options:0 error:&error];
    if (![object isKindOfClass:[NSDictionary class]]) {
        result[@"statusMessage"] = error.localizedDescription ?: @"Invalid JSON response";
        return result;
    }

    NSDictionary *json = (NSDictionary *)object;
    NSNumber *version = [json[@"version"] isKindOfClass:[NSNumber class]] ? json[@"version"] : nil;
    NSNumber *enabled = [json[@"enabled"] isKindOfClass:[NSNumber class]] ? json[@"enabled"] : nil;
    NSNumber *available = [json[@"available"] isKindOfClass:[NSNumber class]] ? json[@"available"] : nil;
    NSString *reason = [json[@"reason"] isKindOfClass:[NSString class]] ? json[@"reason"] : @"";
    NSString *token = [json[@"token"] isKindOfClass:[NSString class]] ? json[@"token"] : @"";
    NSNumber *port = [json[@"port"] isKindOfClass:[NSNumber class]] ? json[@"port"] : nil;
    // Disabled/unavailable hosts intentionally omit the tunnel port and token.
    // See Foundation's certificate-authenticated /api/v1/usb-forwarding route.
    if (version.integerValue == 1 && enabled != nil && available != nil &&
        (!enabled.boolValue || !available.boolValue)) {
        result[@"enabled"] = enabled;
        result[@"available"] = available;
        result[@"reason"] = reason;
        return result;
    }
    BOOL validToken = token.length == 64;
    if (validToken) {
        NSRegularExpression *hex = [NSRegularExpression regularExpressionWithPattern:@"\\A[0-9a-fA-F]{64}\\z"
                                                                                options:0
                                                                                  error:NULL];
        validToken = [hex firstMatchInString:token options:0 range:NSMakeRange(0, token.length)] != nil;
    }
    BOOL valid = version.integerValue == 1 && enabled != nil && available != nil &&
        port != nil && port.integerValue > 0 && port.integerValue <= 65535 && validToken;
    if (!valid) {
        result[@"statusCode"] = @502;
        result[@"statusMessage"] = reason.length > 0 ? reason : @"Invalid USB forwarding capability";
        return result;
    }

    result[@"enabled"] = enabled;
    result[@"available"] = available;
    result[@"reason"] = reason;
    if (enabled.boolValue && available.boolValue) {
        result[@"port"] = port;
        // Keep the token only in this in-memory result; callers must not persist it.
        result[@"token"] = token;
    }
    return result;
}

- (NSDictionary<NSString*, id>*)fetchSunshineFileMappingCapability {
    NSString *urlString = [NSString stringWithFormat:@"%@/api/v1/file-mapping/capability?client_uuid=%@",
                           _baseHTTPSURL,
                           [_clientUniqueId stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] ?: @""];
    NSMutableURLRequest *requestURL = [[self createRequestFromString:urlString timeout:FILE_MAPPING_TIMEOUT_SEC] mutableCopy];
    [requestURL setValue:_clientUniqueId forHTTPHeaderField:@"X-File-Mapping-Client-UUID"];
    // The capability endpoint returns JSON; the XML HttpResponse left statusCode at 0.
    MLSunshineJSONResponse *response = [[MLSunshineJSONResponse alloc] init];
    HttpRequest *request = [HttpRequest requestForResponse:response withUrlRequest:requestURL];
    [self executeRequestSynchronously:request];

    NSMutableDictionary *result = [@{
        @"statusCode": @(response.statusCode),
        @"statusMessage": response.statusMessage ?: @"",
        @"ok": @NO,
        @"enabled": @NO,
        @"listening": @NO
    } mutableCopy];
    if (response.statusCode != 200 || response.data.length == 0) {
        return result;
    }

    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:response.data options:0 error:&error];
    if (![object isKindOfClass:NSDictionary.class]) {
        result[@"statusMessage"] = error.localizedDescription ?: @"Invalid file mapping capability response";
        return result;
    }

    NSDictionary *json = (NSDictionary *)object;
    NSNumber *ok = [json[@"ok"] isKindOfClass:NSNumber.class] ? json[@"ok"] : @NO;
    NSNumber *enabled = [json[@"enabled"] isKindOfClass:NSNumber.class] ? json[@"enabled"] : @NO;
    NSNumber *listening = [json[@"listening"] isKindOfClass:NSNumber.class] ? json[@"listening"] : @NO;
    NSNumber *port = [json[@"port"] isKindOfClass:NSNumber.class] ? json[@"port"] : nil;
    NSString *endpoint = [json[@"session_endpoint"] isKindOfClass:NSString.class] ? json[@"session_endpoint"] : @"";
    NSString *sessionURL = [json[@"session_url"] isKindOfClass:NSString.class] ? json[@"session_url"] : @"";
    NSString *token = [json[@"session_token"] isKindOfClass:NSString.class] ? json[@"session_token"] : @"";
    NSString *clientUUID = [json[@"client_uuid"] isKindOfClass:NSString.class] ? json[@"client_uuid"] : @"";
    BOOL validToken = token.length >= 16 && token.length <= 256;
    BOOL validPort = port != nil && port.integerValue > 0 && port.integerValue <= 65535;
    // Current Foundation releases normally return an empty session_url and
    // require the client to build wss://host:port/session_endpoint. Accept
    // both forms; rejecting the empty form made the otherwise valid protocol
    // look unavailable.
    BOOL valid = ok.boolValue && enabled.boolValue && listening.boolValue && validPort &&
        endpoint.length > 0 && validToken && clientUUID.length > 0;
    result[@"ok"] = @(valid);
    result[@"enabled"] = enabled;
    result[@"listening"] = listening;
    result[@"reason"] = [json[@"error"] isKindOfClass:NSString.class] ? json[@"error"] : @"";
    if (valid) {
        result[@"port"] = port;
        result[@"session_endpoint"] = endpoint;
        result[@"session_url"] = sessionURL;
        result[@"session_token"] = token;
        result[@"client_uuid"] = clientUUID;
        result[@"features"] = [json[@"features"] isKindOfClass:NSArray.class] ? json[@"features"] : @[];
    }
    return result;
}

- (void)appendEncodedQueryParameter:(NSMutableString *)params key:(NSString *)key value:(NSString *)value {
    if (value.length == 0) {
        return;
    }

    NSCharacterSet *allowed = [NSCharacterSet URLQueryAllowedCharacterSet];
    NSString *encodedValue = [value stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    if (encodedValue.length == 0) {
        encodedValue = value;
    }

    [params appendFormat:@"&%@=%@", key, encodedValue];
}

- (void)appendSunshineFoundationParams:(NSMutableString *)extraParams
                                config:(StreamConfiguration *)config {
    if (config.sunshineTargetDisplayName.length > 0) {
        [self appendEncodedQueryParameter:extraParams
                                      key:@"display_name"
                                    value:config.sunshineTargetDisplayName];
    }

    if (config.sunshineUseVirtualDisplay) {
        [extraParams appendString:@"&useVdd=1"];
    }

    if (config.sunshineScreenMode >= 0) {
        [extraParams appendFormat:@"&customScreenMode=%d", config.sunshineScreenMode];
    }

    // Foundation Sunshine's per-client touch keyboard intent. Send an explicit
    // value so a host-side opt-in cannot override the user's client setting.
    [extraParams appendFormat:@"&touchKeyboard=%d", config.sunshineTouchKeyboardAutoInvoke ? 1 : 0];

    // Report all three luminance values or none: the host drops an incomplete
    // or inconsistent report and falls back to its safe defaults.
    const char *luminanceSource = "none";
    double maxNits = 0.0, minNits = 0.0, avgNits = 0.0;
    if (config.sunshineHdrBrightnessOverride) {
        luminanceSource = "override";
        maxNits = config.sunshineMaxBrightness;
        minNits = config.sunshineMinBrightness;
        avgNits = config.sunshineMaxAverageBrightness;
    } else if (config.enableHdr && config.hdrAutoLuminanceAvailable) {
        luminanceSource = "auto";
        maxNits = config.hdrAutoMaxBrightness;
        minNits = config.hdrAutoMinBrightness;
        avgNits = config.hdrAutoMaxAverageBrightness;
    }
    if (luminanceSource[0] != 'n') {
        // Mirrors the host's valid_luminance_values().
        BOOL valid = isfinite(maxNits) && isfinite(minNits) && isfinite(avgNits) &&
                     maxNits >= 1.0 && maxNits <= 10000.0 &&
                     minNits >= 0.0 && minNits <= 100.0 &&
                     avgNits >= 1.0 && avgNits <= maxNits && minNits <= avgNits;
        if (valid) {
            [extraParams appendFormat:@"&maxBrightness=%.3f", maxNits];
            [extraParams appendFormat:@"&minBrightness=%.6f", minNits];
            [extraParams appendFormat:@"&maxAverageBrightness=%.3f", avgNits];
        } else {
            Log(LOG_W, @"[hdr] Display luminance report rejected as invalid for the host: source=%s", luminanceSource);
            luminanceSource = "none";
        }
    }
    if (config.enableHdr || config.sunshineHdrBrightnessOverride) {
        Log(LOG_I, @"[hdr] display luminance report source=%s max=%.3f min=%.6f avg=%.3f",
            luminanceSource, maxNits, minNits, avgNits);
    }

    if (config.clientGamepad.length > 0) {
        [self appendEncodedQueryParameter:extraParams key:@"gamepad" value:config.clientGamepad];
    }
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
        }
    } @catch (NSException* exception) {
        // Best-effort only; keep defaults on any failure.
    }

    [self appendSunshineFoundationParams:extraParams config:config];

    // Ensure even dimensions (some encoders/decoders require this)
    modeWidth &= ~1;
    modeHeight &= ~1;
    
    // Using an FPS value over 60 causes SOPS to default to 720p60.
    // We used to set it to 60, but that stopped working in GFE 3.20.3.
    // Disabling SOPS allows the actual game frame rate to exceed 60.
    if (modeFps > 60) {
        sops = NO;
    }

    NSString* urlString = [NSString stringWithFormat:@"%@/launch?uniqueid=%@&appid=%@&mode=%dx%dx%d&additionalStates=1&sops=%d&rikey=%@&rikeyid=%d%@%@&localAudioPlayMode=%d&surroundAudioInfo=%u",
                           _baseHTTPSURL, _sharedStreamUniqueId,
                           config.appID,
                           modeWidth, modeHeight, modeFps,
                           sops ? 1 : 0,
                           [Utils bytesToHex:config.riKey], config.riKeyId,
                           config.enableHdr ? @"&hdrMode=1&clientHdrCapVersion=0&clientHdrCapSupportedFlagsInUint32=0&clientHdrCapMetaDataId=NV_STATIC_METADATA_TYPE_1&clientHdrCapDisplayData=0x0x0x0x0x0x0x0x0x0x0": @"",
                           extraParams,
                           config.playAudioOnPC ? 1 : 0,
                           (unsigned int)SURROUNDAUDIOINFO_FROM_AUDIO_CONFIGURATION(config.audioConfiguration)];
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
        }
    } @catch (NSException* exception) {
    }

    [self appendSunshineFoundationParams:extraParams config:config];

    modeWidth &= ~1;
    modeHeight &= ~1;
    
    // Using an FPS value over 60 causes SOPS to default to 720p60.
    // We used to set it to 60, but that stopped working in GFE 3.20.3.
    // Disabling SOPS allows the actual game frame rate to exceed 60.
    if (modeFps > 60) {
        sops = NO;
    }

    NSString* urlString = [NSString stringWithFormat:@"%@/resume?uniqueid=%@&appid=%@&mode=%dx%dx%d&additionalStates=1&sops=%d&rikey=%@&rikeyid=%d%@%@&localAudioPlayMode=%d&surroundAudioInfo=%u",
                           _baseHTTPSURL, _sharedStreamUniqueId,
                           config.appID,
                           modeWidth, modeHeight, modeFps,
                           sops ? 1 : 0,
                           [Utils bytesToHex:config.riKey], config.riKeyId,
                           config.enableHdr ? @"&hdrMode=1&clientHdrCapVersion=0&clientHdrCapSupportedFlagsInUint32=0&clientHdrCapMetaDataId=NV_STATIC_METADATA_TYPE_1&clientHdrCapDisplayData=0x0x0x0x0x0x0x0x0x0x0": @"",
                           extraParams,
                           config.playAudioOnPC ? 1 : 0,
                           (unsigned int)SURROUNDAUDIOINFO_FROM_AUDIO_CONFIGURATION(config.audioConfiguration)];
    Log(LOG_I, @"Requesting: %@", urlString);
    // This blocks while the app is resuming
    return [self createRequestFromString:urlString timeout:LONG_TIMEOUT_SEC];
}

- (NSURLRequest*) newQuitAppRequest {
    NSString* urlString = [NSString stringWithFormat:@"%@/cancel?uniqueid=%@", _baseHTTPSURL, _sharedStreamUniqueId];
    return [self createRequestFromString:urlString timeout:LONG_TIMEOUT_SEC];
}

// Runs one of the running app's menu commands (SuperCmds from /applist). The host
// resolves the id against the currently running app only.
- (NSURLRequest*) newSuperCommandRequestWithId:(NSString*)commandId {
    // '&', '+' and '=' are legal in a query component but would split or alter the value.
    NSMutableCharacterSet* allowed = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
    [allowed removeCharactersInString:@"&+=#"];
    NSString* encodedId = [commandId stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
    NSString* urlString = [NSString stringWithFormat:@"%@/supercmd?uniqueid=%@&cmdId=%@", _baseHTTPSURL, _clientUniqueId, encodedId];
    return [self createRequestFromString:urlString timeout:NORMAL_TIMEOUT_SEC];
}

// The host answers only after it resumes from sleep (SetSuspendState blocks), so
// callers must treat a transport timeout as "command delivered".
- (NSURLRequest*) newPcSleepRequest {
    NSString* urlString = [NSString stringWithFormat:@"%@/pcsleep?uniqueid=%@", _baseHTTPSURL, _clientUniqueId];
    return [self createRequestFromString:urlString timeout:NORMAL_TIMEOUT_SEC];
}

- (BOOL) executeSuperCommandWithId:(NSString*)commandId {
    HttpResponse* response = [[HttpResponse alloc] init];
    [self executeRequestSynchronously:[HttpRequest requestForResponse:response withUrlRequest:[self newSuperCommandRequestWithId:commandId]]];
    NSInteger accepted = 0;
    BOOL ok = [response isStatusOk] && [response getIntTag:@"supercmd" value:&accepted] && accepted != 0;
    Log(ok ? LOG_I : LOG_W, @"[supercmd] id=%@ status=%ld accepted=%ld", commandId, (long)response.statusCode, (long)accepted);
    return ok;
}

- (BOOL) requestHostSleep {
    HttpResponse* response = [[HttpResponse alloc] init];
    [self executeRequestSynchronously:[HttpRequest requestForResponse:response withUrlRequest:[self newPcSleepRequest]]];
    NSInteger sleeping = 0;
    BOOL answered = [response isStatusOk] && [response getIntTag:@"pcsleep" value:&sleeping];
    // A host that suspends mid-request never answers; a timeout or dropped
    // connection means the command was most likely delivered.
    BOOL transportError = response.statusCode == NSURLErrorTimedOut ||
                          response.statusCode == NSURLErrorNetworkConnectionLost;
    BOOL ok = answered ? sleeping != 0 : transportError;
    Log(ok ? LOG_I : LOG_W, @"[pcsleep] status=%ld answered=%d sleeping=%ld", (long)response.statusCode, answered, (long)sleeping);
    return ok;
}

#pragma mark - Foundation Sunshine ABR and bandwidth probe

- (NSURLSession*) sunshineAPISession {
    @synchronized (self) {
        if (_apiSession == nil) {
            NSURLSessionConfiguration* config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
            _apiSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
        }
        return _apiSession;
    }
}

- (void) invalidateSunshineAPISession {
    NSURLSession* session = nil;
    @synchronized (self) {
        session = _apiSession;
        _apiSession = nil;
    }
    [session finishTasksAndInvalidate];
}

- (NSDictionary<NSString*, id>*) sunshineAPIRequestWithPath:(NSString*)path
                                                     method:(NSString*)method
                                                       body:(NSDictionary<NSString*, id>*)body
                                                    timeout:(NSTimeInterval)timeout
                                                 httpStatus:(NSInteger*)httpStatus {
    NSString* urlString = [NSString stringWithFormat:@"%@%@", _baseHTTPSURL, path];
    NSMutableURLRequest* request = [[self createRequestFromString:urlString timeout:(int)timeout] mutableCopy];
    request.HTTPMethod = method;
    if (body != nil) {
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }

    __block NSData* respData = nil;
    __block NSInteger status = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURLSessionDataTask* task = [[self sunshineAPISession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        if (error != nil) {
            status = error.code < 0 ? error.code : -error.code;
        } else {
            status = [(NSHTTPURLResponse*)response statusCode];
            respData = data;
        }
        dispatch_semaphore_signal(done);
    }];
    [task resume];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 2.0) * NSEC_PER_SEC))) != 0) {
        [task cancel];
        status = NSURLErrorTimedOut;
    }

    if (httpStatus != NULL) {
        *httpStatus = status;
    }
    id object = respData.length > 0 ? [NSJSONSerialization JSONObjectWithData:respData options:0 error:nil] : nil;
    return [object isKindOfClass:[NSDictionary class]] ? object : @{};
}

// Query component for the display scale routes. Device ids contain characters such as
// backslash, question mark, hash and braces, so everything outside the unreserved set is escaped.
static NSString* ScaleQueryValue(NSString* value) {
    static NSCharacterSet* allowed = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = [NSCharacterSet characterSetWithCharactersInString:
                   @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    });
    return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

- (NSDictionary<NSString*, id>*) fetchRemoteDisplayScaleOptionsForDisplayName:(NSString*)displayName
                                                                      deviceId:(NSString*)deviceId
                                                                    httpStatus:(NSInteger*)httpStatus {
    NSMutableArray<NSString*>* query = [NSMutableArray array];
    if (displayName.length > 0) {
        [query addObject:[@"display_name=" stringByAppendingString:ScaleQueryValue(displayName)]];
    }
    if (deviceId.length > 0) {
        [query addObject:[@"device_id=" stringByAppendingString:ScaleQueryValue(deviceId)]];
    }
    NSString* path = @"/display-scale-options";
    if (query.count > 0) {
        path = [path stringByAppendingFormat:@"?%@", [query componentsJoinedByString:@"&"]];
    }
    return [self sunshineAPIRequestWithPath:path method:@"GET" body:nil timeout:3 httpStatus:httpStatus];
}

- (NSDictionary<NSString*, id>*) setRemoteDisplayScalePercent:(NSInteger)percent
                                                   displayName:(NSString*)displayName
                                                      deviceId:(NSString*)deviceId
                                                    httpStatus:(NSInteger*)httpStatus {
    NSMutableDictionary<NSString*, id>* body = [@{ @"scale_percent": @(percent) } mutableCopy];
    if (displayName.length > 0) {
        body[@"display_name"] = displayName;
    }
    if (deviceId.length > 0) {
        body[@"device_id"] = deviceId;
    }
    return [self sunshineAPIRequestWithPath:@"/display-scale" method:@"POST" body:body timeout:3 httpStatus:httpStatus];
}

static NSString* ProbeErrorReason(NSInteger status, NSDictionary* json) {
    NSString* reason = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : nil;
    if (reason.length > 0) {
        return reason;
    }
    return status == 404 ? @"unsupported" : [NSString stringWithFormat:@"http_%ld", (long)status];
}

- (NSDictionary<NSString*, id>*) runSunshineBandwidthProbe {
    static const uint64_t kMaxProbeBytes = 4ull * 1024 * 1024;
    static const int kLatencySamples = 4;

    MLSunshineProbeCollector* collector = [[MLSunshineProbeCollector alloc] init];
    collector.manager = self;
    NSURLSessionConfiguration* config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = NORMAL_TIMEOUT_SEC;
    NSURLSession* session = [NSURLSession sessionWithConfiguration:config delegate:collector delegateQueue:nil];

    NSDictionary* (^fail)(NSString*, NSInteger) = ^NSDictionary*(NSString* reason, NSInteger retryAfterMs) {
        [session invalidateAndCancel];
        return @{ @"ok": @NO, @"error": reason ?: @"failed", @"retryAfterMs": @(retryAfterMs) };
    };

    // Round-trip samples against the capabilities endpoint; the first one pays for
    // the TLS handshake and is dropped from the latency estimate.
    NSMutableArray<NSNumber*>* latencies = [NSMutableArray array];
    uint64_t minBytes = 0, maxBytes = 0;
    NSURL* capsURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/network/capabilities", _baseHTTPSURL]];
    for (int i = 0; i < kLatencySamples; i++) {
        __block NSData* body = nil;
        __block NSInteger status = 0;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        uint64_t startNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        NSURLRequest* request = [NSURLRequest requestWithURL:capsURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:NORMAL_TIMEOUT_SEC];
        [[session dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
            status = error != nil ? -1 : [(NSHTTPURLResponse*)response statusCode];
            body = data;
            dispatch_semaphore_signal(done);
        }] resume];
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((NORMAL_TIMEOUT_SEC + 2) * NSEC_PER_SEC))) != 0) {
            return fail(@"timeout", 0);
        }
        double elapsedMs = (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - startNs) / 1e6;

        id json = body.length > 0 ? [NSJSONSerialization JSONObjectWithData:body options:0 error:nil] : nil;
        NSDictionary* root = [json isKindOfClass:[NSDictionary class]] ? json : @{};
        if (status != 200) {
            return fail(status < 0 ? @"network_error" : ProbeErrorReason(status, root), 0);
        }
        if (i == 0) {
            NSDictionary* probe = [root[@"bandwidthProbe"] isKindOfClass:[NSDictionary class]] ? root[@"bandwidthProbe"] : nil;
            if ([root[@"version"] integerValue] < 1 || [probe[@"version"] integerValue] < 1) {
                return fail(@"unsupported_version", 0);
            }
            minBytes = [probe[@"minBytes"] unsignedLongLongValue];
            maxBytes = [probe[@"maxBytes"] unsignedLongLongValue];
            if (![probe[@"endpoint"] isEqualToString:@"/api/network/probe"] || minBytes == 0 || maxBytes < minBytes || minBytes > kMaxProbeBytes) {
                return fail(@"invalid_capabilities", 0);
            }
        }
        [latencies addObject:@(elapsedMs)];
    }

    NSArray<NSNumber*>* steady = latencies.count > 1 ? [latencies subarrayWithRange:NSMakeRange(1, latencies.count - 1)] : latencies;
    double latencySum = 0, jitterSum = 0;
    for (NSUInteger i = 0; i < steady.count; i++) {
        latencySum += steady[i].doubleValue;
        if (i > 0) {
            jitterSum += fabs(steady[i].doubleValue - steady[i - 1].doubleValue);
        }
    }
    double latencyMs = latencySum / steady.count;
    double jitterMs = steady.count > 1 ? jitterSum / (steady.count - 1) : 0;

    uint64_t sampleBytes = MIN(maxBytes, kMaxProbeBytes);
    NSString* nonce = [[NSUUID UUID] UUIDString];
    collector.expectedNonce = nonce;
    NSURL* probeURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/network/probe?bytes=%llu&nonce=%@", _baseHTTPSURL, sampleBytes, nonce]];
    NSURLRequest* probeRequest = [NSURLRequest requestWithURL:probeURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:NORMAL_TIMEOUT_SEC];
    [[session dataTaskWithRequest:probeRequest] resume];
    // The host aborts transfers after 3 s; leave generous slack for slow links.
    if (dispatch_semaphore_wait(collector.done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC))) != 0) {
        return fail(@"timeout", 0);
    }
    [session finishTasksAndInvalidate];

    if (collector.failure != nil) {
        return fail(collector.failure, 0);
    }
    if (collector.statusCode != 200) {
        id json = collector.errorBody.length > 0 ? [NSJSONSerialization JSONObjectWithData:collector.errorBody options:0 error:nil] : nil;
        NSDictionary* root = [json isKindOfClass:[NSDictionary class]] ? json : @{};
        return fail(collector.statusCode == 0 ? @"network_error" : ProbeErrorReason(collector.statusCode, root),
                    [root[@"retryAfterMs"] integerValue]);
    }

    double seconds = collector.endNs > collector.startNs ? (double)(collector.endNs - collector.startNs) / 1e9 : 0;
    BOOL complete = collector.receivedBytes == sampleBytes;
    // A transfer the host cut short still yields a usable lower bound.
    if (seconds <= 0 || collector.receivedBytes < minBytes) {
        return fail(complete ? @"invalid_duration" : @"incomplete_response", 0);
    }

    return @{
        @"ok": @YES,
        @"partial": @(!complete),
        @"bandwidthMbps": @((double)collector.receivedBytes * 8.0 / seconds / 1e6),
        @"latencyMs": @(latencyMs),
        @"jitterMs": @(jitterMs),
        @"bytes": @(collector.receivedBytes),
    };
}

- (NSURLRequest*) newAppAssetRequestWithAppId:(NSString *)appId {
    NSString* urlString = [NSString stringWithFormat:@"%@/appasset?uniqueid=%@&appid=%@&AssetType=2&AssetIdx=0", _baseHTTPSURL, _clientUniqueId, appId];
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

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (void)ensureKeychainUnlocked:(SecKeychainRef)keychain context:(NSString *)context {
    if (keychain == NULL) {
        return;
    }

    OSStatus unlockStatus = SecKeychainUnlock(keychain,
                                              (UInt32)strlen(kTempKeychainPassword),
                                              kTempKeychainPassword,
                                              TRUE);
    if (unlockStatus != errSecSuccess) {
        Log(LOG_W, @"Failed to unlock keychain (%@): %d", context ?: @"", (int)unlockStatus);
    }
}

- (void)ensureIdentityKeychainUnlocked:(SecIdentityRef)identity context:(NSString *)context {
    // Prefer unlocking our known temporary keychain first to avoid
    // triggering an implicit keychain lookup prompt via identity APIs.
    [self ensureKeychainUnlocked:gTempClientKeychain context:context];

    if (identity == NULL) {
        return;
    }

    SecKeyRef privateKey = NULL;
    if (SecIdentityCopyPrivateKey(identity, &privateKey) != errSecSuccess || privateKey == NULL) {
        return;
    }

    SecKeychainRef keychain = NULL;
    OSStatus keychainStatus = SecKeychainItemCopyKeychain((SecKeychainItemRef)privateKey, &keychain);
    if (keychainStatus == errSecSuccess && keychain != NULL) {
        BOOL shouldUnlock = NO;
        if (gTempClientKeychain != NULL && CFEqual(keychain, gTempClientKeychain)) {
            shouldUnlock = YES;
        } else {
            char kcPath[1024];
            UInt32 kcPathLen = sizeof(kcPath);
            if (SecKeychainGetPath(keychain, &kcPathLen, kcPath) == errSecSuccess) {
                NSString *kcPathStr = [[NSString alloc] initWithBytes:kcPath length:kcPathLen encoding:NSUTF8StringEncoding];
                shouldUnlock = [self isMoonlightManagedKeychainPath:kcPathStr];
            }
        }

        // Never unlock unknown/system keychains. That can trigger password prompts.
        if (shouldUnlock) {
            [self ensureKeychainUnlocked:keychain context:context];
        } else {
            Log(LOG_W, @"Skipping unlock for unmanaged identity keychain to avoid password prompt");
        }
        CFRelease(keychain);
    }
    CFRelease(privateKey);
}

- (BOOL)isMoonlightManagedKeychainPath:(NSString *)path {
    if (path.length == 0) {
        return NO;
    }

    NSString *name = path.lastPathComponent.lowercaseString;
    if ([name isEqualToString:@"moonlight"]) {
        return YES;
    }
    if ([name isEqualToString:@"moonlight.keychain"] ||
        [name isEqualToString:@"moonlight.keychain-db"]) {
        return YES;
    }
    if ([name hasPrefix:@"moonlight-client-"] &&
        ([name hasSuffix:@".keychain"] || [name hasSuffix:@".keychain-db"])) {
        return YES;
    }
    if ([name hasPrefix:@"moonlight"] && [name containsString:@"keychain"]) {
        return YES;
    }
    return NO;
}

- (void)removeKeychainFileIfExists:(NSString *)path {
    if (path.length == 0) {
        return;
    }
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

- (void)cleanupLegacyMoonlightKeychainFiles {
    NSFileManager *fm = [NSFileManager defaultManager];

    // Legacy fixed paths used by previous versions.
    NSArray *docPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (docPaths.count > 0) {
        NSString *documentsDir = [docPaths objectAtIndex:0];
        [self removeKeychainFileIfExists:[documentsDir stringByAppendingPathComponent:@"moonlight.keychain"]];
        [self removeKeychainFileIfExists:[documentsDir stringByAppendingPathComponent:@"moonlight.keychain-db"]];
    }

    // Best-effort cleanup for prior randomized temp keychains from older runs.
    NSString *tmpDir = NSTemporaryDirectory();
    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:tmpDir error:nil] ?: @[];
    for (NSString *name in files) {
        if ([self isMoonlightManagedKeychainPath:name]) {
            NSString *fullPath = [tmpDir stringByAppendingPathComponent:name];
            [self removeKeychainFileIfExists:fullPath];
        }
    }

    // Older builds may have created moonlight keychains under ~/Library/Keychains.
    NSArray *libraryPaths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    if (libraryPaths.count > 0) {
        NSString *libraryDir = [libraryPaths objectAtIndex:0];
        NSString *keychainsDir = [libraryDir stringByAppendingPathComponent:@"Keychains"];
        [self removeKeychainFileIfExists:[keychainsDir stringByAppendingPathComponent:@"moonlight.keychain"]];
        [self removeKeychainFileIfExists:[keychainsDir stringByAppendingPathComponent:@"moonlight.keychain-db"]];

        NSArray<NSString *> *keychainFiles = [fm contentsOfDirectoryAtPath:keychainsDir error:nil] ?: @[];
        for (NSString *name in keychainFiles) {
            if ([self isMoonlightManagedKeychainPath:name]) {
                NSString *fullPath = [keychainsDir stringByAppendingPathComponent:name];
                [self removeKeychainFileIfExists:fullPath];
            }
        }
    }
}

- (NSString *)newEphemeralMoonlightKeychainPath {
    NSString *uuid = [[NSUUID UUID] UUIDString].lowercaseString;
    NSString *fileName = [NSString stringWithFormat:@"moonlight-client-%@.keychain-db", uuid];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
}

- (void)removeLegacyMoonlightKeychainFromSearchList {
    CFArrayRef currentSearchList = NULL;
    SecKeychainCopySearchList(&currentSearchList);
    if (!currentSearchList) {
        return;
    }

    NSMutableArray *cleanedList = [NSMutableArray array];
    BOOL dirty = NO;
    for (CFIndex i = 0; i < CFArrayGetCount(currentSearchList); i++) {
        SecKeychainRef kc = (SecKeychainRef)CFArrayGetValueAtIndex(currentSearchList, i);
        char kcPath[1024];
        UInt32 kcPathLen = sizeof(kcPath);
        if (SecKeychainGetPath(kc, &kcPathLen, kcPath) == errSecSuccess) {
            NSString *kcPathStr = [[NSString alloc] initWithBytes:kcPath length:kcPathLen encoding:NSUTF8StringEncoding];
            if ([self isMoonlightManagedKeychainPath:kcPathStr]) {
                dirty = YES;
                continue;
            }
        }
        [cleanedList addObject:(__bridge id)kc];
    }

    if (dirty) {
        SecKeychainSetSearchList((__bridge CFArrayRef)cleanedList);
        Log(LOG_I, @"Removed leftover moonlight keychain entries from system search list");
    }

    CFRelease(currentSearchList);
}
#pragma clang diagnostic pop

// Fallback: import PKCS12 into a temporary file-based keychain.
// This bypasses the default Data Protection keychain which may require
// entitlements not available to the app (-34018 errSecMissingEntitlement).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (SecIdentityRef)importP12ViaTemporaryKeychain:(NSData *)p12Obj status:(OSStatus *)statusOut {
    if (statusOut != NULL) {
        *statusOut = errSecSuccess;
    }
    [self cleanupLegacyMoonlightKeychainFiles];
    NSString *keychainPath = [self newEphemeralMoonlightKeychainPath];
    const char *cPath = keychainPath.UTF8String;

    // Clean up previous keychain to avoid stale key material
    if (gTempClientKeychain) {
        char oldPath[1024];
        UInt32 oldPathLen = sizeof(oldPath);
        NSString *oldPathStr = nil;
        if (SecKeychainGetPath(gTempClientKeychain, &oldPathLen, oldPath) == errSecSuccess) {
            oldPathStr = [[NSString alloc] initWithBytes:oldPath length:oldPathLen encoding:NSUTF8StringEncoding];
        }
        SecKeychainDelete(gTempClientKeychain);
        CFRelease(gTempClientKeychain);
        gTempClientKeychain = NULL;
        if (oldPathStr.length > 0) {
            [self removeKeychainFileIfExists:oldPathStr];
        }
    }
    if (gTempClientKeychainPath.length > 0) {
        [self removeKeychainFileIfExists:gTempClientKeychainPath];
        gTempClientKeychainPath = nil;
    }
    [self removeKeychainFileIfExists:keychainPath];

    // Remove any leftover moonlight.keychain from the system search list.
    // Previous versions (or previous runs) may have added it, causing macOS
    // to prompt "wants to use moonlight's keychain" when the keychain is locked.
    [self removeLegacyMoonlightKeychainFromSearchList];

    OSStatus status = SecKeychainCreate(cPath, (UInt32)strlen(kTempKeychainPassword), kTempKeychainPassword, FALSE, NULL, &gTempClientKeychain);
    if (status != errSecSuccess) {
        Log(LOG_E, @"Temp keychain fallback: creation failed (%d)", (int)status);
        gTempClientKeychain = NULL;
        if (statusOut != NULL) {
            *statusOut = status;
        }
        return nil;
    }
    gTempClientKeychainPath = keychainPath;

    // Keep this keychain unlocked so TLS private-key operations don't trigger UI prompts.
    SecKeychainSettings settings;
    memset(&settings, 0, sizeof(settings));
    settings.version = SEC_KEYCHAIN_SETTINGS_VERS1;
    settings.lockOnSleep = FALSE;
    settings.useLockInterval = FALSE;
    OSStatus settingsStatus = SecKeychainSetSettings(gTempClientKeychain, &settings);
    if (settingsStatus != errSecSuccess) {
        Log(LOG_W, @"Temp keychain fallback: failed to set keychain settings (%d)", (int)settingsStatus);
    }
    [self ensureKeychainUnlocked:gTempClientKeychain context:@"temp-keychain-create"];

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
                if ([self isMoonlightManagedKeychainPath:kcPathStr]) {
                    continue;
                }
            }
            [filteredList addObject:(__bridge id)kc];
        }
        SecKeychainSetSearchList((__bridge CFArrayRef)filteredList);
        CFRelease(postCreateList);
    }

    const void *optKeys[] = { kSecImportExportPassphrase, kSecImportExportKeychain };
    const void *optValues[] = { CFSTR("limelight"), gTempClientKeychain };
    CFDictionaryRef options = CFDictionaryCreate(NULL, optKeys, optValues, 2, NULL, NULL);

    CFArrayRef items = NULL;
    OSStatus importStatus = SecPKCS12Import((__bridge CFDataRef)p12Obj, options, &items);
    if (statusOut != NULL) {
        *statusOut = importStatus;
    }
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
        [self ensureIdentityKeychainUnlocked:identity context:@"temp-keychain-import"];
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
        // Clean legacy search list entries before any PKCS12 import attempt.
        // This prevents old locked moonlight keychains from triggering UI prompts.
        [self removeLegacyMoonlightKeychainFromSearchList];

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
            [self ensureIdentityKeychainUnlocked:cachedIdentity context:@"cached-identity"];
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

            OSStatus importStatus = errSecSuccess;
            CFDataRef p12Data = (__bridge CFDataRef)p12Obj;

            // 1) Prefer memory-only import to avoid any keychain access/prompt.
            CFStringRef memOnlyKey = GetImportToMemoryOnlyKey();
            if (memOnlyKey != NULL) {
                const void *memKeys[] = { kSecImportExportPassphrase, memOnlyKey };
                const void *memValues[] = { CFSTR("limelight"), kCFBooleanTrue };
                CFDictionaryRef memOptions = CFDictionaryCreate(NULL, memKeys, memValues, 2, NULL, NULL);
                CFArrayRef memItems = NULL;
                importStatus = SecPKCS12Import(p12Data, memOptions, &memItems);
                CFRelease(memOptions);

                if (importStatus == errSecSuccess && memItems != NULL) {
                    for (CFIndex i = 0; i < CFArrayGetCount(memItems); i++) {
                        CFDictionaryRef dict = CFArrayGetValueAtIndex(memItems, i);
                        SecIdentityRef candidate = (SecIdentityRef)CFDictionaryGetValue(dict, kSecImportItemIdentity);
                        if (candidate != NULL) {
                            identityApp = candidate;
                            CFRetain(identityApp);
                            Log(LOG_I, @"Client certificate imported in memory without keychain access");
                            break;
                        }
                    }
                }
                if (memItems != NULL) {
                    CFRelease(memItems);
                }
            }

            // 2) If memory-only import is unavailable/failed, try default import semantics.
            if (identityApp == nil) {
                const void *keys[] = { kSecImportExportPassphrase };
                const void *values[] = { CFSTR("limelight") };
                CFDictionaryRef options = CFDictionaryCreate(NULL, keys, values, 1, NULL, NULL);
                CFArrayRef items = NULL;
                importStatus = SecPKCS12Import(p12Data, options, &items);
                CFRelease(options);

                if (importStatus == errSecSuccess && items != NULL) {
                    for (CFIndex i = 0; i < CFArrayGetCount(items); i++) {
                        CFDictionaryRef dict = CFArrayGetValueAtIndex(items, i);
                        SecIdentityRef candidate = (SecIdentityRef)CFDictionaryGetValue(dict, kSecImportItemIdentity);
                        if (candidate != NULL) {
                            identityApp = candidate;
                            CFRetain(identityApp);
                            Log(LOG_I, @"Client certificate imported with default PKCS12 import path");
                            break;
                        }
                    }
                }
                if (items != NULL) {
                    CFRelease(items);
                }
            }

            // 3) Last resort: controlled temporary keychain import.
            if (identityApp == nil) {
                identityApp = [self importP12ViaTemporaryKeychain:p12Obj status:&importStatus];
            }
            if (identityApp == nil) {
                if (attempt == 0) {
                    // If files are missing OR PKCS12 is unreadable (bad password/corrupt),
                    // regenerate to recover from a stuck cert state.
                    BOOL missingFiles = ![CryptoManager keyPairExists];
                    BOOL unreadableP12 = (importStatus == errSecAuthFailed ||
                                          importStatus == errSecDecode ||
                                          importStatus == kErrSecPkcs12VerifyFailure);
                    if (missingFiles || unreadableP12) {
                        Log(LOG_W, @"Client certificate import failed (status=%d), regenerating certificates", (int)importStatus);
                        [CryptoManager regenerateKeyPairUsingSSL];
                    } else {
                        Log(LOG_E, @"Client certificate import failed (status=%d) with existing cert files intact; skipping regeneration", (int)importStatus);
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
        // Never allow Security.framework to show keychain UI here.
        // Any unexpected keychain access should fail fast instead of prompting.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        SecKeychainSetUserInteractionAllowed(FALSE);
#pragma clang diagnostic pop
        SecIdentityRef identity = [self getClientCertificate];
        if (identity == nil) {
            Log(LOG_E, @"No client certificate identity available for TLS client auth challenge");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            SecKeychainSetUserInteractionAllowed(TRUE);
#pragma clang diagnostic pop
            completionHandler(NSURLSessionAuthChallengeRejectProtectionSpace, NULL);
            return;
        }
        [self ensureIdentityKeychainUnlocked:identity context:@"client-cert-challenge"];
        NSArray* certArray = [self getCertificate:identity];
        // Use ForSession persistence to avoid macOS prompting for keychain password.
        // We manage identity caching ourselves in getClientCertificate.
        NSURLCredential* newCredential = [NSURLCredential credentialWithIdentity:identity certificates:certArray persistence:NSURLCredentialPersistenceForSession];
        completionHandler(NSURLSessionAuthChallengeUseCredential, newCredential);
        if (identity != nil) {
            CFRelease(identity);
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        SecKeychainSetUserInteractionAllowed(TRUE);
#pragma clang diagnostic pop
    }
    else
    {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, NULL);
    }
}

@end
