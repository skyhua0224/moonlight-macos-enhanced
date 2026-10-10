//
//  StreamViewController+LiveStream.m
//  Moonlight for macOS
//
//  Runtime bitrate / frame rate / resolution changes for a running stream, and
//  the host's resolution change notice.
//

#import "StreamViewController_Internal.h"

@implementation StreamViewController (LiveStream)

// Copied from moonlight-qt (StreamingPreferences::getDefaultBitrate)
+ (int)automaticBitrateKbpsForWidth:(int)width height:(int)height fps:(int)fps yuv444:(BOOL)yuv444 {
    float frameRateFactor = (fps <= 60 ? (float)fps : (sqrtf((float)fps / 60.f) * 60.f)) / 30.f;

    struct ResEntry { int pixels; int factor; };
    static const struct ResEntry resTable[] = {
        { 640 * 360, 1 },
        { 854 * 480, 2 },
        { 1280 * 720, 5 },
        { 1920 * 1080, 10 },
        { 2560 * 1440, 20 },
        { 3840 * 2160, 40 },
        { -1, -1 },
    };

    int pixels = width * height;
    float resolutionFactor = 10.f;
    for (int i = 0;; i++) {
        if (pixels == resTable[i].pixels) {
            resolutionFactor = (float)resTable[i].factor;
            break;
        } else if (pixels < resTable[i].pixels) {
            if (i == 0) {
                resolutionFactor = (float)resTable[i].factor;
            } else {
                resolutionFactor = ((float)(pixels - resTable[i-1].pixels) / (resTable[i].pixels - resTable[i-1].pixels)) * (resTable[i].factor - resTable[i-1].factor) + resTable[i-1].factor;
            }
            break;
        } else if (resTable[i].pixels == -1) {
            resolutionFactor = (float)resTable[i-1].factor;
            break;
        }
    }

    if (yuv444) {
        resolutionFactor *= 2.f;
    }

    return (int)lroundf(resolutionFactor * frameRateFactor) * 1000;
}

- (struct Resolution)effectiveStreamResolution {
    if (self.liveStreamWidth > 0 && self.liveStreamHeight > 0) {
        struct Resolution live = { self.liveStreamWidth, self.liveStreamHeight };
        return live;
    }
    return [self.class getResolution];
}

// The auto bitrate inputs mirror the values used when the stream was started.
- (NSInteger)automaticBitrateKbpsForRunningStream {
    NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    struct Resolution res = [self.class getResolution];
    int width = res.width;
    int height = res.height;
    int fps = [[[[DataManager alloc] init] getSettings].framerate intValue];

    BOOL scaleEnabled = prefs ? [prefs[@"streamResolutionScale"] boolValue] : NO;
    int scaleRatio = prefs ? [prefs[@"streamResolutionScaleRatio"] intValue] : 100;
    if (scaleEnabled && scaleRatio > 0 && scaleRatio != 100) {
        width = ((width * scaleRatio / 100) / 8) * 8;
        height = ((height * scaleRatio / 100) / 8) * 8;
    }
    if ([prefs[@"remoteResolution"] boolValue]) {
        int rw = [prefs[@"remoteResolutionWidth"] intValue];
        int rh = [prefs[@"remoteResolutionHeight"] intValue];
        if (rw > 0 && rh > 0) {
            width = rw;
            height = rh;
        }
    }
    if ([prefs[@"remoteFps"] boolValue]) {
        int rfps = [prefs[@"remoteFpsRate"] intValue];
        if (rfps > 0) {
            fps = rfps;
        }
    }
    width &= ~1;
    height &= ~1;
    return [StreamViewController automaticBitrateKbpsForWidth:width
                                                        height:height
                                                           fps:fps
                                                        yuv444:self.sessionEffectiveYuv444];
}

- (Connection *)liveStreamConnectionIfSupported {
    Connection *connection = self.streamMan.connection;
    if (connection == nil || ![connection supportsLiveStreamChanges] || self.reconnectInProgress ||
        self.stopStreamInProgress) {
        return nil;
    }
    return connection;
}

- (void)noteLiveChangeFailedWithResult:(int)result what:(NSString *)what {
    Log(LOG_W, @"[live] %@ not applied (result=%d), falling back to reconnect", what, result);
}

- (BOOL)applyLiveBitrateKbps:(NSInteger)kbps {
    Connection *connection = [self liveStreamConnectionIfSupported];
    if (connection == nil || kbps <= 0 || kbps > INT_MAX) {
        return NO;
    }
    int result = [connection sendLiveStreamBitrateKbps:(int)kbps];
    if (result != 0) {
        [self noteLiveChangeFailedWithResult:result what:@"bitrate"];
        return NO;
    }
    [connection.renderer updateLiveStreamFrameRate:0 bitrateKbps:(int)kbps];
    NSString *mbps = kbps < 1000 ? [NSString stringWithFormat:@"%.1f", kbps / 1000.0]
                                  : [NSString stringWithFormat:@"%.0f", kbps / 1000.0];
    [self showNotification:[NSString stringWithFormat:MLString(@"Bitrate set to %@ Mbps", nil), mbps]];
    return YES;
}

- (BOOL)applyLiveFramerate:(int)fps {
    Connection *connection = [self liveStreamConnectionIfSupported];
    if (connection == nil || fps <= 0) {
        return NO;
    }
    int result = [connection sendLiveStreamFramerate:fps];
    if (result != 0) {
        [self noteLiveChangeFailedWithResult:result what:@"framerate"];
        return NO;
    }
    [connection.renderer updateLiveStreamFrameRate:fps bitrateKbps:0];
    [self showNotification:[NSString stringWithFormat:MLString(@"Frame rate set to %d FPS", nil), fps]];
    return YES;
}

- (BOOL)applyLiveResolutionWidth:(int)width height:(int)height {
    Connection *connection = [self liveStreamConnectionIfSupported];
    if (connection == nil || width <= 0 || height <= 0) {
        return NO;
    }

    // The live path sends the size as picked. Scaling and the host render mode
    // override change what is actually streamed, so they keep the reconnect path.
    NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    BOOL scaleEnabled = prefs ? [prefs[@"streamResolutionScale"] boolValue] : NO;
    int scaleRatio = prefs ? [prefs[@"streamResolutionScaleRatio"] intValue] : 100;
    if ((scaleEnabled && scaleRatio > 0 && scaleRatio != 100) || [prefs[@"remoteResolution"] boolValue]) {
        return NO;
    }

    int result = [connection sendLiveStreamResolutionWidth:width height:height];
    if (result != 0) {
        [self noteLiveChangeFailedWithResult:result what:@"resolution"];
        return NO;
    }
    [self showNotification:[NSString stringWithFormat:MLString(@"Resolution set to %dx%d", nil), width, height]];
    return YES;
}

#pragma mark - Host resolution notice

- (void)streamResolutionChanged:(uint32_t)width height:(uint32_t)height {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self applyHostStreamResolutionWidth:(int)width height:(int)height];
    });
}

- (void)applyHostStreamResolutionWidth:(int)width height:(int)height {
    if (width <= 0 || height <= 0 || width > 16384 || height > 16384) {
        Log(LOG_W, @"[live] Ignoring invalid host resolution %dx%d", width, height);
        return;
    }
    if (width == self.liveStreamWidth && height == self.liveStreamHeight) {
        return;
    }

    self.liveStreamWidth = width;
    self.liveStreamHeight = height;
    Log(LOG_I, @"[live] Stream resolution is now %dx%d", width, height);

    // The absolute mouse reference is the view size, so only the window shape follows the stream.
    NSWindow *window = self.view.window;
    NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    if (window == nil || [prefs[@"ignoreAspectRatio"] boolValue]) {
        return;
    }

    NSSize aspect = NSMakeSize(width, height);
    if (self.savedContentAspectRatioValid) {
        // Borderless mode keeps the screen shape active and restores this on exit.
        self.savedContentAspectRatio = aspect;
        return;
    }
    window.contentAspectRatio = aspect;
    if ((window.styleMask & NSWindowStyleMaskFullScreen) == 0 &&
        (window.styleMask & NSWindowStyleMaskTitled) != 0) {
        NSSize content = window.contentView.bounds.size;
        if (content.width > 0 && content.height > 0) {
            NSSize target = NSMakeSize(content.width, round(content.width * height / (CGFloat)width));
            [window setContentSize:target];
        }
    }
}

@end
