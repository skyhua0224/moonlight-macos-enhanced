//
//  MLAdaptiveBitrateController.m
//  Moonlight for macOS
//

#import "MLAdaptiveBitrateController.h"
#import "HttpManager.h"

// The session must be RUNNING on the host before /api/abr accepts a client.
static const int64_t kStartDelaySeconds = 3;
static const int kEnableRetryIntervalTicks = 5;
static const int kMaxEnableAttempts = 10;
static const int kSummaryIntervalTicks = 10;
static const NSTimeInterval kRequestTimeoutSec = 3;

static const int kBalancedMinFloorKbps = 3000;
static const double kBalancedMinFraction = 0.3;
static const double kBalancedMaxMultiplier = 2.0;
static const int kAbsoluteMaxKbps = 150000;

@implementation MLAdaptiveBitrateController {
    HttpManager *_http;
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    int _initialKbps;
    int _minKbps;
    int _maxKbps;

    // Only touched on _queue.
    BOOL _stopped;
    BOOL _serverEnabled;
    int _enableAttempts;
    int _ticksSinceEnableAttempt;
    int _ticksSinceSummary;
    int _currentKbps;

    NSLock *_statsLock;
    BOOL _hasStats;
    double _packetLoss;
    double _rttMs;
    double _decodeFps;
    int _droppedFrames;
}

- (instancetype)initWithHttpManager:(HttpManager *)httpManager
                 initialBitrateKbps:(int)initialBitrateKbps
                        ceilingKbps:(int)ceilingKbps {
    self = [super init];
    if (self) {
        _http = httpManager;
        _queue = dispatch_queue_create("moonlight.abr", DISPATCH_QUEUE_SERIAL);
        _statsLock = [[NSLock alloc] init];
        _initialKbps = initialBitrateKbps;
        _currentKbps = initialBitrateKbps;

        // "balanced" preset, matching the Android client.
        _maxKbps = MIN(kAbsoluteMaxKbps, (int)(initialBitrateKbps * kBalancedMaxMultiplier));
        if (ceilingKbps > 0) {
            _maxKbps = MIN(_maxKbps, MAX(ceilingKbps, initialBitrateKbps));
        }
        _minKbps = MIN(initialBitrateKbps, MAX(kBalancedMinFloorKbps, (int)(initialBitrateKbps * kBalancedMinFraction)));
        _maxKbps = MAX(_maxKbps, _minKbps);
    }
    return self;
}

- (void)updatePacketLossPercent:(double)packetLossPercent
                          rttMs:(double)rttMs
                      decodeFps:(double)decodeFps
                  droppedFrames:(int)droppedFrames {
    [_statsLock lock];
    _hasStats = YES;
    _packetLoss = packetLossPercent;
    _rttMs = rttMs;
    _decodeFps = decodeFps;
    _droppedFrames = droppedFrames;
    [_statsLock unlock];
}

- (void)start {
    dispatch_async(_queue, ^{
        if (self->_timer != nil || self->_stopped) {
            return;
        }

        NSInteger status = 0;
        NSDictionary *caps = [self->_http sunshineAPIRequestWithPath:@"/api/abr/capabilities" method:@"GET" body:nil timeout:kRequestTimeoutSec httpStatus:&status];
        BOOL supported = status == 200 && [caps[@"supported"] boolValue];
        Log(LOG_I, @"[abr] capabilities status=%ld supported=%d version=%@ hostMaxKbps=%@ llm=%d",
            (long)status, supported, caps[@"version"], caps[@"hostMaxBitrate"], [caps[@"llmEnabled"] boolValue]);
        if (!supported) {
            Log(LOG_I, @"[abr] host does not offer adaptive bitrate; leaving the bitrate fixed");
            [self->_http invalidateSunshineAPISession];
            return;
        }

        self->_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_queue);
        dispatch_source_set_timer(self->_timer,
                                  dispatch_time(DISPATCH_TIME_NOW, kStartDelaySeconds * NSEC_PER_SEC),
                                  NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(self->_timer, ^{ [self tick]; });
        dispatch_resume(self->_timer);
    });
}

- (void)stop {
    dispatch_async(_queue, ^{
        if (self->_stopped) {
            return;
        }
        self->_stopped = YES;
        if (self->_timer != nil) {
            dispatch_source_cancel(self->_timer);
            self->_timer = nil;
        }
        if (self->_serverEnabled) {
            // Best effort; the session is usually already gone by now.
            NSInteger status = 0;
            [self->_http sunshineAPIRequestWithPath:@"/api/abr" method:@"POST" body:@{ @"enabled": @NO } timeout:2 httpStatus:&status];
            Log(LOG_I, @"[abr] disabled status=%ld lastBitrate=%dkbps initial=%dkbps", (long)status, self->_currentKbps, self->_initialKbps);
        }
        [self->_http invalidateSunshineAPISession];
    });
}

- (void)tick {
    if (_stopped) {
        return;
    }

    if (!_serverEnabled) {
        if (_enableAttempts >= kMaxEnableAttempts) {
            return;
        }
        if (_enableAttempts > 0 && ++_ticksSinceEnableAttempt < kEnableRetryIntervalTicks) {
            return;
        }
        _ticksSinceEnableAttempt = 0;
        _enableAttempts++;
        [self enableOnHost];
        return;
    }

    [_statsLock lock];
    BOOL hasStats = _hasStats;
    double loss = _packetLoss, rtt = _rttMs, fps = _decodeFps;
    int dropped = _droppedFrames;
    [_statsLock unlock];
    if (!hasStats) {
        return;
    }

    NSInteger status = 0;
    NSDictionary *response = [_http sunshineAPIRequestWithPath:@"/api/abr/feedback" method:@"POST" body:@{
        @"packetLoss": @(loss),
        @"rttMs": @(rtt),
        @"decodeFps": @(fps),
        @"droppedFrames": @(dropped),
        @"currentBitrate": @(_currentKbps),
    } timeout:kRequestTimeoutSec httpStatus:&status];

    if (status != 200) {
        NSString *error = [response[@"error"] isKindOfClass:[NSString class]] ? response[@"error"] : @"";
        Log(LOG_W, @"[abr] feedback failed status=%ld error=%@", (long)status, error);
        if (status == 400) {
            // The host forgot the session (e.g. after a restart of the stream); enable again.
            _serverEnabled = NO;
            _enableAttempts = 0;
            _ticksSinceEnableAttempt = 0;
        }
        return;
    }

    NSNumber *newBitrate = response[@"newBitrate"];
    BOOL applied = [response[@"bitrateApplied"] boolValue];
    if ([newBitrate isKindOfClass:[NSNumber class]] && newBitrate.intValue > 0 && newBitrate.intValue != _currentKbps) {
        Log(LOG_I, @"[abr] bitrate %d -> %dkbps applied=%d reason=%@ (loss=%.2f%% rtt=%.0fms fps=%.1f drop=%d)",
            _currentKbps, newBitrate.intValue, applied, response[@"reason"], loss, rtt, fps, dropped);
        if (applied) {
            _currentKbps = newBitrate.intValue;
        }
        _ticksSinceSummary = 0;
    } else if (++_ticksSinceSummary >= kSummaryIntervalTicks) {
        _ticksSinceSummary = 0;
        Log(LOG_I, @"[abr] steady bitrate=%dkbps loss=%.2f%% rtt=%.0fms fps=%.1f drop=%d reason=%@",
            _currentKbps, loss, rtt, fps, dropped, response[@"reason"]);
    }
}

- (void)enableOnHost {
    NSInteger status = 0;
    NSDictionary *response = [_http sunshineAPIRequestWithPath:@"/api/abr" method:@"POST" body:@{
        @"enabled": @YES,
        @"mode": @"balanced",
        @"minBitrate": @(_minKbps),
        @"maxBitrate": @(_maxKbps),
    } timeout:kRequestTimeoutSec httpStatus:&status];

    if (status == 200 && [response[@"success"] boolValue]) {
        _serverEnabled = YES;
        // The host may have lowered the range or the active bitrate to its own cap.
        NSNumber *initial = response[@"initialBitrate"];
        if ([initial isKindOfClass:[NSNumber class]] && initial.intValue > 0) {
            _currentKbps = initial.intValue;
        }
        Log(LOG_I, @"[abr] enabled mode=balanced range=%d-%dkbps hostRange=%@-%@kbps hostMax=%@kbps initial=%dkbps capped=%d applied=%d attempt=%d",
            _minKbps, _maxKbps, response[@"minBitrate"], response[@"maxBitrate"], response[@"hostMaxBitrate"],
            _currentKbps, [response[@"maxBitrateCapped"] boolValue], [response[@"bitrateApplied"] boolValue], _enableAttempts);
        return;
    }

    Log(LOG_W, @"[abr] enable failed status=%ld attempt=%d/%d error=%@",
        (long)status, _enableAttempts, kMaxEnableAttempts, response[@"error"]);
    if (_enableAttempts >= kMaxEnableAttempts) {
        Log(LOG_W, @"[abr] giving up; the bitrate stays fixed for this stream");
    }
}

@end
