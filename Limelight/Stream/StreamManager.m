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
    // Built on the main thread while the host launches the app, bound to the launch
    // reply later. Not exposed as -connection until then: the connect watchdog treats a
    // visible connection as "RTSP/video startup has begun". Guarded by _preparedLock.
    Connection* _preparedConnection;
    // Set once the prepared connection was discarded; an early block still queued on the
    // main thread must then not build one.
    BOOL _preparedClosed;
    NSObject* _preparedLock;
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
    _preparedLock = [[NSObject alloc] init];
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
    
    if (_config.enableAdaptiveBitrate) {
        // The host refuses the probe once a video session exists, so it must precede launch/resume.
        [self applyBandwidthProbe:hMan];
        if (self.isCancelled || _callbacks == nil) {
            return;
        }
    }

    // Populate the config's version fields from serverinfo. They do not depend on the
    // launch/resume reply and the request does not read them, so they are set before it
    // goes out and let the Connection be built while the host is busy.
    _config.appVersion = appversion;
    _config.gfeVersion = gfeVersion;
    // VddCapabilityVersion only exists in Foundation Sunshine serverinfo. Runtime
    // stream changes (0x5506) are a Foundation protocol extension.
    _config.foundationHost = [serverInfoResp getStringTag:@"VddCapabilityVersion"] != nil;

    // Everything the Connection reads from the config is final now (serverinfo fields, and
    // the bitrate after the optional probe) except the session URL from the reply.
    __block uint64_t connectionPreparedMs = 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.isCancelled || self->_callbacks == nil) {
            return;
        }
        @synchronized (self->_preparedLock) {
            if (self->_preparedClosed) {
                return;
            }
        }

        uint64_t prepareStartMs = LiGetMillis();
        if (self->_renderer == nil) {
            self->_renderer = [[VideoDecoderRenderer alloc] initWithView:self->_renderView];
            [self->_renderer prewarmPresentationForStreamConfig:self->_config];
            rendererWarmupFinishedMs = LiGetMillis();
        }

        Connection* prepared = [[Connection alloc] initWithConfig:self->_config renderer:self->_renderer connectionCallbacks:self->_callbacks];
        BOOL abandoned = NO;
        @synchronized (self->_preparedLock) {
            // stopStream cancels before it looks for a prepared connection, so either it
            // sees this one or this check sees the cancellation.
            abandoned = self.isCancelled || self->_callbacks == nil || self->_preparedClosed;
            if (!abandoned) {
                self->_preparedConnection = prepared;
            }
        }
        if (abandoned) {
            [prepared terminate];
            return;
        }
        connectionPreparedMs = LiGetMillis() - prepareStartMs;
    });

    // resumeApp and launchApp handle calling launchFailed
    const uint64_t hostLaunchStartMs = LiGetMillis();
    if ([serverState hasSuffix:@"_SERVER_BUSY"]) {
        // App already running, resume it
        if (![self resumeApp:hMan]) {
            [self discardPreparedConnection];
            return;
        }
    } else {
        // Start app
        if (![self launchApp:hMan]) {
            [self discardPreparedConnection];
            return;
        }
    }
    const uint64_t hostLaunchEndMs = LiGetMillis();
    _config.startupRequestMs = hostLaunchStartMs;
    _config.startupReplyMs = hostLaunchEndMs;
    if (self.isCancelled || _callbacks == nil) {
        [self discardPreparedConnection];
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
        Connection* connection = nil;
        @synchronized (self->_preparedLock) {
            connection = self->_preparedConnection;
            self->_preparedConnection = nil;
        }
        const BOOL preparedEarly = connection != nil;
        if (!preparedEarly) {
            // Not prepared ahead (the early block was skipped); build it now.
            if (self->_renderer == nil) {
                self->_renderer = [[VideoDecoderRenderer alloc] initWithView:self->_renderView];
                [self->_renderer prewarmPresentationForStreamConfig:self->_config];
                rendererWarmupFinishedMs = LiGetMillis();
            }
            connection = [[Connection alloc] initWithConfig:self->_config renderer:self->_renderer connectionCallbacks:self->_callbacks];
        }
        [connection bindLaunchResultWithSessionUrl:self->_config.sessionUrl];

        self->_connection = connection;
        if (self.isCancelled || self->_callbacks == nil) {
            self->_connection = nil;
            [connection terminate];
            return;
        }

        [self->_connectionQueue cancelAllOperations];
        self->_connectionQueue = [[NSOperationQueue alloc] init];
        self->_connectionQueue.maxConcurrentOperationCount = 1;
        [self->_connectionQueue addOperation:self->_connection];
        Log(LOG_I, @"[startup] Main bind rendererWarmupQueued=%llums rendererWarmupReady=%llums connectionQueue=%llums total=%llums connectionPrepared=%llums early=%d",
            rendererWarmupScheduledMs != 0 ? (unsigned long long)(rendererWarmupScheduledMs - startupStartMs) : 0,
            rendererWarmupFinishedMs != 0 ? (unsigned long long)(rendererWarmupFinishedMs - startupStartMs) : 0,
            (unsigned long long)(LiGetMillis() - mainBindStartMs),
            (unsigned long long)(LiGetMillis() - startupStartMs),
            (unsigned long long)connectionPreparedMs,
            preparedEarly ? 1 : 0);
    });
}

- (void) stopStream
{
    [self cancel];
    [_connectionQueue cancelAllOperations];
    _connectionQueue = nil;
    [_connection terminate];
    [self discardPreparedConnection];
    _callbacks = nil;
}

// Tears down a connection that was built ahead of the launch reply but never started.
// terminate also removes it from the connection registry, which would otherwise keep it alive.
// Safe from any thread and idempotent.
- (void)discardPreparedConnection {
    Connection* prepared = nil;
    @synchronized (_preparedLock) {
        prepared = _preparedConnection;
        _preparedConnection = nil;
        _preparedClosed = YES;
    }
    [prepared terminate];
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

static const CFTimeInterval kRemoteDisplayScaleRefreshIntervalSec = 5.0;

static dispatch_queue_t MLRemoteDisplayScaleQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("moonlight.display-scale", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
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

@implementation MLRemoteDisplayScale {
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
    // Bumped when a session begins and when it ends. Work created for one session carries the
    // value it saw and is dropped on the scale queue if the session is no longer that one.
    NSUInteger _sessionGeneration;
    void (^_optionsDidChangeHandler)(void);
}

- (instancetype)initWithHostAddress:(NSString *)hostAddress serverCert:(NSData *)serverCert {
    self = [super init];
    if (self) {
        _hostAddress = [hostAddress copy];
        _serverCert = [serverCert copy];
        _target = @"";
        _support = MLRemoteDisplayScaleSupportUnknown;
        _awaitingFirstQuery = YES;
        _supportedPercents = @[];
    }
    return self;
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

#pragma mark Session guard

// Generation to stamp on work created right now (any thread).
- (NSUInteger)currentSessionGeneration {
    @synchronized (self) {
        return _sessionGeneration;
    }
}

// YES while `generation` is still the live session. Call it on the scale queue right before
// anything that talks to the host: -endSession flips this under the same lock, so a request
// created before teardown (or for an earlier session) cannot pass any more.
- (BOOL)isSessionCurrent:(NSUInteger)generation source:(NSString *)source {
    BOOL live = NO;
    NSUInteger current = 0;
    @synchronized (self) {
        live = _sessionLive;
        current = _sessionGeneration;
    }
    if (live && current == generation) {
        return YES;
    }
    Log(LOG_I, @"[display-scale] ignored stale request source=%@ generation=%lu current=%lu live=%d",
        source, (unsigned long)generation, (unsigned long)current, live ? 1 : 0);
    return NO;
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

- (void (^)(void))optionsDidChangeHandler {
    @synchronized (self) {
        return _optionsDidChangeHandler;
    }
}

- (void)setOptionsDidChangeHandler:(void (^)(void))handler {
    @synchronized (self) {
        _optionsDidChangeHandler = [handler copy];
    }
}

// Tells the control center (main queue) that the snapshot moved. Safe from any thread.
- (void)notifyOptionsDidChange {
    void (^handler)(void) = self.optionsDidChangeHandler;
    if (handler == nil) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        // Re-read: the session may have ended (handler cleared) while this was queued.
        void (^current)(void) = self.optionsDidChangeHandler;
        if (current != nil) {
            current();
        }
    });
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

    BOOL changed = NO;
    @synchronized (self) {
        const MLRemoteDisplayScaleSupport oldSupport = _support;
        const BOOL oldAwaiting = _awaitingFirstQuery;
        const NSInteger oldCurrent = _currentPercent;
        const NSInteger oldRecommended = _recommendedPercent;
        NSArray<NSNumber *> *oldPercents = _supportedPercents;

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

        changed = oldSupport != _support || oldAwaiting != _awaitingFirstQuery ||
                  oldCurrent != _currentPercent || oldRecommended != _recommendedPercent ||
                  ![oldPercents isEqualToArray:_supportedPercents];
    }
    if (statusOut != NULL) {
        *statusOut = status;
    }
    // A control center that is open is only touched when the answer differs from what it shows.
    if (changed) {
        [self notifyOptionsDidChange];
    }
    return json;
}

#pragma mark Stream start

- (void)beginSessionWithTargetDisplay:(NSString *)targetDisplay {
    NSUInteger generation = 0;
    @synchronized (self) {
        _target = [targetDisplay copy] ?: @"";
        _resolvedDeviceId = nil;
        _resolvedDisplayName = nil;
        _targetIsDisplayName = NO;
        _support = MLRemoteDisplayScaleSupportUnknown;
        _awaitingFirstQuery = YES;
        _sessionLive = YES;
        generation = ++_sessionGeneration;
    }

    dispatch_async(MLRemoteDisplayScaleQueue(), ^{
        // The stream may already be over, or replaced, by the time the queue gets here.
        if (![self isSessionCurrent:generation source:@"stream-start"]) {
            return;
        }
        HttpManager *http = [self newHttpManager];
        if (http == nil) {
            @synchronized (self) {
                self->_awaitingFirstQuery = NO;
            }
            return;
        }

        // Read only: the host's scale is never touched unless the user picks one in the control center.
        NSInteger status = 0;
        NSDictionary *json = [self queryOptionsWithHttp:http status:&status];
        if (self.support != MLRemoteDisplayScaleSupportAvailable) {
            Log(LOG_I, @"[display-scale] start: host does not offer a settable scale (status=%ld errorCode=%@)",
                (long)status, MLScaleErrorCode(status, json));
        } else {
            Log(LOG_I, @"[display-scale] start: left as it is (current=%ld%%)", (long)self.currentPercent);
        }
        [http invalidateSunshineAPISession];
    });
}

#pragma mark Applying a value (scale queue only)

// A request that is no longer for the live session is dropped without calling the completion:
// the stream it belonged to is gone, so there is nobody left to show an outcome to.
- (void)applyPercentOnQueue:(NSInteger)percent
                       http:(HttpManager *)http
                 generation:(NSUInteger)generation
                     source:(NSString *)source
                 completion:(MLRemoteDisplayScaleCompletion)completion {
    if (![self isSessionCurrent:generation source:source]) {
        return;
    }
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
        if (resulting != before) {
            [self notifyOptionsDidChange];
        }
        // The user changed the host by hand: it stays like that, exactly as if it had been done in
        // Windows. Nothing remembers it and nothing puts the old value back.
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

#pragma mark Control center

- (void)applyManualPercent:(NSInteger)percent
                completion:(MLRemoteDisplayScaleCompletion)completion {
    // Stamped when the action is created: a menu that outlives its stream must not act on a later one.
    NSUInteger generation = [self currentSessionGeneration];
    dispatch_async(MLRemoteDisplayScaleQueue(), ^{
        if (![self isSessionCurrent:generation source:@"control-center"]) {
            return;
        }
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
            [self applyPercentOnQueue:percent http:http generation:generation source:@"control-center" completion:completion];
        }
        [http invalidateSunshineAPISession];
    });
}

- (void)refreshOptionsIfStale {
    NSUInteger generation = 0;
    @synchronized (self) {
        if (!_sessionLive || _refreshInFlight || _awaitingFirstQuery ||
            _support == MLRemoteDisplayScaleSupportUnavailable ||
            [NSProcessInfo processInfo].systemUptime - _lastQueryTime < kRemoteDisplayScaleRefreshIntervalSec) {
            return;
        }
        _refreshInFlight = YES;
        generation = _sessionGeneration;
    }
    dispatch_async(MLRemoteDisplayScaleQueue(), ^{
        // After teardown (or for a replaced session) the snapshot is not worth another host call.
        HttpManager *http = [self isSessionCurrent:generation source:@"refresh"] ? [self newHttpManager] : nil;
        if (http != nil) {
            [self queryOptionsWithHttp:http status:NULL];
            [http invalidateSunshineAPISession];
        }
        @synchronized (self) {
            self->_refreshInFlight = NO;
        }
    });
}

#pragma mark Stream end

- (void)endSession {
    @synchronized (self) {
        _sessionLive = NO;
        // Invalidates every request stamped before this point; see -isSessionCurrent:source:.
        _sessionGeneration++;
        _optionsDidChangeHandler = nil;
    }
}

@end
