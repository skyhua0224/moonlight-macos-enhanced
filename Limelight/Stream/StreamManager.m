//
//  StreamManager.m
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "StreamManager.h"
#import "CryptoManager.h"
#import "HttpManager.h"
#import "Utils.h"

#import "StreamView.h"
#import "ServerInfoResponse.h"
#import "HttpResponse.h"
#import "HttpRequest.h"
#import "IdManager.h"
#include "Limelight.h"

@implementation StreamManager {
    StreamConfiguration* _config;

    OSView* _renderView;
    id<ConnectionCallbacks> _callbacks;
    Connection* _connection;
    NSOperationQueue* _connectionQueue;
    VideoDecoderRenderer* _renderer;
}

@synthesize connection = _connection;

- (StreamConfiguration *)streamConfiguration {
    return _config;
}

- (id) initWithConfig:(StreamConfiguration*)config renderView:(OSView*)view connectionCallbacks:(id<ConnectionCallbacks>)callbacks {
    self = [super init];
    _config = config;
    _renderView = view;
    _callbacks = callbacks;
    _config.riKey = [Utils randomBytes:16];
    _config.riKeyId = arc4random();
    return self;
}

- (void)main {
    const uint64_t startupStartMs = LiGetMillis();
    __block uint64_t rendererWarmupScheduledMs = 0;
    __block uint64_t rendererWarmupFinishedMs = 0;

    if (_config != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.isCancelled || self->_callbacks == nil) {
                return;
            }

            rendererWarmupScheduledMs = LiGetMillis();
            if (self->_renderer == nil) {
                self->_renderer = [[VideoDecoderRenderer alloc] initWithView:self->_renderView];
            }
            [self->_renderer prewarmPresentationForStreamConfig:self->_config];
            rendererWarmupFinishedMs = LiGetMillis();
            Log(LOG_I, @"[startup] Renderer warmup total=%llums",
                (unsigned long long)(rendererWarmupFinishedMs - rendererWarmupScheduledMs));
        });
    }

    const uint64_t cryptoStartMs = LiGetMillis();
    [CryptoManager generateKeyPairUsingSSL];
    const uint64_t cryptoEndMs = LiGetMillis();
    NSString* uniqueId = [IdManager getUniqueId];
    
    HttpManager* hMan = [[HttpManager alloc] initWithHost:_config.host
                                                 uniqueId:uniqueId
                                                     serverCert:_config.serverCert];
    
    const uint64_t serverInfoStartMs = LiGetMillis();
    ServerInfoResponse* serverInfoResp = [[ServerInfoResponse alloc] init];
    [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp withUrlRequest:[hMan newServerInfoRequest:false]
                                       fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
    const uint64_t serverInfoEndMs = LiGetMillis();
    if (self.isCancelled || _callbacks == nil) {
        return;
    }
    NSString* pairStatus = [serverInfoResp getStringTag:@"PairStatus"];
    NSString* appversion = [serverInfoResp getStringTag:@"appversion"];
    NSString* gfeVersion = [serverInfoResp getStringTag:@"GfeVersion"];
    NSString* serverState = [serverInfoResp getStringTag:@"state"];
    if (![serverInfoResp isStatusOk]) {
        [_callbacks launchFailed:serverInfoResp.statusMessage];
        return;
    }
    else if (pairStatus == NULL || appversion == NULL || serverState == NULL) {
        [_callbacks launchFailed:@"Failed to connect to PC"];
        return;
    }
    
    if (![pairStatus isEqualToString:@"1"]) {
        // Not paired
        [_callbacks launchFailed:@"Device not paired to PC"];
        return;
    }
    
    // A previous run may have been killed before it put the host display scale back. The restore
    // runs in the background (the stream does not wait for it) and ahead of any new scale change.
    [MLRemoteDisplayScale recoverPendingRestoreForHostUUID:_config.hostUUID
                                               hostAddress:_config.host
                                                serverCert:_config.serverCert];

    if (_config.enableAdaptiveBitrate) {
        // The host refuses the probe once a video session exists, so it must precede launch/resume.
        [self applyBandwidthProbe:hMan];
        if (self.isCancelled || _callbacks == nil) {
            return;
        }
    }

    // resumeApp and launchApp handle calling launchFailed
    const uint64_t hostLaunchStartMs = LiGetMillis();
    if ([serverState hasSuffix:@"_SERVER_BUSY"]) {
        // App already running, resume it
        if (![self resumeApp:hMan]) {
            return;
        }
    } else {
        // Start app
        if (![self launchApp:hMan]) {
            return;
        }
    }
    const uint64_t hostLaunchEndMs = LiGetMillis();
    if (self.isCancelled || _callbacks == nil) {
        return;
    }
    
#if TARGET_OS_IPHONE
    // Set mouse delta factors from the screen resolution and stream size
    CGFloat screenScale = [[UIScreen mainScreen] scale];
    CGRect screenBounds = [[UIScreen mainScreen] bounds];
    CGSize screenSize = CGSizeMake(screenBounds.size.width * screenScale, screenBounds.size.height * screenScale);
    [((StreamView*)_renderView) setMouseDeltaFactors:_config.width / screenSize.width
                                                   y:_config.height / screenSize.height];
#endif
    
    // Populate the config's version fields from serverinfo
    _config.appVersion = appversion;
    _config.gfeVersion = gfeVersion;
    // VddCapabilityVersion only exists in Foundation Sunshine serverinfo. Runtime
    // stream changes (0x5506) are a Foundation protocol extension.
    _config.foundationHost = [serverInfoResp getStringTag:@"VddCapabilityVersion"] != nil;
    Log(LOG_I, @"[live] Foundation host=%d", _config.foundationHost ? 1 : 0);
    Log(LOG_I, @"[startup] Network prep crypto=%llums serverInfo=%llums hostLaunch=%llums total=%llums",
        (unsigned long long)(cryptoEndMs - cryptoStartMs),
        (unsigned long long)(serverInfoEndMs - serverInfoStartMs),
        (unsigned long long)(hostLaunchEndMs - hostLaunchStartMs),
        (unsigned long long)(hostLaunchEndMs - startupStartMs));
    
    // Initializing the renderer must be done on the main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.isCancelled || self->_callbacks == nil) {
            return;
        }

        uint64_t mainBindStartMs = LiGetMillis();
        if (self->_renderer == nil) {
            self->_renderer = [[VideoDecoderRenderer alloc] initWithView:self->_renderView];
            [self->_renderer prewarmPresentationForStreamConfig:self->_config];
            rendererWarmupFinishedMs = LiGetMillis();
        }

        self->_connection = [[Connection alloc] initWithConfig:self->_config renderer:self->_renderer connectionCallbacks:self->_callbacks];
        if (self.isCancelled || self->_callbacks == nil) {
            self->_connection = nil;
            return;
        }

        [self->_connectionQueue cancelAllOperations];
        self->_connectionQueue = [[NSOperationQueue alloc] init];
        self->_connectionQueue.maxConcurrentOperationCount = 1;
        [self->_connectionQueue addOperation:self->_connection];
        Log(LOG_I, @"[startup] Main bind rendererWarmupQueued=%llums rendererWarmupReady=%llums connectionQueue=%llums total=%llums",
            rendererWarmupScheduledMs != 0 ? (unsigned long long)(rendererWarmupScheduledMs - startupStartMs) : 0,
            rendererWarmupFinishedMs != 0 ? (unsigned long long)(rendererWarmupFinishedMs - startupStartMs) : 0,
            (unsigned long long)(LiGetMillis() - mainBindStartMs),
            (unsigned long long)(LiGetMillis() - startupStartMs));
    });
}

- (void) stopStream
{
    [self cancel];
    [_connectionQueue cancelAllOperations];
    _connectionQueue = nil;
    [_connection terminate];
    _callbacks = nil;
}

// Fraction of the measured throughput treated as sustainable for a video stream.
static const double kProbeSafeBandwidthFraction = 0.65;
static const int kProbeMaxBitrateKbps = 150000;
static const int kProbeBitrateStepKbps = 500;
// Only intervene when the configured bitrate clearly exceeds what the link carried.
static const double kProbeCapTolerance = 1.15;

- (void) applyBandwidthProbe:(HttpManager*)hMan {
    const uint64_t probeStartMs = LiGetMillis();
    NSDictionary* result = [hMan runSunshineBandwidthProbe];
    const uint64_t elapsedMs = LiGetMillis() - probeStartMs;
    if (![result[@"ok"] boolValue]) {
        Log(LOG_W, @"[netprobe] skipped reason=%@ retryAfterMs=%@ elapsed=%llums",
            result[@"error"], result[@"retryAfterMs"], (unsigned long long)elapsedMs);
        return;
    }

    double mbps = [result[@"bandwidthMbps"] doubleValue];
    int safeKbps = (int)floor(mbps * 1000.0 * kProbeSafeBandwidthFraction);
    safeKbps = MIN(safeKbps, kProbeMaxBitrateKbps) / kProbeBitrateStepKbps * kProbeBitrateStepKbps;
    Log(LOG_I, @"[netprobe] bandwidth=%.1fMbps latency=%.1fms jitter=%.1fms bytes=%@ partial=%d safeBitrate=%dkbps configured=%dkbps elapsed=%llums",
        mbps, [result[@"latencyMs"] doubleValue], [result[@"jitterMs"] doubleValue],
        result[@"bytes"], [result[@"partial"] boolValue], safeKbps, _config.bitRate, (unsigned long long)elapsedMs);
    if (safeKbps < kProbeBitrateStepKbps) {
        return;
    }

    // The probe measures what the whole link carries. Audio that goes beyond the
    // share the host holds back from the video bitrate (PCM, AC3) uses part of it.
    int audioExtraKbps = MAX(0, _config.audioExcessBitrateKbps);
    int videoCeilingKbps = safeKbps;
    if (audioExtraKbps > 0) {
        videoCeilingKbps = MAX(kProbeBitrateStepKbps, safeKbps - audioExtraKbps);
        videoCeilingKbps = videoCeilingKbps / kProbeBitrateStepKbps * kProbeBitrateStepKbps;
        Log(LOG_I, @"[netprobe] audio uses %dkbps beyond the host reserve: video ceiling %d -> %dkbps",
            audioExtraKbps, safeKbps, videoCeilingKbps);
    }

    _config.probedBitrateCeilingKbps = videoCeilingKbps;
    if (_config.bitRate > videoCeilingKbps * kProbeCapTolerance) {
        Log(LOG_I, @"[netprobe] capping bitrate %d -> %dkbps", _config.bitRate, videoCeilingKbps);
        _config.bitRate = videoCeilingKbps;
    }
}

- (BOOL) launchApp:(HttpManager*)hMan {
    HttpResponse* launchResp = [[HttpResponse alloc] init];
    [hMan executeRequestSynchronously:[HttpRequest requestForResponse:launchResp withUrlRequest:[hMan newLaunchRequest:_config]]];
    NSString *gameSession = [launchResp getStringTag:@"gamesession"];
    NSString *sessionUrl = [launchResp getStringTag:@"sessionUrl0"];
    if (sessionUrl != nil) {
        _config.sessionUrl = sessionUrl;
    }

    if (![launchResp isStatusOk]) {
        [_callbacks launchFailed:launchResp.statusMessage];
        Log(LOG_E, @"Failed Launch Response: %@", launchResp.statusMessage);
        return FALSE;
    } else if (gameSession == NULL || [gameSession isEqualToString:@"0"]) {
        [_callbacks launchFailed:@"Failed to launch app"];
        Log(LOG_E, @"Failed to parse game session");
        return FALSE;
    }
    
    return TRUE;
}

- (BOOL) resumeApp:(HttpManager*)hMan {
    HttpResponse* resumeResp = [[HttpResponse alloc] init];
    [hMan executeRequestSynchronously:[HttpRequest requestForResponse:resumeResp withUrlRequest:[hMan newResumeRequest:_config]]];
    NSString* resume = [resumeResp getStringTag:@"resume"];
    NSString *sessionUrl = [resumeResp getStringTag:@"sessionUrl0"];
    if (sessionUrl != nil) {
        _config.sessionUrl = sessionUrl;
    }

    if (![resumeResp isStatusOk]) {
        [_callbacks launchFailed:resumeResp.statusMessage];
        Log(LOG_E, @"Failed Resume Response: %@", resumeResp.statusMessage);
        return FALSE;
    } else if (resume == NULL || [resume isEqualToString:@"0"]) {
        [_callbacks launchFailed:@"Failed to resume app"];
        Log(LOG_E, @"Failed to parse resume response");
        return FALSE;
    }
    
    return TRUE;
}

@end

#pragma mark - Remote display scale

// UserDefaults record kept per host from the moment this client changes the host display
// scale until it has put it back: previous, applied (NSNumber), deviceId, displayName.
static NSString *const kRemoteDisplayScalePendingKeyPrefix = @"MLRemoteDisplayScalePending.";
static const CFTimeInterval kRemoteDisplayScaleRefreshIntervalSec = 5.0;

static dispatch_queue_t MLRemoteDisplayScaleQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("moonlight.display-scale", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

// Hosts with a live session in this process; their pending record is not a crash leftover.
static NSMutableSet<NSString *> *MLRemoteDisplayScaleLiveHosts(void) {
    static NSMutableSet<NSString *> *hosts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hosts = [NSMutableSet set];
    });
    return hosts;
}

static void MLRemoteDisplayScaleSetLive(NSString *hostUUID, BOOL live) {
    if (hostUUID.length == 0) {
        return;
    }
    NSMutableSet<NSString *> *hosts = MLRemoteDisplayScaleLiveHosts();
    @synchronized (hosts) {
        if (live) {
            [hosts addObject:hostUUID];
        } else {
            [hosts removeObject:hostUUID];
        }
    }
}

static BOOL MLRemoteDisplayScaleIsLive(NSString *hostUUID) {
    NSMutableSet<NSString *> *hosts = MLRemoteDisplayScaleLiveHosts();
    @synchronized (hosts) {
        return [hosts containsObject:hostUUID];
    }
}

static NSNumber *MLScaleNumber(id value) {
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

static NSString *MLScaleString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static NSString *MLScaleDescribe(NSNumber *value) {
    return value != nil ? [NSString stringWithFormat:@"%ld", (long)value.integerValue] : @"n/a";
}

// The host answered and the display can have its scale set.
static BOOL MLScaleOptionsUsable(NSInteger status, NSDictionary *json) {
    if (status != 200 || ![MLScaleNumber(json[@"success"]) boolValue]) {
        return NO;
    }
    if (![MLScaleNumber(json[@"scale_set_supported"]) boolValue]) {
        return NO;
    }
    NSArray *supported = [json[@"supported_scale_percents"] isKindOfClass:[NSArray class]] ? json[@"supported_scale_percents"] : nil;
    return supported.count > 0 && MLScaleNumber(json[@"current_scale_percent"]) != nil;
}

// A final answer (as opposed to a timeout or a host error that may pass).
static BOOL MLScaleStatusIsDefinitive(NSInteger status) {
    if (status == 200 || status == 501) {
        return YES;
    }
    return status >= 400 && status < 500 && status != 408 && status != 429;
}

static NSString *MLScaleErrorCode(NSInteger status, NSDictionary *json) {
    NSString *code = MLScaleString(json[@"error_code"]);
    if (code.length > 0) {
        return code;
    }
    if (status <= 0) {
        return @"network_error";
    }
    return status == 404 ? @"route_not_found" : [NSString stringWithFormat:@"http_%ld", (long)status];
}

static NSArray<NSNumber *> *MLScalePercentList(id value) {
    if (![value isKindOfClass:[NSArray class]]) {
        return @[];
    }
    NSMutableArray<NSNumber *> *percents = [NSMutableArray array];
    for (id entry in (NSArray *)value) {
        NSNumber *number = MLScaleNumber(entry);
        if (number != nil && number.integerValue > 0) {
            [percents addObject:number];
        }
    }
    [percents sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [a compare:b];
    }];
    return percents;
}

static HttpManager *MLScaleNewHttpManager(NSString *address, NSData *serverCert) {
    if (address.length == 0 || serverCert == nil) {
        return nil;
    }
    return [[HttpManager alloc] initWithHost:address uniqueId:[IdManager getUniqueId] serverCert:serverCert];
}

static NSString *MLScalePendingKey(NSString *hostUUID) {
    return [kRemoteDisplayScalePendingKeyPrefix stringByAppendingString:hostUUID ?: @""];
}

static NSDictionary *MLScaleLoadPending(NSString *hostUUID) {
    if (hostUUID.length == 0) {
        return nil;
    }
    return [[NSUserDefaults standardUserDefaults] dictionaryForKey:MLScalePendingKey(hostUUID)];
}

static void MLScaleClearPending(NSString *hostUUID) {
    if (hostUUID.length > 0) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:MLScalePendingKey(hostUUID)];
    }
}

@implementation MLRemoteDisplayScale {
    NSString *_hostUUID;
    NSString *_hostAddress;
    NSData *_serverCert;

    // Guarded by @synchronized(self).
    NSString *_target;
    NSString *_resolvedDeviceId;
    NSString *_resolvedDisplayName;
    BOOL _targetIsDisplayName;
    MLRemoteDisplayScaleSupport _support;
    BOOL _awaitingFirstQuery;
    NSArray<NSNumber *> *_supportedPercents;
    NSInteger _currentPercent;
    NSInteger _recommendedPercent;
    CFTimeInterval _lastQueryTime;
    BOOL _refreshInFlight;
    BOOL _sessionLive;
}

- (instancetype)initWithHostUUID:(NSString *)hostUUID hostAddress:(NSString *)hostAddress serverCert:(NSData *)serverCert {
    self = [super init];
    if (self) {
        _hostUUID = [hostUUID copy] ?: @"";
        _hostAddress = [hostAddress copy];
        _serverCert = [serverCert copy];
        _target = @"";
        _support = MLRemoteDisplayScaleSupportUnknown;
        _awaitingFirstQuery = YES;
        _supportedPercents = @[];
    }
    return self;
}

- (void)dealloc {
    if (_sessionLive) {
        MLRemoteDisplayScaleSetLive(_hostUUID, NO);
    }
}

- (void)updateHostAddress:(NSString *)hostAddress serverCert:(NSData *)serverCert {
    @synchronized (self) {
        if (hostAddress.length > 0) {
            _hostAddress = [hostAddress copy];
        }
        if (serverCert != nil) {
            _serverCert = [serverCert copy];
        }
    }
}

#pragma mark Snapshot

- (MLRemoteDisplayScaleSupport)support {
    @synchronized (self) {
        return _support;
    }
}

- (BOOL)awaitingFirstQuery {
    @synchronized (self) {
        return _awaitingFirstQuery;
    }
}

- (NSArray<NSNumber *> *)supportedPercents {
    @synchronized (self) {
        return _supportedPercents ?: @[];
    }
}

- (NSInteger)currentPercent {
    @synchronized (self) {
        return _currentPercent;
    }
}

- (NSInteger)recommendedPercent {
    @synchronized (self) {
        return _recommendedPercent;
    }
}

- (HttpManager *)newHttpManager {
    NSString *address = nil;
    NSData *cert = nil;
    @synchronized (self) {
        address = _hostAddress;
        cert = _serverCert;
    }
    return MLScaleNewHttpManager(address, cert);
}

- (void)finishOnMain:(MLRemoteDisplayScaleCompletion)completion outcome:(NSDictionary<NSString *, id> *)outcome {
    if (completion == nil) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(outcome);
    });
}

#pragma mark Options query (scale queue only)

// Reads the options of the target display and refreshes the snapshot.
- (NSDictionary *)queryOptionsWithHttp:(HttpManager *)http status:(NSInteger *)statusOut {
    NSString *deviceId = nil;
    NSString *displayName = nil;
    NSString *target = nil;
    BOOL targetIsDisplayName = NO;
    @synchronized (self) {
        deviceId = _resolvedDeviceId;
        displayName = _resolvedDisplayName;
        target = _target;
        targetIsDisplayName = _targetIsDisplayName;
    }
    BOOL pinned = deviceId.length > 0 || displayName.length > 0;
    if (!pinned && target.length > 0) {
        if (targetIsDisplayName) {
            displayName = target;
        } else {
            deviceId = target;
        }
    }

    NSInteger status = 0;
    NSDictionary *json = [http fetchRemoteDisplayScaleOptionsForDisplayName:(deviceId.length > 0 ? nil : displayName)
                                                                   deviceId:deviceId
                                                                 httpStatus:&status];
    if (!pinned && target.length > 0 && !targetIsDisplayName && status == 404 &&
        [MLScaleString(json[@"error_code"]) isEqualToString:@"display_not_found"]) {
        // The saved value may be a GDI display name rather than a device id.
        NSInteger retryStatus = 0;
        NSDictionary *retry = [http fetchRemoteDisplayScaleOptionsForDisplayName:target deviceId:nil httpStatus:&retryStatus];
        if (retryStatus == 200) {
            json = retry;
            status = retryStatus;
            @synchronized (self) {
                _targetIsDisplayName = YES;
            }
        }
    }

    BOOL usable = MLScaleOptionsUsable(status, json);
    NSString *reportedDeviceId = MLScaleString(json[@"device_id"]);
    NSString *reportedDisplayName = MLScaleString(json[@"display_name"]);
    Log(LOG_I, @"[display-scale] options target=%@ status=%ld errorCode=%@ display=%@ device=%@ primary=%d current=%@ recommended=%@ supported=%@ setSupported=%d",
        target.length > 0 ? target : @"host-default(primary)",
        (long)status,
        MLScaleString(json[@"error_code"]),
        reportedDisplayName,
        reportedDeviceId,
        [MLScaleNumber(json[@"is_primary"]) boolValue] ? 1 : 0,
        MLScaleDescribe(MLScaleNumber(json[@"current_scale_percent"])),
        MLScaleDescribe(MLScaleNumber(json[@"recommended_scale_percent"])),
        [MLScalePercentList(json[@"supported_scale_percents"]) componentsJoinedByString:@","],
        [MLScaleNumber(json[@"scale_set_supported"]) boolValue] ? 1 : 0);

    @synchronized (self) {
        _awaitingFirstQuery = NO;
        _lastQueryTime = [NSProcessInfo processInfo].systemUptime;
        if (usable) {
            _support = MLRemoteDisplayScaleSupportAvailable;
            _supportedPercents = MLScalePercentList(json[@"supported_scale_percents"]);
            _currentPercent = MLScaleNumber(json[@"current_scale_percent"]).integerValue;
            _recommendedPercent = MLScaleNumber(json[@"recommended_scale_percent"]).integerValue;
            if (reportedDeviceId.length > 0) {
                _resolvedDeviceId = reportedDeviceId;
            }
            if (reportedDisplayName.length > 0) {
                _resolvedDisplayName = reportedDisplayName;
            }
        } else if (MLScaleStatusIsDefinitive(status)) {
            _support = MLRemoteDisplayScaleSupportUnavailable;
            _supportedPercents = @[];
            _currentPercent = 0;
            _recommendedPercent = 0;
        }
        // A timeout or host error keeps whatever was known before.
    }
    if (statusOut != NULL) {
        *statusOut = status;
    }
    return json;
}

#pragma mark Stream start

- (void)beginSessionWithTargetDisplay:(NSString *)targetDisplay
                       desiredSetting:(NSInteger)setting
                   restoreAfterStream:(BOOL)restore
                           completion:(MLRemoteDisplayScaleCompletion)completion {
    @synchronized (self) {
        _target = [targetDisplay copy] ?: @"";
        _resolvedDeviceId = nil;
        _resolvedDisplayName = nil;
        _targetIsDisplayName = NO;
        _support = MLRemoteDisplayScaleSupportUnknown;
        _awaitingFirstQuery = YES;
        _sessionLive = YES;
    }
    MLRemoteDisplayScaleSetLive(_hostUUID, YES);

    dispatch_async(MLRemoteDisplayScaleQueue(), ^{
        HttpManager *http = [self newHttpManager];
        if (http == nil) {
            @synchronized (self) {
                self->_awaitingFirstQuery = NO;
            }
            return;
        }

        NSInteger status = 0;
        NSDictionary *json = [self queryOptionsWithHttp:http status:&status];
        if (self.support != MLRemoteDisplayScaleSupportAvailable) {
            Log(LOG_I, @"[display-scale] start: host does not offer a settable scale (status=%ld errorCode=%@), leaving it alone",
                (long)status, MLScaleErrorCode(status, json));
            [http invalidateSunshineAPISession];
            return;
        }
        if (setting == 0) {
            Log(LOG_I, @"[display-scale] start: no change requested (current=%ld%%)", (long)self.currentPercent);
            [http invalidateSunshineAPISession];
            return;
        }

        NSInteger wanted = setting < 0 ? self.recommendedPercent : setting;
        if (wanted <= 0) {
            Log(LOG_I, @"[display-scale] start: host reported no recommended scale, leaving it alone");
        } else if (![self.supportedPercents containsObject:@(wanted)]) {
            Log(LOG_I, @"[display-scale] start: %ld%% is not supported by this display (supported=%@), leaving it alone",
                (long)wanted, [self.supportedPercents componentsJoinedByString:@","]);
        } else if (wanted == self.currentPercent) {
            Log(LOG_I, @"[display-scale] start: scale is already %ld%%", (long)wanted);
        } else {
            [self applyPercentOnQueue:wanted http:http restore:restore source:@"stream-start" completion:completion];
        }
        [http invalidateSunshineAPISession];
    });
}

#pragma mark Applying a value (scale queue only)

- (void)applyPercentOnQueue:(NSInteger)percent
                       http:(HttpManager *)http
                    restore:(BOOL)restore
                     source:(NSString *)source
                 completion:(MLRemoteDisplayScaleCompletion)completion {
    NSString *deviceId = nil;
    NSString *displayName = nil;
    NSInteger before = 0;
    @synchronized (self) {
        deviceId = _resolvedDeviceId;
        displayName = _resolvedDisplayName;
        before = _currentPercent;
    }

    NSInteger status = 0;
    NSDictionary *json = [http setRemoteDisplayScalePercent:percent
                                                displayName:(deviceId.length > 0 ? nil : displayName)
                                                   deviceId:deviceId
                                                 httpStatus:&status];
    BOOL ok = status == 200 && [MLScaleNumber(json[@"success"]) boolValue];
    NSNumber *previous = MLScaleNumber(json[@"previous_scale_percent"]);
    NSNumber *current = MLScaleNumber(json[@"current_scale_percent"]);
    BOOL restartRequired = [MLScaleNumber(json[@"restart_required"]) boolValue];
    BOOL effectiveImmediately = [MLScaleNumber(json[@"effective_immediately"]) boolValue];
    NSString *errorCode = ok ? @"" : MLScaleErrorCode(status, json);

    Log(LOG_I, @"[display-scale] set source=%@ target=%@ previous=%@ requested=%ld result=%@ effectiveImmediately=%d restartRequired=%d status=%ld errorCode=%@",
        source,
        deviceId.length > 0 ? deviceId : (displayName.length > 0 ? displayName : @"host-default(primary)"),
        MLScaleDescribe(previous ?: (before > 0 ? @(before) : nil)),
        (long)percent,
        MLScaleDescribe(current),
        effectiveImmediately ? 1 : 0,
        restartRequired ? 1 : 0,
        (long)status,
        errorCode.length > 0 ? errorCode : @"none");

    NSInteger resulting = current != nil ? current.integerValue : percent;
    if (ok) {
        NSArray<NSNumber *> *supported = MLScalePercentList(json[@"supported_scale_percents"]);
        @synchronized (self) {
            _currentPercent = resulting;
            if (supported.count > 0) {
                _supportedPercents = supported;
            }
            _support = MLRemoteDisplayScaleSupportAvailable;
        }
        NSString *reportedDeviceId = MLScaleString(json[@"device_id"]);
        NSString *reportedDisplayName = MLScaleString(json[@"display_name"]);
        [self recordPendingPrevious:(previous != nil ? previous.integerValue : before)
                            applied:resulting
                            restore:restore
                           deviceId:(reportedDeviceId.length > 0 ? reportedDeviceId : deviceId)
                        displayName:(reportedDisplayName.length > 0 ? reportedDisplayName : displayName)];
    }

    [self finishOnMain:completion outcome:@{
        @"ok": @(ok),
        @"changed": @(ok && resulting != before),
        @"percent": @(resulting),
        @"restartRequired": @(restartRequired),
        @"errorCode": errorCode ?: @"",
        @"httpStatus": @(status),
    }];
}

// Remembers what to put back. The original value survives repeated changes in one session.
- (void)recordPendingPrevious:(NSInteger)previous
                      applied:(NSInteger)applied
                      restore:(BOOL)restore
                     deviceId:(NSString *)deviceId
                  displayName:(NSString *)displayName {
    if (_hostUUID.length == 0) {
        return;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *key = MLScalePendingKey(_hostUUID);
    NSDictionary *existing = [defaults dictionaryForKey:key];

    if (!restore) {
        if (existing != nil) {
            [defaults removeObjectForKey:key];
        }
        Log(LOG_I, @"[display-scale] restore after streaming is off; the %ld%% scale stays after the stream", (long)applied);
        return;
    }

    NSInteger original = previous;
    if (existing != nil) {
        NSString *existingDeviceId = MLScaleString(existing[@"deviceId"]);
        NSString *existingDisplayName = MLScaleString(existing[@"displayName"]);
        BOOL sameDisplay = (deviceId.length > 0 && [existingDeviceId isEqualToString:deviceId]) ||
                           (displayName.length > 0 && [existingDisplayName isEqualToString:displayName]);
        NSInteger existingPrevious = MLScaleNumber(existing[@"previous"]).integerValue;
        if (sameDisplay && existingPrevious > 0) {
            original = existingPrevious;
        }
    }

    if (original <= 0 || original == applied) {
        [defaults removeObjectForKey:key];
        Log(LOG_I, @"[display-scale] scale is back at %ld%%; nothing to restore later", (long)applied);
        return;
    }
    [defaults setObject:@{
        @"previous": @(original),
        @"applied": @(applied),
        @"deviceId": deviceId ?: @"",
        @"displayName": displayName ?: @"",
    } forKey:key];
    Log(LOG_I, @"[display-scale] pending restore saved: %ld%% -> %ld%% device=%@", (long)original, (long)applied, deviceId.length > 0 ? deviceId : displayName);
}

#pragma mark Control center

- (void)applyPercent:(NSInteger)percent
  restoreAfterStream:(BOOL)restore
          completion:(MLRemoteDisplayScaleCompletion)completion {
    dispatch_async(MLRemoteDisplayScaleQueue(), ^{
        HttpManager *http = [self newHttpManager];
        if (http == nil) {
            [self finishOnMain:completion outcome:@{ @"ok": @NO, @"changed": @NO, @"errorCode": @"no_host", @"httpStatus": @0 }];
            return;
        }
        if (self.support != MLRemoteDisplayScaleSupportAvailable) {
            [self queryOptionsWithHttp:http status:NULL];
        }
        if (self.support != MLRemoteDisplayScaleSupportAvailable) {
            [self finishOnMain:completion outcome:@{ @"ok": @NO, @"changed": @NO, @"errorCode": @"unsupported_platform", @"httpStatus": @0 }];
        } else {
            [self applyPercentOnQueue:percent http:http restore:restore source:@"control-center" completion:completion];
        }
        [http invalidateSunshineAPISession];
    });
}

- (void)refreshOptionsIfStale {
    @synchronized (self) {
        if (!_sessionLive || _refreshInFlight || _awaitingFirstQuery ||
            _support == MLRemoteDisplayScaleSupportUnavailable ||
            [NSProcessInfo processInfo].systemUptime - _lastQueryTime < kRemoteDisplayScaleRefreshIntervalSec) {
            return;
        }
        _refreshInFlight = YES;
    }
    dispatch_async(MLRemoteDisplayScaleQueue(), ^{
        HttpManager *http = [self newHttpManager];
        if (http != nil) {
            [self queryOptionsWithHttp:http status:NULL];
            [http invalidateSunshineAPISession];
        }
        @synchronized (self) {
            self->_refreshInFlight = NO;
        }
    });
}

#pragma mark Stream end and crash recovery

- (void)endSessionRestoring:(BOOL)restore reason:(NSString *)reason {
    NSString *address = nil;
    NSData *cert = nil;
    @synchronized (self) {
        _sessionLive = NO;
        address = _hostAddress;
        cert = _serverCert;
    }
    MLRemoteDisplayScaleSetLive(_hostUUID, NO);

    NSString *hostUUID = _hostUUID;
    dispatch_async(MLRemoteDisplayScaleQueue(), ^{
        NSDictionary *record = MLScaleLoadPending(hostUUID);
        if (record == nil) {
            Log(LOG_I, @"[display-scale] restore skipped (%@): this client did not change the scale", reason ?: @"stream-end");
            return;
        }
        if (!restore) {
            MLScaleClearPending(hostUUID);
            Log(LOG_I, @"[display-scale] restore skipped (%@): restore after streaming is off, scale stays %@%%",
                reason ?: @"stream-end", MLScaleDescribe(MLScaleNumber(record[@"applied"])));
            return;
        }
        [MLRemoteDisplayScale performRestoreForRecord:record hostUUID:hostUUID address:address serverCert:cert reason:reason ?: @"stream-end"];
    });
}

+ (void)recoverPendingRestoreForHostUUID:(NSString *)hostUUID
                             hostAddress:(NSString *)hostAddress
                              serverCert:(NSData *)serverCert {
    if (MLScaleLoadPending(hostUUID) == nil) {
        return;
    }
    NSString *address = [hostAddress copy];
    NSData *cert = [serverCert copy];
    dispatch_async(MLRemoteDisplayScaleQueue(), ^{
        if (MLRemoteDisplayScaleIsLive(hostUUID)) {
            return;
        }
        NSDictionary *record = MLScaleLoadPending(hostUUID);
        if (record == nil) {
            return;
        }
        [MLRemoteDisplayScale performRestoreForRecord:record hostUUID:hostUUID address:address serverCert:cert reason:@"crash-recovery"];
    });
}

// Puts the previous scale back, but only while the host still shows the value this client
// applied. Keeps the record when the host could not be reached so a later run can retry.
+ (void)performRestoreForRecord:(NSDictionary *)record
                       hostUUID:(NSString *)hostUUID
                        address:(NSString *)address
                     serverCert:(NSData *)serverCert
                         reason:(NSString *)reason {
    HttpManager *http = MLScaleNewHttpManager(address, serverCert);
    if (http == nil) {
        Log(LOG_W, @"[display-scale] restore (%@) postponed: no host address", reason);
        return;
    }

    NSInteger previous = MLScaleNumber(record[@"previous"]).integerValue;
    NSInteger applied = MLScaleNumber(record[@"applied"]).integerValue;
    NSString *deviceId = MLScaleString(record[@"deviceId"]);
    NSString *displayName = MLScaleString(record[@"displayName"]);
    NSString *label = deviceId.length > 0 ? deviceId : displayName;

    NSInteger status = 0;
    NSDictionary *options = [http fetchRemoteDisplayScaleOptionsForDisplayName:(deviceId.length > 0 ? nil : displayName)
                                                                      deviceId:deviceId
                                                                    httpStatus:&status];
    if (status == 200 && [MLScaleNumber(options[@"success"]) boolValue]) {
        NSNumber *current = MLScaleNumber(options[@"current_scale_percent"]);
        if (current == nil || current.integerValue != applied) {
            MLScaleClearPending(hostUUID);
            Log(LOG_I, @"[display-scale] restore (%@) skipped: host scale is %@%%, not the %ld%% this client applied; left alone (device=%@)",
                reason, MLScaleDescribe(current), (long)applied, label);
        } else if (previous <= 0 || previous == current.integerValue) {
            MLScaleClearPending(hostUUID);
            Log(LOG_I, @"[display-scale] restore (%@) skipped: nothing to restore", reason);
        } else {
            NSInteger setStatus = 0;
            NSDictionary *result = [http setRemoteDisplayScalePercent:previous
                                                          displayName:(deviceId.length > 0 ? nil : displayName)
                                                             deviceId:deviceId
                                                           httpStatus:&setStatus];
            BOOL ok = setStatus == 200 && [MLScaleNumber(result[@"success"]) boolValue];
            NSString *errorCode = ok ? @"none" : MLScaleErrorCode(setStatus, result);
            Log(LOG_I, @"[display-scale] restore (%@) device=%@ requested=%ld previous=%@ result=%@ effectiveImmediately=%d restartRequired=%d status=%ld errorCode=%@",
                reason, label, (long)previous,
                MLScaleDescribe(MLScaleNumber(result[@"previous_scale_percent"])),
                MLScaleDescribe(MLScaleNumber(result[@"current_scale_percent"])),
                [MLScaleNumber(result[@"effective_immediately"]) boolValue] ? 1 : 0,
                [MLScaleNumber(result[@"restart_required"]) boolValue] ? 1 : 0,
                (long)setStatus, errorCode);
            if (ok) {
                MLScaleClearPending(hostUUID);
            } else if (MLScaleStatusIsDefinitive(setStatus) && setStatus != 403) {
                // unsupported_scale / display_not_found: retrying cannot succeed.
                MLScaleClearPending(hostUUID);
            }
        }
    } else if (MLScaleStatusIsDefinitive(status)) {
        MLScaleClearPending(hostUUID);
        Log(LOG_I, @"[display-scale] restore (%@) dropped: host cannot report the display (status=%ld errorCode=%@ device=%@)",
            reason, (long)status, MLScaleErrorCode(status, options), label);
    } else {
        Log(LOG_W, @"[display-scale] restore (%@) postponed: host unreachable (status=%ld); will retry on the next connection",
            reason, (long)status);
    }
    [http invalidateSunshineAPISession];
}

@end
