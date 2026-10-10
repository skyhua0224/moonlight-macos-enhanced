//
//  StreamViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 25/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "StreamViewController_Internal.h"
#import "RemoteUSBForwardingSession.h"

static NSScreen *MLScreenContainingMouseLocation(void) {
    NSPoint mouseLocation = [NSEvent mouseLocation];
    for (NSScreen *screen in [NSScreen screens]) {
        if (NSPointInRect(mouseLocation, screen.frame)) {
            return screen;
        }
    }
    return [NSScreen mainScreen];
}

static const NSTimeInterval MLClipboardMonitorInterval = 0.25;
static const NSUInteger MLClipboardImageSizeLimit = 4 * 1024 * 1024;
static const NSUInteger MLClipboardBlobSizeLimit = 64 * 1024 * 1024;
static const uint64_t MLClipboardActivationRepeatLogIntervalMs = 1000;
static const uint64_t MLClipboardControlStartupGraceMs = 500;
static const uint64_t MLClipboardFNVOffsetBasis = 14695981039346656037ULL;
static const uint64_t MLClipboardFNVPrime = 1099511628211ULL;
static const uint8_t MLClipboardAgentWireVersion = 1;
static const NSUInteger MLClipboardAgentFrameHeaderSize = 10;
static const NSUInteger MLClipboardAgentInlinePayloadLimit = 60000;

static __weak StreamViewController *MLActiveClipboardController = nil;

typedef NS_ENUM(NSInteger, MLClipboardActivationDiagnosticState) {
    MLClipboardActivationDiagnosticStateIdle = 0,
    MLClipboardActivationDiagnosticStateDisabled = 1,
    MLClipboardActivationDiagnosticStateNotOwner = 2,
    MLClipboardActivationDiagnosticStateNoConnection = 3,
    MLClipboardActivationDiagnosticStateControlNotReady = 4,
};

static uint64_t MLClipboardHashAppend(uint64_t hash, const void *bytes, NSUInteger length) {
    const uint8_t *cursor = bytes;
    for (NSUInteger index = 0; index < length; index++) {
        hash ^= cursor[index];
        hash *= MLClipboardFNVPrime;
    }
    return hash;
}

static NSString *MLNormalizeClipboardText(NSString *text) {
    if (text.length == 0) {
        return text ?: @"";
    }

    NSString *normalized = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    return normalized;
}

static uint64_t MLComputeClipboardHash(uint8_t type, NSData *data, NSString *name) {
    uint64_t hash = MLClipboardFNVOffsetBasis;
    hash = MLClipboardHashAppend(hash, &type, sizeof(type));

    if (data.length > 0) {
        hash = MLClipboardHashAppend(hash, data.bytes, data.length);
    }

    const char *nameUtf8 = name.length > 0 ? name.UTF8String : NULL;
    if (nameUtf8 != NULL) {
        hash = MLClipboardHashAppend(hash, nameUtf8, strlen(nameUtf8));
    }

    return hash;
}

static uint64_t MLGenerateClipboardItemId(void) {
    return (((uint64_t)LiGetMillis()) << 16) ^ (uint64_t)arc4random();
}

static NSData *MLClipboardAgentEncodeFrame(uint8_t kind, uint32_t token, NSData *payload) {
    if (payload == nil || payload.length > MLClipboardAgentInlinePayloadLimit) {
        return nil;
    }

    NSMutableData *frame = [NSMutableData dataWithCapacity:MLClipboardAgentFrameHeaderSize + payload.length];
    uint8_t version = MLClipboardAgentWireVersion;
    uint32_t tokenLE = CFSwapInt32HostToLittle(token);
    uint32_t lengthLE = CFSwapInt32HostToLittle((uint32_t)payload.length);
    [frame appendBytes:&version length:sizeof(version)];
    [frame appendBytes:&kind length:sizeof(kind)];
    [frame appendBytes:&tokenLE length:sizeof(tokenLE)];
    [frame appendBytes:&lengthLE length:sizeof(lengthLE)];
    [frame appendData:payload];
    return frame;
}

static BOOL MLClipboardAgentDecodeFrame(const uint8_t *bytes,
                                        NSUInteger length,
                                        uint8_t *kind,
                                        uint32_t *token,
                                        NSData **payload) {
    if (bytes == NULL || length < MLClipboardAgentFrameHeaderSize ||
        bytes[0] != MLClipboardAgentWireVersion || kind == NULL ||
        token == NULL || payload == NULL) {
        return NO;
    }

    uint32_t tokenLE = 0;
    uint32_t payloadLengthLE = 0;
    memcpy(&tokenLE, bytes + 2, sizeof(tokenLE));
    memcpy(&payloadLengthLE, bytes + 6, sizeof(payloadLengthLE));
    uint32_t payloadLength = CFSwapInt32LittleToHost(payloadLengthLE);
    if (payloadLength > MLClipboardAgentInlinePayloadLimit ||
        length < MLClipboardAgentFrameHeaderSize + payloadLength) {
        return NO;
    }

    uint8_t decodedKind = bytes[1];
    if (decodedKind != LI_CLIPBOARD_KIND_TEXT &&
        decodedKind != LI_CLIPBOARD_KIND_PNG &&
        decodedKind != LI_CLIPBOARD_KIND_REF) {
        return NO;
    }

    *kind = decodedKind;
    *token = CFSwapInt32LittleToHost(tokenLE);
    *payload = [NSData dataWithBytes:bytes + MLClipboardAgentFrameHeaderSize
                               length:payloadLength];
    return YES;
}

@interface MLClipboardItemSnapshot : NSObject

@property(nonatomic, assign) uint8_t type;
@property(nonatomic, strong) NSData *data;
@property(nonatomic, copy) NSString *mimeType;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, assign) uint64_t itemId;
@property(nonatomic, assign) uint64_t contentHash;
@property(nonatomic, assign) uint32_t flags;

+ (instancetype)snapshotWithClipboardItem:(const LI_CLIPBOARD_ITEM *)item;

@end

@implementation MLClipboardItemSnapshot

+ (instancetype)snapshotWithClipboardItem:(const LI_CLIPBOARD_ITEM *)item {
    if (item == NULL) {
        return nil;
    }

    MLClipboardItemSnapshot *snapshot = [[MLClipboardItemSnapshot alloc] init];
    snapshot.type = item->type;
    snapshot.data = item->length > 0 && item->data != NULL
        ? [NSData dataWithBytes:item->data length:item->length]
        : [NSData data];
    snapshot.mimeType = item->mimeType != NULL ? [NSString stringWithUTF8String:item->mimeType] : nil;
    snapshot.name = item->name != NULL ? [NSString stringWithUTF8String:item->name] : nil;
    snapshot.itemId = item->itemId;
    snapshot.contentHash = item->contentHash;
    snapshot.flags = item->flags;
    return snapshot;
}

@end

@interface MLStreamScopedConnectionCallbacks : NSObject <ConnectionCallbacks>

- (instancetype)initWithOwner:(id<MLStreamScopedCallbackOwner>)owner generation:(NSUInteger)generation;

@end

@implementation MLStreamScopedConnectionCallbacks {
    __weak id<MLStreamScopedCallbackOwner> _owner;
    NSUInteger _generation;
}

- (instancetype)initWithOwner:(id<MLStreamScopedCallbackOwner>)owner generation:(NSUInteger)generation {
    self = [super init];
    if (self) {
        _owner = owner;
        _generation = generation;
    }
    return self;
}

- (BOOL)forwardIfCurrentNamed:(NSString *)name block:(void (^)(id<MLStreamScopedCallbackOwner> owner))block {
    id<MLStreamScopedCallbackOwner> owner = _owner;
    if (!owner) {
        Log(LOG_W, @"[diag] Dropping stream callback with no owner: %@ gen=%lu",
            name ?: @"unknown",
            (unsigned long)_generation);
        return NO;
    }
    if (![owner isActiveStreamGeneration:_generation]) {
        Log(LOG_I, @"[diag] Ignoring stale stream callback: %@ gen=%lu",
            name ?: @"unknown",
            (unsigned long)_generation);
        return NO;
    }
    if (block) {
        block(owner);
    }
    return YES;
}

- (void)connectionStarted {
    [self forwardIfCurrentNamed:@"connectionStarted" block:^(id<MLStreamScopedCallbackOwner> owner) {
        [owner connectionStarted];
    }];
}

- (void)connectionTerminated:(int)errorCode {
    [self forwardIfCurrentNamed:@"connectionTerminated" block:^(id<MLStreamScopedCallbackOwner> owner) {
        [owner connectionTerminated:errorCode];
    }];
}

- (void)stageStarting:(const char *)stageName {
    [self forwardIfCurrentNamed:@"stageStarting" block:^(id<MLStreamScopedCallbackOwner> owner) {
        [owner stageStarting:stageName];
    }];
}

- (void)stageComplete:(const char *)stageName {
    [self forwardIfCurrentNamed:@"stageComplete" block:^(id<MLStreamScopedCallbackOwner> owner) {
        [owner stageComplete:stageName];
    }];
}

- (void)stageFailed:(const char *)stageName withError:(int)errorCode {
    [self forwardIfCurrentNamed:@"stageFailed" block:^(id<MLStreamScopedCallbackOwner> owner) {
        [owner stageFailed:stageName withError:errorCode];
    }];
}

- (void)launchFailed:(NSString *)message {
    [self forwardIfCurrentNamed:@"launchFailed" block:^(id<MLStreamScopedCallbackOwner> owner) {
        [owner launchFailed:message];
    }];
}

- (void)rumble:(unsigned short)controllerNumber
 lowFreqMotor:(unsigned short)lowFreqMotor
highFreqMotor:(unsigned short)highFreqMotor {
    [self forwardIfCurrentNamed:@"rumble" block:^(id<MLStreamScopedCallbackOwner> owner) {
        [owner rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
    }];
}

- (void)rumbleTriggers:(unsigned short)controllerNumber
      leftTriggerMotor:(unsigned short)leftTriggerMotor
     rightTriggerMotor:(unsigned short)rightTriggerMotor {
    [self forwardIfCurrentNamed:@"rumbleTriggers" block:^(id<MLStreamScopedCallbackOwner> owner) {
        if ([owner respondsToSelector:@selector(rumbleTriggers:leftTriggerMotor:rightTriggerMotor:)]) {
            [owner rumbleTriggers:controllerNumber leftTriggerMotor:leftTriggerMotor rightTriggerMotor:rightTriggerMotor];
        }
    }];
}

- (void)setControllerLED:(unsigned short)controllerNumber
                       red:(unsigned char)red
                     green:(unsigned char)green
                      blue:(unsigned char)blue {
    [self forwardIfCurrentNamed:@"setControllerLED" block:^(id<MLStreamScopedCallbackOwner> owner) {
        if ([owner respondsToSelector:@selector(setControllerLED:red:green:blue:)]) {
            [owner setControllerLED:controllerNumber red:red green:green blue:blue];
        }
    }];
}

- (void)setAdaptiveTriggers:(unsigned short)controllerNumber
                 eventFlags:(unsigned char)eventFlags
                   typeLeft:(unsigned char)typeLeft
                  typeRight:(unsigned char)typeRight
                       left:(const unsigned char *)left
                      right:(const unsigned char *)right {
    NSData *leftPayload = left != NULL ? [NSData dataWithBytes:left length:DS_EFFECT_PAYLOAD_SIZE] : nil;
    NSData *rightPayload = right != NULL ? [NSData dataWithBytes:right length:DS_EFFECT_PAYLOAD_SIZE] : nil;
    [self forwardIfCurrentNamed:@"setAdaptiveTriggers" block:^(id<MLStreamScopedCallbackOwner> owner) {
        if ([owner respondsToSelector:@selector(setAdaptiveTriggers:eventFlags:typeLeft:typeRight:left:right:)]) {
            [owner setAdaptiveTriggers:controllerNumber eventFlags:eventFlags typeLeft:typeLeft typeRight:typeRight
                                   left:leftPayload.bytes right:rightPayload.bytes];
        }
    }];
}

- (void)ds5HapticsIrV2:(const LI_DS5_HAPTICS_IR_FRAME_V2 *)frame {
    [self forwardIfCurrentNamed:@"ds5HapticsIrV2" block:^(id<MLStreamScopedCallbackOwner> owner) {
        if ([owner respondsToSelector:@selector(ds5HapticsIrV2:)]) [owner ds5HapticsIrV2:frame];
    }];
}

- (void)ds5HapticsPcm:(const LI_DS5_HAPTICS_PCM_FRAME *)frame {
    [self forwardIfCurrentNamed:@"ds5HapticsPcm" block:^(id<MLStreamScopedCallbackOwner> owner) {
        if ([owner respondsToSelector:@selector(ds5HapticsPcm:)]) {
            [owner ds5HapticsPcm:frame];
        }
    }];
}

/**
 * Queues a host motion request on main and revalidates the stream generation there.
 *
 * The stream-scoped proxy forwards only to its still-current owner, preventing requests from
 * a superseded stream from configuring the replacement backend. Safe for native callback threads.
 * @param controllerNumber Host controller slot.
 * @param motionType Protocol sensor type.
 * @param reportRateHz Requested sensor frequency in Hz, or zero to stop reporting.
 */
- (void)setMotionEventState:(unsigned short)controllerNumber
                  motionType:(unsigned char)motionType
                reportRateHz:(unsigned short)reportRateHz {
    // Recheck the stream generation after queueing, before choosing a backend.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self forwardIfCurrentNamed:@"setMotionEventState" block:^(id<MLStreamScopedCallbackOwner> owner) {
            if ([owner respondsToSelector:@selector(setMotionEventState:motionType:reportRateHz:)]) {
                [owner setMotionEventState:controllerNumber motionType:motionType reportRateHz:reportRateHz];
            }
        }];
    });
}

- (void)connectionStatusUpdate:(int)status {
    [self forwardIfCurrentNamed:@"connectionStatusUpdate" block:^(id<MLStreamScopedCallbackOwner> owner) {
        [owner connectionStatusUpdate:status];
    }];
}

- (void)clipboardItemReceived:(const LI_CLIPBOARD_ITEM *)item {
    [self forwardIfCurrentNamed:@"clipboardItemReceived" block:^(id<MLStreamScopedCallbackOwner> owner) {
        if ([owner respondsToSelector:@selector(clipboardItemReceived:)]) {
            [owner clipboardItemReceived:item];
        }
    }];
}

- (void)clipboardDataReceived:(const uint8_t *)data length:(uint32_t)length {
    NSData *frame = data != NULL && length > 0 ? [NSData dataWithBytes:data length:length] : nil;
    [self forwardIfCurrentNamed:@"clipboardDataReceived" block:^(id<MLStreamScopedCallbackOwner> owner) {
        if ([owner respondsToSelector:@selector(clipboardDataReceived:length:)]) {
            [owner clipboardDataReceived:frame.bytes length:(uint32_t)frame.length];
        }
    }];
}

@end

@implementation StreamViewController

/**
 * Selects the controller backend from the effective host/global preference on main.
 * DualSense input follows the same explicit choice as other pads, keeping stream routing
 * consistent with HIDSupport's delivery gate.
 * @return YES when GameController is selected; NO for direct HID.
 */
- (BOOL)useSystemControllerDriver {
    return [SettingsClass controllerDriverFor:self.app.host.uuid] == 1;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.cursorHiddenCounter = 0;
    self.isMouseCaptured = NO;
    self.disconnectWasUserInitiated = NO;
    self.suppressConnectionWarningsUntilMs = 0;
    self.pendingDisconnectSource = nil;
    self.currentStreamRiskAssessment = nil;
    self.lastOptionUncaptureAtMs = 0;
    self.stopStreamInProgress = NO;
    self.shouldAttemptReconnect = YES;
    self.reconnectAttemptCount = 0;
    self.reconnectInProgress = NO;
    self.connectWatchdogToken = 0;
    self.didAutoReconnectAfterTimeout = NO;
    self.streamOpQueue = [[NSOperationQueue alloc] init];
    self.streamOpQueue.maxConcurrentOperationCount = 1;
    self.streamHealthSawPayload = NO;
    self.streamHealthNoPayloadStreak = 0;
    self.streamHealthNoDecodeStreak = 0;
    self.streamHealthNoRenderStreak = 0;
    self.streamHealthHighDropStreak = 0;
    self.streamHealthLastPayloadReconnectMs = 0;
    self.streamHealthConnectionStartedMs = 0;
    self.lastConnectionStatus = -1;
    self.connectionPoorStatusBurstCount = 0;
    self.connectionPoorStatusBurstWindowStartMs = 0;
    self.connectionLastIdrRequestMs = 0;
    self.runtimeAutoBitrateCapKbps = 0;
    self.runtimeAutoBitrateBaselineKbps = 0;
    self.runtimeAutoBitrateStableStreak = 0;
    self.runtimeAutoBitrateLastRaiseMs = 0;
    self.isRemoteDesktopMode = [[SettingsClass mouseModeFor:self.app.host.uuid] isEqualToString:@"remote"];
    self.pendingFreeMouseReentryEdge = MLFreeMouseExitEdgeNone;
    self.pendingFreeMouseReentryAtMs = 0;
    self.suppressFreeMouseEdgeUncaptureUntilMs = 0;

    self.hideFullscreenControlBall = [[NSUserDefaults standardUserDefaults] boolForKey:[self fullscreenControlBallDefaultsKey]];
    self.edgeMenuDockEdge = [self defaultEdgeMenuDockEdge];
    self.edgeMenuButtonEdgeRatio = 0.5;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:[self fullscreenControlBallDockSideDefaultsKey]];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:[self fullscreenControlBallVerticalRatioDefaultsKey]];
    
    [self prepareForStreaming];

    __weak typeof(self) weakSelf = self;

    self.windowDidExitFullScreenNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidExitFullScreenNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            weakSelf.fullscreenTransitionInProgress = NO;
            [weakSelf logCurrentWindowStateWithContext:@"window-did-exit-fullscreen"];
            if (weakSelf.pendingWindowMode == PendingWindowModeBorderless) {
                weakSelf.pendingWindowMode = PendingWindowModeNone;
                [weakSelf applyBorderlessMode];
            } else if (weakSelf.pendingWindowMode == PendingWindowModeWindowed) {
                weakSelf.pendingWindowMode = PendingWindowModeNone;
                [weakSelf applyWindowedMode];
            }

            [weakSelf requestStreamMenuEntrypointsVisibilityUpdate];
            if ([weakSelf.view.window isKeyWindow]) {
                [weakSelf uncaptureMouseWithCode:@"MUC001" reason:@"window-exited-fullscreen"];
                [weakSelf rearmMouseCaptureIfPossibleWithReason:@"window-exited-fullscreen"];
                [weakSelf scheduleDeferredMouseCaptureRearmWithReason:@"window-exited-fullscreen" delay:0.12];
                [weakSelf scheduleDeferredMouseCaptureRearmWithReason:@"window-exited-fullscreen" delay:0.35];
                [weakSelf scheduleDeferredMouseCaptureRearmWithReason:@"window-exited-fullscreen" delay:0.70];
            }
            if (weakSelf.pendingCloseWindowAfterFullscreenExit) {
                weakSelf.pendingCloseWindowAfterFullscreenExit = NO;
                [weakSelf requestSafeCloseOfStreamWindow];
            }
        }
    }];

    self.windowDidEnterFullScreenNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidEnterFullScreenNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            weakSelf.fullscreenTransitionInProgress = NO;
            [weakSelf logCurrentWindowStateWithContext:@"window-did-enter-fullscreen"];
            [weakSelf requestStreamMenuEntrypointsVisibilityUpdate];
            [weakSelf scheduleDeferredStreamMenuEntrypointsVisibilityRetries];
            if ([weakSelf isWindowInCurrentSpace]) {
                if ([weakSelf isWindowFullscreen]) {
                    if ([weakSelf.view.window isKeyWindow]) {
                        [weakSelf uncaptureMouseWithCode:@"MUC002" reason:@"window-entered-fullscreen"];
                        [weakSelf rearmMouseCaptureIfPossibleWithReason:@"window-entered-fullscreen"];
                        [weakSelf scheduleDeferredMouseCaptureRearmWithReason:@"window-entered-fullscreen" delay:0.12];
                        [weakSelf scheduleDeferredMouseCaptureRearmWithReason:@"window-entered-fullscreen" delay:0.35];
                        [weakSelf scheduleDeferredMouseCaptureRearmWithReason:@"window-entered-fullscreen" delay:0.70];
                    }
                }
            }
        }
    }];
    
    self.windowDidResignKeyNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResignKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            [weakSelf logKeyLossDiagnosticsForStage:@"received" code:@"MUC003" reason:@"window-resigned-key"];
            if ([weakSelf shouldSuppressTransientKeyLossUncaptureForCode:@"MUC003" reason:@"window-resigned-key"]) {
                [weakSelf logKeyLossDiagnosticsForStage:@"skip-top-edge-click" code:@"MUC003" reason:@"window-resigned-key"];
                [weakSelf logMouseUncaptureStage:@"skip-top-edge-click" code:@"MUC003" reason:@"window-resigned-key"];
                [weakSelf scheduleTransientKeyLossRecoveryWithReason:@"window-resigned-key"];
                return;
            }
            [weakSelf requestMouseUncaptureWhenSafeWithReason:@"window-resigned-key" code:@"MUC003"];
        }
    }];
    self.windowDidBecomeKeyNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            if ([weakSelf isWindowInCurrentSpace]) {
                if ([weakSelf.view.window isKeyWindow]) {
                    [weakSelf claimClipboardSyncOwnershipIfNeeded];
                    Log(LOG_D, @"[diag] Window became key; rearming input capture (fullscreen=%d style=%llu level=%ld)",
                        [weakSelf isWindowFullscreen] ? 1 : 0,
                        (unsigned long long)weakSelf.view.window.styleMask,
                        (long)weakSelf.view.window.level);
                    [weakSelf prepareCoreHIDFreeMouseStateForFocusRegainWithReason:@"window-became-key"];
                    [weakSelf uncaptureMouseWithCode:@"MUC004" reason:@"window-became-key"];
                    [weakSelf rearmMouseCaptureIfPossibleWithReason:@"window-became-key"];
                    [weakSelf scheduleDeferredMouseCaptureRearmWithReason:@"window-became-key" delay:0.10];
                    [weakSelf scheduleDeferredMouseCaptureRearmWithReason:@"window-became-key" delay:0.28];
                    [weakSelf scheduleDeferredMouseCaptureRearmWithReason:@"window-became-key" delay:0.60];
                }
            }
        } else {
            [weakSelf logKeyLossDiagnosticsForStage:@"received" code:@"MUC005" reason:@"other-window-became-key"];
            if ([weakSelf shouldSuppressTransientKeyLossUncaptureForCode:@"MUC005" reason:@"other-window-became-key"]) {
                [weakSelf logKeyLossDiagnosticsForStage:@"skip-top-edge-click" code:@"MUC005" reason:@"other-window-became-key"];
                [weakSelf logMouseUncaptureStage:@"skip-top-edge-click" code:@"MUC005" reason:@"other-window-became-key"];
                [weakSelf scheduleTransientKeyLossRecoveryWithReason:@"other-window-became-key"];
                return;
            }
            [weakSelf requestMouseUncaptureWhenSafeWithReason:@"other-window-became-key" code:@"MUC005"];
        }
    }];
    
    self.windowWillCloseNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            [weakSelf beginStopStreamIfNeededWithReason:@"window-will-close"]; 
        }
    }];

    self.appDidResignActiveObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidResignActiveNotification object:NSApp queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        weakSelf.globalInactivePointerInsideStreamView = NO;
        [weakSelf requestMouseUncaptureWhenSafeWithReason:@"app-resigned-active" code:@"MUC006"];
    }];
    self.appDidBecomeActiveObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidBecomeActiveNotification object:NSApp queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        weakSelf.globalInactivePointerInsideStreamView = NO;
        if ([weakSelf isWindowInCurrentSpace] && [weakSelf isCurrentPointerInsideStreamView]) {
            [weakSelf ensureStreamWindowKeyIfPossible];
        }
        [weakSelf prepareCoreHIDFreeMouseStateForFocusRegainWithReason:@"app-became-active"];
        [weakSelf rearmMouseCaptureIfPossibleWithReason:@"app-became-active"];
        [weakSelf scheduleDeferredMouseCaptureRearmWithReason:@"app-became-active" delay:0.10];
        [weakSelf scheduleDeferredMouseCaptureRearmWithReason:@"app-became-active" delay:0.28];
        [weakSelf scheduleDeferredMouseCaptureRearmWithReason:@"app-became-active" delay:0.60];
    }];

    self.activeSpaceDidChangeObserver = [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (strongSelf.stopStreamInProgress || strongSelf.reconnectInProgress) {
            return;
        }
        NSWindow *window = strongSelf.view.window;
        BOOL appActive = [NSApp isActive];
        BOOL windowInCurrentSpace = [strongSelf isWindowInCurrentSpace];
        BOOL windowKey = window != nil && window.isKeyWindow;
        BOOL windowMain = window != nil && window.isMainWindow;
        BOOL shouldReleaseForActiveSpaceChange = !appActive || !windowKey || !windowMain ||
            (!windowInCurrentSpace && !strongSelf.fullscreenTransitionInProgress);
        strongSelf.spaceTransitionInProgress = YES;
        [strongSelf logPointerContextForReason:@"active-space-changed"];
        Log(LOG_I, @"[diag] Active space change decision: release=%d appActive=%d currentSpace=%d key=%d main=%d captured=%d fullscreen=%d fullscreenTransition=%d remoteDesktop=%d",
            shouldReleaseForActiveSpaceChange ? 1 : 0,
            appActive ? 1 : 0,
            windowInCurrentSpace ? 1 : 0,
            windowKey ? 1 : 0,
            windowMain ? 1 : 0,
            strongSelf.isMouseCaptured ? 1 : 0,
            [strongSelf isWindowFullscreen] ? 1 : 0,
            strongSelf.fullscreenTransitionInProgress ? 1 : 0,
            strongSelf.isRemoteDesktopMode ? 1 : 0);
        if (shouldReleaseForActiveSpaceChange) {
            [strongSelf requestMouseUncaptureWhenSafeWithReason:@"active-space-changed" code:@"MUC007"];
        } else {
            [strongSelf logMouseUncaptureStage:@"skip-still-active" code:@"MUC007" reason:@"active-space-changed"];
        }
        if (!windowInCurrentSpace) {
            [strongSelf hideEdgeMenuForInactiveSpaceIfNeeded];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!strongSelf) {
                return;
            }
            strongSelf.spaceTransitionInProgress = NO;
            if (strongSelf.stopStreamInProgress || strongSelf.reconnectInProgress) {
                return;
            }
            if (![strongSelf isWindowInCurrentSpace]) {
                [strongSelf hideEdgeMenuForInactiveSpaceIfNeeded];
                return;
            }
            [strongSelf requestStreamMenuEntrypointsVisibilityUpdate];
            [strongSelf scheduleDeferredStreamMenuEntrypointsVisibilityRetries];
            if ([strongSelf isWindowInCurrentSpace] && strongSelf.view.window.isKeyWindow) {
                    [strongSelf rearmMouseCaptureIfPossibleWithReason:@"space-transition-finished"];
                    [strongSelf scheduleDeferredMouseCaptureRearmWithReason:@"space-transition-finished" delay:0.12];
                    [strongSelf scheduleDeferredMouseCaptureRearmWithReason:@"space-transition-finished" delay:0.35];
                    [strongSelf scheduleDeferredMouseCaptureRearmWithReason:@"space-transition-finished" delay:0.75];
            }
        });
    }];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleMouseModeToggledNotification:) name:HIDMouseModeToggledNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleGamepadQuitNotification:) name:HIDGamepadQuitNotification object:nil];

    // Listen for disconnect requests from the session manager
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleSessionDisconnectRequest:) name:@"StreamingSessionRequestDisconnect" object:nil];

    [self installStreamMenuEntrypoints];
}

- (void)handleSessionDisconnectRequest:(NSNotification *)note {
    NSString *hostUUID = note.userInfo[@"hostUUID"];
    NSNumber *quitApp = note.userInfo[@"quitApp"];
    Log(LOG_I, @"[diag] Session disconnect request received: requestHost=%@ currentHost=%@ quitApp=%@ userInfo=%@",
        hostUUID ?: @"(nil)",
        self.app.host.uuid ?: @"(nil)",
        quitApp != nil ? (quitApp.boolValue ? @"1" : @"0") : @"(nil)",
        note.userInfo ?: @{});

    if (hostUUID && self.app.host.uuid && ![hostUUID isEqualToString:self.app.host.uuid]) {
        return;
    }

    if (quitApp != nil) {
        if (quitApp.boolValue) {
            [self performCloseAndQuitApp:nil];
        } else {
            [self requestStreamCloseWithSource:@"session-manager-request"];
        }
        return;
    }

    // Programmatic disconnect requests should not show a confirmation alert.
    [self requestStreamCloseWithSource:@"session-manager-request-legacy"];
}

- (void)beginStopStreamIfNeededWithReason:(NSString *)reason {
    [self beginStopStreamIfNeededWithReason:reason completion:nil];
}

/**
 * Begins one stream teardown, disabling input and invalidating stream-scoped callbacks.
 *
 * Clears input contexts after releasing controller state, removes lifecycle observers/timers,
 * and stops native streaming on a background queue with controller cleanup on main. Call from
 * main-thread lifecycle handling. A repeated call schedules its completion immediately rather
 * than waiting for the first teardown to finish.
 * @param reason Diagnostic teardown reason; nil uses fallback diagnostic labels.
 * @param completion Optional block dispatched to main after this stop, or immediately if already stopping.
 */
- (void)beginStopStreamIfNeededWithReason:(NSString *)reason completion:(void (^)(void))completion {
    @synchronized (self) {
        if (self.stopStreamInProgress) {
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), completion);
            }
            return;
        }
        self.stopStreamInProgress = YES;
        self.activeStreamGeneration += 1;
    }

    [self stopStreamHealthDiagnostics];
    [[MLRemoteUSBForwardingSession sharedSession] stop];
    [self logStreamHealthSummaryWithReason:[NSString stringWithFormat:@"begin-stop:%@", reason ?: @"unknown"]];
    [self finalizeInputDiagnosticsWithReason:reason];
    [[AwdlHelperManager sharedManager] endStreamSessionWithReason:reason ?: @"begin-stop"];
    [self tearDownStreamLifecycleObserversAndTimers];

    self.hidSupport.shouldSendInputEvents = NO;
    self.hidSupport.shouldSendControllerEvents = NO;
    self.controllerSupport.shouldSendInputEvents = NO;
    self.hidSupport.inputContext = NULL;
    self.controllerSupport.inputContext = NULL;

    [self broadcastHostOnlineStateForExit];

    // If we are closing while in borderless, ensure we restore system UI state and window constraints.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self restorePresentationOptionsIfNeeded];
        if (self.savedContentAspectRatioValid && self.view.window) {
            @try {
                self.view.window.contentAspectRatio = self.savedContentAspectRatio;
            } @catch (NSException *exception) {
                // ignore
            }
            self.savedContentAspectRatioValid = NO;
        }
    });

    // If we are intentionally stopping, don't attempt auto-reconnect.
    self.shouldAttemptReconnect = NO;
    self.reconnectInProgress = NO;

    // Treat window close / quit shortcuts as a user-initiated disconnect to avoid
    // showing transient "connection is slow" warnings during teardown.
    [self markUserInitiatedDisconnectAndSuppressWarningsForSeconds:2.0 reason:reason];

    // Stopping the stream can block while common-c tears down sockets/ENet.
    // Do cleanup/stop off the main thread so window close doesn't feel like a hang.
    __strong typeof(self) strongSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        double start = CACurrentMediaTime();
        if (strongSelf.controllerSupport != nil) {
            double cleanupStart = CACurrentMediaTime();
            dispatch_sync(dispatch_get_main_queue(), ^{
                [strongSelf tearDownControllerSupportOnMainThreadIfNeeded];
            });
            Log(LOG_I, @"Controller cleanup took %.3fs", CACurrentMediaTime() - cleanupStart);
        }

        double stopStart = CACurrentMediaTime();
        [strongSelf.streamMan stopStream];
        Log(LOG_I, @"Stream stop took %.3fs (total %.3fs)", CACurrentMediaTime() - stopStart, CACurrentMediaTime() - start);

        // Ensure streaming state is cleared for this host even if we don't receive a termination callback
        if (self.app.host.uuid) {
            [[StreamingSessionManager shared] didDisconnectForHost:self.app.host.uuid];
        }

        if (completion) {
            dispatch_async(dispatch_get_main_queue(), completion);
        }
    });
}

- (void)broadcastHostOnlineStateForExit {
    if (!self.app.host.uuid) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        self.app.host.state = StateOnline;

        NSMutableDictionary *states = [NSMutableDictionary dictionaryWithDictionary:self.app.host.addressStates ?: @{}];
        if (self.app.host.activeAddress) {
            states[self.app.host.activeAddress] = @(1);
        }
        self.app.host.addressStates = states;

        [[NSNotificationCenter defaultCenter] postNotificationName:@"HostLatencyUpdated"
                                                            object:nil
                                                          userInfo:@{
                                                              @"uuid": self.app.host.uuid,
                                                              @"latencies": self.app.host.addressLatencies ?: @{},
                                                              @"states": states
                                                          }];
    });
}

/**
 * Initializes the visible stream view and installs session settings/lifecycle observers.
 *
 * AppKit calls this on main. Creates input backends, subscribes to live controller preference
 * changes for the active/global profile, and starts stream/window setup. Teardown must remove
 * these observers and timers before replacing or closing the session.
 */
- (void)viewDidAppear {
    [super viewDidAppear];
    
    self.streamView.keyboardNotifiable = self;
    self.streamView.appName = self.app.name;
    self.streamView.statusText = @"Starting";
    self.view.window.tabbingMode = NSWindowTabbingModeDisallowed;
    self.view.window.delegate = self;
    [self prepareStreamWindowChromeForStreamingIfNeeded];
    [self.view.window makeFirstResponder:self];

    [self installLocalKeyMonitorIfNeeded];
    [self installLocalMouseClickMonitorIfNeeded];
    [self installGlobalMouseMonitorIfNeeded];
    [self installMouseTrackingArea];
    
    NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    BOOL ignoreAspectRatio = prefs ? [prefs[@"ignoreAspectRatio"] boolValue] : NO;

    if (!ignoreAspectRatio) {
        int width = [self.class getResolution].width;
        int height = [self.class getResolution].height;

        BOOL scaleEnabled = prefs ? [prefs[@"streamResolutionScale"] boolValue] : NO;
        int ratio = prefs ? [prefs[@"streamResolutionScaleRatio"] intValue] : 100;
        if (scaleEnabled && ratio > 0 && ratio != 100) {
            int scaledWidth = width * ratio / 100;
            int scaledHeight = height * ratio / 100;
            width = (scaledWidth / 8) * 8;
            height = (scaledHeight / 8) * 8;
        }

        self.view.window.contentAspectRatio = NSMakeSize(width, height);
    }
    self.view.window.frameAutosaveName = @"Stream Window";
    
    struct Resolution res = [self.class getResolution];
    CGFloat aspectRatio = (res.height > 0) ? ((CGFloat)res.width / (CGFloat)res.height) : (16.0 / 9.0);
    CGFloat initialW = 1280.0;
    CGFloat initialH = initialW / aspectRatio;

    // Sanity check for portrait streams or extreme aspect ratios to avoid huge windows
    if (initialH > 900.0) {
        initialH = 900.0;
        initialW = initialH * aspectRatio;
    }

    NSScreen *preferredScreen = MLScreenContainingMouseLocation();
    NSString *autosaveKey = [NSString stringWithFormat:@"NSWindow Frame %@", self.view.window.frameAutosaveName];
    BOOL hasSavedFrame = [[NSUserDefaults standardUserDefaults] stringForKey:autosaveKey].length > 0;
    if (hasSavedFrame) {
        [self.view.window moonlight_centerWindowOnScreen:preferredScreen];
    } else {
        [self.view.window setFrame:NSMakeRect(0, 0, initialW, initialH) display:NO];
        [self.view.window moonlight_centerWindowOnScreen:preferredScreen];
    }
    
    self.view.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];

    NSInteger displayMode = [SettingsClass displayModeFor:self.app.host.uuid];
    if (displayMode == 1 && ![self isWindowFullscreen] && !self.fullscreenTransitionInProgress) {
        Log(LOG_I, @"[diag] Priming startup fullscreen before connection handshake");
        [self applyStartupDisplayMode:displayMode];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateWindowSubtitle];
        [self updateConfiguredShortcutMenus];
        [self requestStreamMenuEntrypointsVisibilityUpdate];
        if ([self.view.window isKeyWindow]) {
            [self claimClipboardSyncOwnershipIfNeeded];
        }

        if (!self.streamStartDate) {
            self.streamStartDate = [NSDate date];
        }
        [self startControlCenterTimerIfNeeded];
    });

    __weak typeof(self) weakSelf = self;
    self.settingsDidChangeObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [weakSelf updateWindowSubtitle];
        [weakSelf refreshInputDiagnosticsPreference];
    }];
    self.streamShortcutSettingsDidChangeObserver = [[NSNotificationCenter defaultCenter] addObserverForName:@"MoonlightStreamShortcutsDidChange" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        NSString *hostId = note.userInfo[@"hostId"];
        if (hostId.length > 0 &&
            ![hostId isEqualToString:@"__global__"] &&
            ![hostId isEqualToString:strongSelf.app.host.uuid]) {
            return;
        }

        [strongSelf updateConfiguredShortcutMenus];
    }];
    self.mouseSettingsDidChangeObserver = [[NSNotificationCenter defaultCenter] addObserverForName:@"MoonlightMouseSettingsDidChange" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        NSString *hostId = note.userInfo[@"hostId"];
        if (hostId.length > 0 &&
            ![hostId isEqualToString:@"__global__"] &&
            ![hostId isEqualToString:strongSelf.app.host.uuid]) {
            return;
        }

        NSString *setting = note.userInfo[@"setting"];
        [strongSelf applyLiveMouseSettingsRefreshForSetting:setting];
    }];
    self.controllerSettingsDidChangeObserver = [[NSNotificationCenter defaultCenter] addObserverForName:@"MoonlightControllerSettingsDidChange" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        NSString *hostId = note.userInfo[@"hostId"];
        if (hostId.length > 0 &&
            ![hostId isEqualToString:@"__global__"] &&
            ![hostId isEqualToString:strongSelf.app.host.uuid]) {
            return;
        }

        [strongSelf refreshControllerInputSendingState];
    }];
    self.hostLatencyUpdatedObserver = [[NSNotificationCenter defaultCenter] addObserverForName:@"HostLatencyUpdated" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [weakSelf updateWindowSubtitle];
    }];

    self.logDidAppendObserver = [[NSNotificationCenter defaultCenter] addObserverForName:MoonlightLogDidAppendNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        NSString *line = note.userInfo[MoonlightLogNotificationLineKey];
        if (line) {
            [weakSelf appendLogLineToOverlay:line];
        }
    }];
}

- (void)updateWindowSubtitle {
    NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    NSString *method = prefs[@"connectionMethod"];

    NSString* (^addressLabel)(NSString*) = ^NSString* (NSString* addr) {
        if (!addr) {
            return MLString(@"Unknown", nil);
        }

        NSNumber *state = self.app.host.addressStates[addr];
        NSNumber *latency = self.app.host.addressLatencies[addr];
        BOOL online = state ? (state.intValue == 1) : YES;

        if (!online) {
            return [NSString stringWithFormat:@"%@ (%@)", addr, MLString(@"Offline", nil)];
        }
        if (latency && latency.intValue >= 0) {
            NSString *latencyText = [self formattedLatencyTextForDisplay:latency];
            return [NSString stringWithFormat:@"%@ (%@)", addr, latencyText ?: MLString(@"Online", nil)];
        }
        return addr;
    };

    NSString *subtitle = nil;
    if (method && ![method isEqualToString:@"Auto"]) {
        subtitle = [NSString stringWithFormat:@"%@ (%@)", MLString(@"Manual", nil), addressLabel(method)];
    } else {
        subtitle = [NSString stringWithFormat:@"%@ (%@)", MLString(@"Auto", nil), addressLabel(self.app.host.activeAddress)];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        self.view.window.subtitle = subtitle;
    });
}

- (void)dealloc {
    [[AwdlHelperManager sharedManager] endStreamSessionWithReason:@"stream-view-controller-dealloc"];
    [self releaseClipboardSyncOwnershipWithUnbind:NO];
    [self restoreStreamWindowChromeIfNeeded];
    [self tearDownStreamLifecycleObserversAndTimers];

    [self removeMenuTitlebarAccessoryFromWindowIfNeeded];
    self.menuTitlebarAccessory = nil;
    self.menuTitlebarButton = nil;
    self.controlCenterPill = nil;
    self.controlCenterSignalImageView = nil;
    self.controlCenterTimeLabel = nil;
    self.controlCenterTitleLabel = nil;

    [self.edgeMenuAutoCollapseTimer invalidate];
    self.edgeMenuAutoCollapseTimer = nil;

    if (self.streamHealthTimer) {
        [self.streamHealthTimer invalidate];
        self.streamHealthTimer = nil;
    }

    if (self.localKeyDownMonitor) {
        [NSEvent removeMonitor:self.localKeyDownMonitor];
        self.localKeyDownMonitor = nil;
    }
    if (self.localModifierMonitor) {
        [NSEvent removeMonitor:self.localModifierMonitor];
        self.localModifierMonitor = nil;
    }
    if (self.localMouseClickMonitor) {
        [NSEvent removeMonitor:self.localMouseClickMonitor];
        self.localMouseClickMonitor = nil;
    }
    if (self.globalMouseMovedMonitor) {
        [NSEvent removeMonitor:self.globalMouseMovedMonitor];
        self.globalMouseMovedMonitor = nil;
    }
    self.globalInactivePointerInsideStreamView = NO;

    if (self.mouseTrackingArea) {
        [self.view removeTrackingArea:self.mouseTrackingArea];
        self.mouseTrackingArea = nil;
    }

    if (self.edgeMenuButtonTrackingArea && self.edgeMenuButton) {
        [self.edgeMenuButton removeTrackingArea:self.edgeMenuButtonTrackingArea];
        self.edgeMenuButtonTrackingArea = nil;
    }

    if (self.edgeMenuPanel.parentWindow) {
        [self.edgeMenuPanel.parentWindow removeChildWindow:self.edgeMenuPanel];
    }
    [self.edgeMenuPanel orderOut:nil];
    [self.edgeMenuPanel close];
    self.edgeMenuPanel = nil;

    [self stopInputDiagnosticsTimer];
    [self tearDownControllerSupportOnMainThreadIfNeeded];
    [self.hidSupport tearDownHidManager];
    self.hidSupport = nil;
}

- (void)tearDownControllerSupportOnMainThreadIfNeeded {
    if (![NSThread isMainThread]) {
        NSAssert(NO, @"tearDownControllerSupportOnMainThreadIfNeeded must run on the main thread");
        return;
    }

    if (self.controllerSupport == nil) {
        return;
    }

    self.controllerSupport.shouldSendInputEvents = NO;
    self.controllerSupport.inputContext = NULL;
    [self.controllerSupport cleanup];
    self.controllerSupport = nil;
}

/**
 * Resolves controller delivery for both backends from stream readiness and capture policy.
 *
 * Delivery requires a ready context with neither stop nor reconnect in progress, plus captured
 * keyboard/mouse input or the profile's background preference. Applies that preference to
 * process-wide GameController background monitoring, updates both controller gates and logs
 * the decision. Off-main calls asynchronously reschedule themselves on main.
 */
- (void)refreshControllerInputSendingState {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshControllerInputSendingState];
        });
        return;
    }

    BOOL streamCanSendInput = !self.stopStreamInProgress &&
        !self.reconnectInProgress &&
        [self hasReadyInputContext];
    BOOL focusedInputEnabled = self.hidSupport.shouldSendInputEvents;
    BOOL backgroundInputEnabled =
        [SettingsClass backgroundControllerInputFor:self.app.host.uuid];
    if (@available(macOS 11.3, *)) {
        GCController.shouldMonitorBackgroundEvents = backgroundInputEnabled;
    }
    BOOL shouldSendControllerInput = streamCanSendInput &&
        (focusedInputEnabled || backgroundInputEnabled);

    self.hidSupport.shouldSendControllerEvents = shouldSendControllerInput;
    self.controllerSupport.shouldSendInputEvents = shouldSendControllerInput;
    Log(LOG_I, @"Controller input state updated: enabled=%d focusedInput=%d background=%d ready=%d",
        shouldSendControllerInput ? 1 : 0,
        focusedInputEnabled ? 1 : 0,
        backgroundInputEnabled ? 1 : 0,
        streamCanSendInput ? 1 : 0);
}

/**
 * Removes stream lifecycle/settings observers and invalidates session timers.
 *
 * Includes the controller-settings observer so a closed stream cannot react to live preference
 * changes. Clears observer references for repeated teardown; call on main for UI-owned timers.
 */
- (void)tearDownStreamLifecycleObserversAndTimers {
    NSNotificationCenter *defaultCenter = [NSNotificationCenter defaultCenter];

    if (self.windowDidExitFullScreenNotification != nil) {
        [defaultCenter removeObserver:self.windowDidExitFullScreenNotification];
        self.windowDidExitFullScreenNotification = nil;
    }
    if (self.windowDidEnterFullScreenNotification != nil) {
        [defaultCenter removeObserver:self.windowDidEnterFullScreenNotification];
        self.windowDidEnterFullScreenNotification = nil;
    }
    if (self.windowDidResignKeyNotification != nil) {
        [defaultCenter removeObserver:self.windowDidResignKeyNotification];
        self.windowDidResignKeyNotification = nil;
    }
    if (self.windowDidBecomeKeyNotification != nil) {
        [defaultCenter removeObserver:self.windowDidBecomeKeyNotification];
        self.windowDidBecomeKeyNotification = nil;
    }
    if (self.windowWillCloseNotification != nil) {
        [defaultCenter removeObserver:self.windowWillCloseNotification];
        self.windowWillCloseNotification = nil;
    }
    if (self.appDidBecomeActiveObserver != nil) {
        [defaultCenter removeObserver:self.appDidBecomeActiveObserver];
        self.appDidBecomeActiveObserver = nil;
    }
    if (self.appDidResignActiveObserver != nil) {
        [defaultCenter removeObserver:self.appDidResignActiveObserver];
        self.appDidResignActiveObserver = nil;
    }
    if (self.settingsDidChangeObserver != nil) {
        [defaultCenter removeObserver:self.settingsDidChangeObserver];
        self.settingsDidChangeObserver = nil;
    }
    if (self.streamShortcutSettingsDidChangeObserver != nil) {
        [defaultCenter removeObserver:self.streamShortcutSettingsDidChangeObserver];
        self.streamShortcutSettingsDidChangeObserver = nil;
    }
    if (self.mouseSettingsDidChangeObserver != nil) {
        [defaultCenter removeObserver:self.mouseSettingsDidChangeObserver];
        self.mouseSettingsDidChangeObserver = nil;
    }
    if (self.controllerSettingsDidChangeObserver != nil) {
        [defaultCenter removeObserver:self.controllerSettingsDidChangeObserver];
        self.controllerSettingsDidChangeObserver = nil;
    }
    if (self.hostLatencyUpdatedObserver != nil) {
        [defaultCenter removeObserver:self.hostLatencyUpdatedObserver];
        self.hostLatencyUpdatedObserver = nil;
    }
    if (self.logDidAppendObserver != nil) {
        [defaultCenter removeObserver:self.logDidAppendObserver];
        self.logDidAppendObserver = nil;
    }

    [defaultCenter removeObserver:self name:HIDMouseModeToggledNotification object:nil];
    [defaultCenter removeObserver:self name:HIDGamepadQuitNotification object:nil];
    [defaultCenter removeObserver:self name:@"StreamingSessionRequestDisconnect" object:nil];

    if (self.activeSpaceDidChangeObserver != nil) {
        [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self.activeSpaceDidChangeObserver];
        self.activeSpaceDidChangeObserver = nil;
    }

    if (self.controlCenterTimer != nil) {
        [self.controlCenterTimer invalidate];
        self.controlCenterTimer = nil;
    }
    if (self.notificationTimer != nil) {
        [self.notificationTimer invalidate];
        self.notificationTimer = nil;
    }
    if (self.statsTimer != nil) {
        [self.statsTimer invalidate];
        self.statsTimer = nil;
    }
    if (self.streamHealthTimer != nil) {
        [self.streamHealthTimer invalidate];
        self.streamHealthTimer = nil;
    }
    if (self.inputDiagnosticsTimer != nil) {
        [self.inputDiagnosticsTimer invalidate];
        self.inputDiagnosticsTimer = nil;
    }
    if (self.edgeMenuAutoCollapseTimer != nil) {
        [self.edgeMenuAutoCollapseTimer invalidate];
        self.edgeMenuAutoCollapseTimer = nil;
    }

    if (self.localKeyDownMonitor != nil) {
        [NSEvent removeMonitor:self.localKeyDownMonitor];
        self.localKeyDownMonitor = nil;
    }
    if (self.localModifierMonitor != nil) {
        [NSEvent removeMonitor:self.localModifierMonitor];
        self.localModifierMonitor = nil;
    }
    if (self.localMouseClickMonitor != nil) {
        [NSEvent removeMonitor:self.localMouseClickMonitor];
        self.localMouseClickMonitor = nil;
    }
    if (self.globalMouseMovedMonitor != nil) {
        [NSEvent removeMonitor:self.globalMouseMovedMonitor];
        self.globalMouseMovedMonitor = nil;
    }
    self.globalInactivePointerInsideStreamView = NO;

    if (self.hidSupport != nil) {
        [self.hidSupport setFreeMouseVirtualCursorActive:NO];
        [self.hidSupport resetFreeMouseVirtualCursorState];
        self.hidSupport.freeMouseAbsoluteSyncHandler = nil;
    }
}

- (BOOL)isWindowBorderlessMode {
    if (!self.view.window) {
        return NO;
    }
    BOOL isFullscreen = [self isWindowFullscreen];
    return ((self.view.window.styleMask & NSWindowStyleMaskTitled) == 0) && !isFullscreen;
}

- (StreamViewMac *)streamView {
    return (StreamViewMac *)self.view;
}


#pragma mark - Streaming Operations

- (void)prepareForStreaming {
    [self stopStreamHealthDiagnostics];
    [self resetStreamHealthDiagnostics];
    self.pendingDisconnectSource = nil;
    self.activeStreamGeneration += 1;
    NSUInteger streamGeneration = self.activeStreamGeneration;
    [self releaseClipboardSyncOwnershipWithUnbind:NO];
    self.clipboardRuntimeConnection = nil;
    LiSetThreadConnectionContext(NULL);

    // Defensive cleanup: avoid overlapping stream operations when a previous attempt
    // hasn't fully quiesced yet.
    StreamManager *previousStreamMan = self.streamMan;
    self.streamMan = nil;
    if (self.streamOpQueue) {
        [self.streamOpQueue cancelAllOperations];
    }
    if (previousStreamMan) {
        [previousStreamMan stopStream];
    }

    StreamConfiguration *streamConfig = [[StreamConfiguration alloc] init];
    
    streamConfig.host = self.app.host.activeAddress;
    streamConfig.hostUUID = self.app.host.uuid;
    
    NSDictionary* prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    NSString *selectedConnectionMethod = nil;
    if (prefs) {
        selectedConnectionMethod = prefs[@"connectionMethod"];
        if (selectedConnectionMethod && ![selectedConnectionMethod isEqualToString:@"Auto"]) {
            streamConfig.host = selectedConnectionMethod;
        }
    }
    Log(LOG_I, @"[diag] Stream target selection: method=%@ active=%@ local=%@ address=%@ external=%@ ipv6=%@",
        selectedConnectionMethod ?: @"Auto",
        self.app.host.activeAddress ?: @"",
        self.app.host.localAddress ?: @"",
        self.app.host.address ?: @"",
        self.app.host.externalAddress ?: @"",
        self.app.host.ipv6Address ?: @"");

    BOOL vpnActive = [Utils isActiveNetworkVPN];
    BOOL remoteByAddress = [self isRemoteStreamTargetAddress:streamConfig.host];
    NSString *egressSource = nil;
    NSString *egressIf = [Utils outboundInterfaceNameForAddress:streamConfig.host sourceAddress:&egressSource];
    BOOL routeKnown = egressIf.length > 0;
    BOOL remoteByRoute = routeKnown && [Utils isTunnelInterfaceName:egressIf];
    BOOL remoteByVpnFallback = vpnActive && !routeKnown;
    streamConfig.streamingRemotely = remoteByAddress || remoteByRoute || remoteByVpnFallback;

    NSMutableArray<NSString *> *reasonParts = [NSMutableArray array];
    if (streamConfig.streamingRemotely) {
        if (remoteByRoute) {
            [reasonParts addObject:[NSString stringWithFormat:@"route-via-%@", egressIf]];
        }
        if (remoteByAddress) {
            [reasonParts addObject:@"address-public-or-external"];
        }
        if (remoteByVpnFallback) {
            [reasonParts addObject:@"vpn-fallback-no-route"];
        }
    } else {
        if (routeKnown) {
            [reasonParts addObject:[NSString stringWithFormat:@"route-via-%@", egressIf]];
        } else {
            [reasonParts addObject:@"route-unknown-no-vpn"];
        }
        if (!remoteByAddress) {
            [reasonParts addObject:@"address-private-or-local"];
        }
    }
    NSString *classifyReason = reasonParts.count > 0 ? [reasonParts componentsJoinedByString:@","] : @"n/a";

    Log(LOG_I, @"[diag] Stream target classification: host=%@ remote=%d local=%d vpn=%d byAddress=%d byRoute=%d byVpnFallback=%d egressIf=%@ source=%@ main=%@ ipv6=%@ external=%@ reason=%@",
        streamConfig.host ?: @"(null)",
        streamConfig.streamingRemotely ? 1 : 0,
        streamConfig.streamingRemotely ? 0 : 1,
        vpnActive ? 1 : 0,
        remoteByAddress ? 1 : 0,
        remoteByRoute ? 1 : 0,
        remoteByVpnFallback ? 1 : 0,
        egressIf ?: @"(unknown)",
        egressSource ?: @"",
        self.app.host.localAddress ?: @"",
        self.app.host.ipv6Address ?: @"",
        self.app.host.externalAddress ?: @"",
        classifyReason);
    
    streamConfig.appID = self.app.id;
    streamConfig.appName = self.app.name;
    streamConfig.serverCert = self.app.host.serverCert;
    streamConfig.serverCodecModeSupport = self.app.host.serverCodecModeSupport;
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];
    
    streamConfig.width = [self.class getResolution].width;
    streamConfig.height = [self.class getResolution].height;

    streamConfig.frameRate = [streamSettings.framerate intValue];

    // Apply resolution scaling (mirrors moonlight-qt behavior)
    BOOL scaleEnabled = prefs ? [prefs[@"streamResolutionScale"] boolValue] : NO;
    int scaleRatio = prefs ? [prefs[@"streamResolutionScaleRatio"] intValue] : 100;
    if (scaleEnabled && scaleRatio > 0 && scaleRatio != 100) {
        int scaledWidth = streamConfig.width * scaleRatio / 100;
        int scaledHeight = streamConfig.height * scaleRatio / 100;
        streamConfig.width = (scaledWidth / 8) * 8;
        streamConfig.height = (scaledHeight / 8) * 8;
    }

    // Default bitrate (may be overridden by auto-adjust below)
    streamConfig.bitRate = [streamSettings.bitrate intValue];

    BOOL enableYuv444 = prefs ? [prefs[@"yuv444"] boolValue] : NO;
    streamConfig.videoRendererMode = prefs[@"videoRendererMode"] != nil ? [prefs[@"videoRendererMode"] intValue] : 2;
    int modeWidth = streamConfig.width;
    int modeHeight = streamConfig.height;
    int modeFps = streamConfig.frameRate;

    // Incorporate remote overrides (host render mode) for bitrate calculation and risk assessment
    if (prefs != nil) {
        if ([prefs[@"remoteResolution"] boolValue]) {
            int rw = [prefs[@"remoteResolutionWidth"] intValue];
            int rh = [prefs[@"remoteResolutionHeight"] intValue];
            if (rw > 0 && rh > 0) {
                modeWidth = rw;
                modeHeight = rh;
            }
        }
        if ([prefs[@"remoteFps"] boolValue]) {
            int rfps = [prefs[@"remoteFpsRate"] intValue];
            if (rfps > 0) {
                modeFps = rfps;
            }
        }

        NSNumber *hdrTransferFunction = prefs[@"hdrTransferFunction"];
        streamConfig.hdrTransferFunction = hdrTransferFunction != nil ? [hdrTransferFunction intValue] : 0;
        streamConfig.hdrMetadataSource = prefs[@"hdrMetadataSource"] != nil ? [prefs[@"hdrMetadataSource"] intValue] : 2;
        streamConfig.hdrClientDisplayProfile = prefs[@"hdrClientDisplayProfile"] != nil ? [prefs[@"hdrClientDisplayProfile"] intValue] : 0;
        streamConfig.hdrManualMaxBrightness = prefs[@"hdrManualMaxBrightness"] != nil ? [prefs[@"hdrManualMaxBrightness"] doubleValue] : 1000.0;
        streamConfig.hdrManualMinBrightness = prefs[@"hdrManualMinBrightness"] != nil ? [prefs[@"hdrManualMinBrightness"] doubleValue] : 0.001;
        streamConfig.hdrManualMaxAverageBrightness = prefs[@"hdrManualMaxAverageBrightness"] != nil ? [prefs[@"hdrManualMaxAverageBrightness"] doubleValue] : 1000.0;
        streamConfig.hdrOpticalOutputScale = prefs[@"hdrOpticalOutputScale"] != nil ? [prefs[@"hdrOpticalOutputScale"] doubleValue] : 100.0;
        streamConfig.hdrHlgViewingEnvironment = prefs[@"hdrHlgViewingEnvironment"] != nil ? [prefs[@"hdrHlgViewingEnvironment"] intValue] : 0;
        streamConfig.hdrEdrStrategy = prefs[@"hdrEdrStrategy"] != nil ? [prefs[@"hdrEdrStrategy"] intValue] : 0;
        streamConfig.hdrToneMappingPolicy = prefs[@"hdrToneMappingPolicy"] != nil ? [prefs[@"hdrToneMappingPolicy"] intValue] : 0;

        if (self.hasSessionSunshineTargetDisplayOverride) {
            streamConfig.sunshineTargetDisplayName = self.sessionSunshineTargetDisplayNameOverride ?: @"";
        } else {
            NSString *targetDisplayName = [prefs[@"sunshineTargetDisplayName"] isKindOfClass:[NSString class]]
                ? prefs[@"sunshineTargetDisplayName"] : nil;
            if (targetDisplayName.length > 0) {
                streamConfig.sunshineTargetDisplayName = targetDisplayName;
            }
        }

        BOOL requestedUseVdd = self.sessionSunshineUseVirtualDisplayOverride != nil
            ? self.sessionSunshineUseVirtualDisplayOverride.boolValue
            : [prefs[@"sunshineUseVirtualDisplay"] boolValue];
        streamConfig.sunshineUseVirtualDisplay = requestedUseVdd &&
            [SettingsClass sunshineVddSupportsFor:self.app.host.uuid];
        if (requestedUseVdd && !streamConfig.sunshineUseVirtualDisplay) {
            Log(LOG_W, @"[sunshine] Ignoring useVdd=1 because the latest display topology probe reports VDD unsupported");
        }
        streamConfig.sunshineScreenMode = self.sessionSunshineScreenModeOverride != nil
            ? self.sessionSunshineScreenModeOverride.intValue
            : (prefs[@"sunshineScreenMode"] != nil ? [prefs[@"sunshineScreenMode"] intValue] : -1);
        streamConfig.sunshineTouchKeyboardAutoInvoke = [prefs[@"sunshineTouchKeyboardAutoInvoke"] boolValue];
        streamConfig.sunshineHdrBrightnessOverride = [prefs[@"sunshineHdrBrightnessOverride"] boolValue];
        streamConfig.sunshineMaxBrightness = prefs[@"sunshineMaxBrightness"] != nil ? [prefs[@"sunshineMaxBrightness"] doubleValue] : 1000.0;
        streamConfig.sunshineMinBrightness = prefs[@"sunshineMinBrightness"] != nil ? [prefs[@"sunshineMinBrightness"] doubleValue] : 0.001;
        streamConfig.sunshineMaxAverageBrightness = prefs[@"sunshineMaxAverageBrightness"] != nil ? [prefs[@"sunshineMaxAverageBrightness"] doubleValue] : 1000.0;
    }

    // Keep even dimensions
    modeWidth &= ~1;
    modeHeight &= ~1;

    // Auto-adjust bitrate (mirrors moonlight-qt default algorithm)
    BOOL autoAdjustBitrate = prefs ? [prefs[@"autoAdjustBitrate"] boolValue] : NO;
    streamConfig.autoAdjustBitrate = autoAdjustBitrate;
    if (!autoAdjustBitrate) {
        self.runtimeAutoBitrateCapKbps = 0;
        self.runtimeAutoBitrateBaselineKbps = 0;
        self.runtimeAutoBitrateStableStreak = 0;
        self.runtimeAutoBitrateLastRaiseMs = 0;
    }
    if (autoAdjustBitrate) {
        // Copied from moonlight-qt (StreamingPreferences::getDefaultBitrate)
        float frameRateFactor = (modeFps <= 60 ? (float)modeFps : (sqrtf((float)modeFps / 60.f) * 60.f)) / 30.f;

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

        int pixels = modeWidth * modeHeight;
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

        if (enableYuv444) {
            resolutionFactor *= 2.f;
        }

        int defaultKbps = (int)lroundf(resolutionFactor * frameRateFactor) * 1000;
        streamConfig.bitRate = defaultKbps;
        self.runtimeAutoBitrateBaselineKbps = streamConfig.bitRate;
        if (self.runtimeAutoBitrateCapKbps > 0 && self.runtimeAutoBitrateCapKbps > streamConfig.bitRate) {
            self.runtimeAutoBitrateCapKbps = streamConfig.bitRate;
        }
        if (self.runtimeAutoBitrateCapKbps > 0 && streamConfig.bitRate > self.runtimeAutoBitrateCapKbps) {
            Log(LOG_I, @"[diag] Runtime auto bitrate cap applied: %d -> %ld kbps",
                streamConfig.bitRate,
                (long)self.runtimeAutoBitrateCapKbps);
            streamConfig.bitRate = (int)self.runtimeAutoBitrateCapKbps;
        }
    }
    streamConfig.optimizeGameSettings = streamSettings.optimizeGames;
    streamConfig.playAudioOnPC = streamSettings.playAudioOnPC;
    NSInteger codecPreference = [SettingsClass videoCodecFor:self.app.host.uuid];
    streamConfig.videoCodecPreference = (int)MAX(0, MIN(codecPreference, 2));

    BOOL hevcDecodeSupported = NO;
    if (@available(iOS 11.3, tvOS 11.3, macOS 10.14, *)) {
        hevcDecodeSupported = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);
    }
    BOOL av1DecodeSupported = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1);

    streamConfig.allowHevc = streamConfig.videoCodecPreference != 0;
    if (streamConfig.videoCodecPreference == 2) {
        streamConfig.enableHdr = streamSettings.enableHdr && av1DecodeSupported;
    } else if (streamConfig.videoCodecPreference == 1) {
        streamConfig.enableHdr = streamSettings.enableHdr && hevcDecodeSupported;
    } else {
        streamConfig.enableHdr = NO;
    }
    streamConfig.enable10BitSdr = [SettingsClass enable10BitSdrFor:self.app.host.uuid] &&
                                  !streamConfig.enableHdr &&
                                  streamConfig.videoCodecPreference != 0 &&
                                  (streamConfig.videoCodecPreference == 2 ? av1DecodeSupported : hevcDecodeSupported);

    NSString *codecName = @"H.264";
    if (streamConfig.videoCodecPreference == 2) {
        codecName = @"AV1";
    } else if (streamConfig.videoCodecPreference == 1) {
        codecName = @"H.265";
    }
    self.currentStreamRiskAssessment = [StreamRiskAssessor assessWithHost:self.app.host
                                                            targetAddress:streamConfig.host
                                                         connectionMethod:selectedConnectionMethod
                                                                    width:modeWidth
                                                                   height:modeHeight
                                                                      fps:modeFps
                                                              bitrateKbps:streamConfig.bitRate
                                                                codecName:codecName
                                                             enableYUV444:enableYuv444
                                                                 autoMode:autoAdjustBitrate];
    Log(LOG_I, @"[diag] Stream risk assessment: %@ codec=%@ chroma=%@ decode=%d target=%@",
        self.currentStreamRiskAssessment.summaryLine ?: @"(none)",
        self.currentStreamRiskAssessment.codecName ?: codecName,
        self.currentStreamRiskAssessment.chromaName ?: (enableYuv444 ? @"4:4:4" : @"4:2:0"),
        self.currentStreamRiskAssessment.decodeSupported ? 1 : 0,
        self.currentStreamRiskAssessment.targetAddress ?: streamConfig.host ?: @"(null)");
    if (self.currentStreamRiskAssessment.recommendedFallbacks.count > 0) {
        StreamRiskRecommendation *firstRecommendation = self.currentStreamRiskAssessment.recommendedFallbacks.firstObject;
        Log(LOG_I, @"[diag] Recommended fallback: %@", firstRecommendation.summaryLine ?: @"(none)");
    }
    if (streamConfig.videoCodecPreference == 2) {
        Log(LOG_I, @"[diag] AV1 preference: serverAdvertises=%d localDecode=%d hdr=%d yuv444=%d",
            (self.app.host.serverCodecModeSupport & SCM_MASK_AV1) != 0 ? 1 : 0,
            av1DecodeSupported ? 1 : 0,
            streamConfig.enableHdr ? 1 : 0,
            enableYuv444 ? 1 : 0);
    }

    streamConfig.multiController = streamSettings.multiController;
    streamConfig.gamepadMask = self.useSystemControllerDriver ? (int)[ControllerSupport getConnectedGamepadMask:streamConfig] : 1;
    
    NSInteger audioConfigSelection = [SettingsClass audioConfigurationFor:self.app.host.uuid];
    int audioConfig = AUDIO_CONFIGURATION_STEREO;
    if (audioConfigSelection == 1) {
        audioConfig = AUDIO_CONFIGURATION_51_SURROUND;
    } else if (audioConfigSelection == 2) {
        audioConfig = AUDIO_CONFIGURATION_71_SURROUND;
    } else if (audioConfigSelection == 3) {
        audioConfig = AUDIO_CONFIGURATION_714_SURROUND;
    }
    int audioOutputMode = (int)[SettingsClass audioOutputModeFor:self.app.host.uuid];
    streamConfig.audioOutputMode = audioOutputMode;
    streamConfig.disableHighQualitySurround =
        (audioOutputMode == 1 && audioConfig == AUDIO_CONFIGURATION_714_SURROUND);
    streamConfig.audioConfiguration = audioConfig;
    streamConfig.enhancedAudioOutputTarget = (int)[SettingsClass enhancedAudioOutputTargetFor:self.app.host.uuid];
    streamConfig.enhancedAudioPreset = (int)[SettingsClass enhancedAudioPresetFor:self.app.host.uuid];
    streamConfig.enhancedAudioSpatialIntensity = [SettingsClass enhancedAudioSpatialIntensityFor:self.app.host.uuid];
    streamConfig.enhancedAudioSoundstageWidth = [SettingsClass enhancedAudioSoundstageWidthFor:self.app.host.uuid];
    streamConfig.enhancedAudioReverbAmount = [SettingsClass enhancedAudioReverbAmountFor:self.app.host.uuid];
    streamConfig.enhancedAudioEQGains = [SettingsClass enhancedAudioEQGainsFor:self.app.host.uuid];
    if (streamConfig.disableHighQualitySurround) {
        Log(LOG_I, @"[diag] Using 7.1.4 compatibility audio topology for Enhanced mode");
    }
    
    streamConfig.framePacingMode = (int)[SettingsClass framePacingFor:self.app.host.uuid];
    streamConfig.smoothnessLatencyMode = (int)[SettingsClass smoothnessLatencyModeFor:self.app.host.uuid];
        streamConfig.timingBufferLevel = (int)[SettingsClass timingBufferLevelFor:self.app.host.uuid];
        streamConfig.timingPrioritizeResponsiveness = [SettingsClass timingPrioritizeResponsivenessFor:self.app.host.uuid];
        streamConfig.timingCompatibilityMode = [SettingsClass timingCompatibilityModeFor:self.app.host.uuid];
        streamConfig.timingSdrCompatibilityWorkaround = [SettingsClass timingSdrCompatibilityWorkaroundFor:self.app.host.uuid];
        streamConfig.enableVsync = [SettingsClass enableVsyncFor:self.app.host.uuid];
        streamConfig.displaySyncMode = prefs[@"displaySyncMode"] != nil ? [prefs[@"displaySyncMode"] intValue] : 0;
        streamConfig.frameQueueTarget = prefs[@"frameQueueTarget"] != nil ? [prefs[@"frameQueueTarget"] intValue] : -1;
        streamConfig.timingResponsivenessBias = prefs[@"timingResponsivenessBias"] != nil ? [prefs[@"timingResponsivenessBias"] intValue] : (streamConfig.timingPrioritizeResponsiveness ? 1 : 0);
        streamConfig.allowDrawableTimeoutMode = prefs[@"allowDrawableTimeoutMode"] != nil ? [prefs[@"allowDrawableTimeoutMode"] intValue] : 0;
    streamConfig.showPerformanceOverlay = [SettingsClass showPerformanceOverlayFor:self.app.host.uuid];
    streamConfig.gamepadMouseMode = [SettingsClass gamepadMouseModeFor:self.app.host.uuid];
    streamConfig.gamepadMouseModeLongPressMenu = [SettingsClass gamepadMouseModeLongPressMenuFor:self.app.host.uuid];
    streamConfig.nativeTouchpad = [SettingsClass nativeTouchpadFor:self.app.host.uuid];
    streamConfig.gamepadTrackpadPointerSensitivity = [SettingsClass pointerSensitivityFor:self.app.host.uuid];
    streamConfig.gamepadTrackpadScrollSpeed = [SettingsClass gestureScrollSpeedFor:self.app.host.uuid];
    streamConfig.gamepadTrackpadReverseScroll = [SettingsClass reverseScrollDirectionFor:self.app.host.uuid];
    streamConfig.gamepadDeadzone = [SettingsClass controllerDeadzoneFor:self.app.host.uuid];
    streamConfig.controllerHapticsMode = [SettingsClass controllerHapticsModeFor:self.app.host.uuid];
    streamConfig.controllerMotionMode = [SettingsClass controllerMotionModeFor:self.app.host.uuid];
    streamConfig.controllerFeedbackTarget = [SettingsClass controllerFeedbackTargetFor:self.app.host.uuid];
    streamConfig.controllerVirtualType = [SettingsClass controllerVirtualTypeFor:self.app.host.uuid];
    // Foundation Sunshine accepts gamepad=ds5 on /launch and /resume. Send
    // it only when a real DualSense is present; other controllers continue to
    // use the standard arrival negotiation.
    if (streamConfig.controllerVirtualType == 3 ||
        (streamConfig.controllerVirtualType != 1 && [ControllerSupport hasDualSenseController])) {
        streamConfig.clientGamepad = @"ds5";
        Log(LOG_I, @"[controller] Declaring gamepad=ds5 for Foundation Sunshine");
    }
    NSDictionary<NSString *, NSNumber *> *controllerCalibration =
        [SettingsClass controllerCalibrationFor:self.app.host.uuid];
    streamConfig.controllerLeftCenterX = controllerCalibration[@"leftCenterX"].doubleValue;
    streamConfig.controllerLeftCenterY = controllerCalibration[@"leftCenterY"].doubleValue;
    streamConfig.controllerRightCenterX = controllerCalibration[@"rightCenterX"].doubleValue;
    streamConfig.controllerRightCenterY = controllerCalibration[@"rightCenterY"].doubleValue;
    streamConfig.controllerLeftGain = controllerCalibration[@"leftGain"].doubleValue;
    streamConfig.controllerRightGain = controllerCalibration[@"rightGain"].doubleValue;
    streamConfig.upscalingMode = (int)[SettingsClass upscalingModeFor:self.app.host.uuid];
    streamConfig.frameInterpolationMode = prefs[@"frameInterpolationMode"] != nil ? [prefs[@"frameInterpolationMode"] intValue] : 0;
    Log(LOG_I, @"[diag] Stream timing config: preset=%d framePacing=%d buffer=%d responsiveness=%d compatibility=%d vsync=%d sdrCompat=%d",
        (int)streamConfig.smoothnessLatencyMode,
        (int)streamConfig.framePacingMode,
        (int)streamConfig.timingBufferLevel,
        streamConfig.timingPrioritizeResponsiveness ? 1 : 0,
        streamConfig.timingCompatibilityMode ? 1 : 0,
        streamConfig.enableVsync ? 1 : 0,
        streamConfig.timingSdrCompatibilityWorkaround ? 1 : 0);
    [[AwdlHelperManager sharedManager] beginStreamSessionIfEnabled:[SettingsClass awdlStabilityHelperEnabled]
                                                        generation:streamGeneration];

    if (self.useSystemControllerDriver) {

        if (@available(iOS 13, tvOS 13, macOS 10.15, *)) {
            self.controllerSupport = [[ControllerSupport alloc] initWithConfig:streamConfig presenceDelegate:self];
        }
    }
    self.hidSupport = [[HIDSupport alloc] init:self.app.host];
    __weak typeof(self) weakSelf = self;
    self.hidSupport.freeMouseAbsoluteSyncHandler = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.isRemoteDesktopMode || !strongSelf.isMouseCaptured) {
            return;
        }
        strongSelf.pendingHybridRemoteCursorSync = NO;
        [strongSelf reconcileHybridFreeMouseAnchorToCurrentPointer];
    };
    [self resetInputDiagnosticsState];
    [self refreshInputDiagnosticsPreference];
    
    id<ConnectionCallbacks> scopedCallbacks = [[MLStreamScopedConnectionCallbacks alloc] initWithOwner:self generation:streamGeneration];
    self.streamMan = [[StreamManager alloc] initWithConfig:streamConfig renderView:self.view connectionCallbacks:scopedCallbacks];
    if (!self.streamOpQueue) {
        self.streamOpQueue = [[NSOperationQueue alloc] init];
        self.streamOpQueue.maxConcurrentOperationCount = 1;
    }
    [self.streamOpQueue addOperation:self.streamMan];

    [self startConnectWatchdog];
    
    // Don’t create the overlay before streaming starts. The video view may be inserted later
    // and would otherwise cover the overlay.
}

+ (struct Resolution)getResolution {
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];

    struct Resolution resolution;
    
    resolution.width = [streamSettings.width intValue];
    resolution.height = [streamSettings.height intValue];

    return resolution;
}


#pragma mark - ConnectionCallbacks

- (void)stageStarting:(const char *)stageName {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *lowerCase = [NSString stringWithFormat:@"%s in progress...", stageName];
        NSString *titleCase = [[[lowerCase substringToIndex:1] uppercaseString] stringByAppendingString:[lowerCase substringFromIndex:1]];
        self.streamView.statusText = titleCase;
    });
}

/**
 * Binds input backends when the native input-stream establishment stage completes.
 *
 * Queues context binding, controller-policy refresh, microphone readiness and pointer rearming
 * on main after checking the available context. Other stages and a NULL name are ignored.
 * @param stageName Borrowed, NUL-terminated native stage name, inspected synchronously.
 */
- (void)stageComplete:(const char *)stageName {
    if (stageName == NULL) {
        return;
    }

    // Ensure input context is bound as soon as input stream establishment completes.
    if (strcmp(stageName, "input stream establishment") == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            void *inputContext = self.streamMan.connection ? [self.streamMan.connection inputStreamContext] : NULL;
            if (inputContext == NULL) {
                Log(LOG_W, @"Input stream established but inputContext is NULL");
                return;
            }
            PML_INPUT_STREAM_CONTEXT ctx = (PML_INPUT_STREAM_CONTEXT)inputContext;
            Log(LOG_I, @"Input stream established: ctx=%p initialized=%d libInit=%d libConn=%p", ctx, ctx->initialized, LiInputContextIsInitialized(ctx), LiInputContextGetConnectionCtx(ctx));
            if (ctx->initialized) {
                self.hidSupport.inputContext = inputContext;
                self.controllerSupport.inputContext = inputContext;
                self.hidSupport.shouldSendInputEvents = YES;
                [self refreshControllerInputSendingState];
                [self.streamMan.connection notifyInputStreamReadyForMicrophoneControlIfNeeded];
                [self rearmMouseCaptureIfPossibleWithReason:@"input-stream-established"];
            }
        });
    }
}

- (void)scheduleInitialRenderedFrameCheckForGeneration:(NSUInteger)generation remainingAttempts:(NSUInteger)remainingAttempts {
    if (!self.waitingForFirstRenderedFrame || self.activeStreamGeneration != generation) {
        return;
    }

    VideoDecoderRenderer *renderer = self.streamMan.connection.renderer;
    if (renderer != nil) {
        if (renderer.hasPresentedVideo) {
            self.waitingForFirstRenderedFrame = NO;
            self.streamView.statusText = nil;
            Log(LOG_I, @"[diag] First rendered frame observed via startup poll; clearing loading indicator");
            return;
        }
    }

    if (remainingAttempts == 0) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        [strongSelf scheduleInitialRenderedFrameCheckForGeneration:generation remainingAttempts:remainingAttempts - 1];
    });
}

- (void)publishSunshineDisplayRuntimeState:(NSString *)phase {
    if (self.app.host.uuid.length == 0) {
        return;
    }

    NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid] ?: @{};
    NSString *displayName = self.sessionSunshineTargetDisplayNameOverride.length > 0
        ? self.sessionSunshineTargetDisplayNameOverride
        : ([prefs[@"sunshineTargetDisplayName"] isKindOfClass:[NSString class]]
           ? prefs[@"sunshineTargetDisplayName"] : @"");
    BOOL useVdd = self.sessionSunshineUseVirtualDisplayOverride != nil
        ? self.sessionSunshineUseVirtualDisplayOverride.boolValue
        : [prefs[@"sunshineUseVirtualDisplay"] boolValue];
    NSInteger screenMode = self.sessionSunshineScreenModeOverride != nil
        ? self.sessionSunshineScreenModeOverride.integerValue
        : (prefs[@"sunshineScreenMode"] != nil ? [prefs[@"sunshineScreenMode"] integerValue] : -1);

    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"MoonlightSunshineDisplayRuntimeDidChange"
                      object:nil
                    userInfo:@{
                        @"hostKey": self.app.host.uuid,
                        @"phase": phase ?: @"idle",
                        @"displayName": displayName ?: @"",
                        @"useVdd": @(useVdd),
                        @"screenMode": @(screenMode)
                    }];
    Log(LOG_I, @"[sunshine] Display runtime state: phase=%@ host=%@ display=%@ useVdd=%d customScreenMode=%ld",
        phase ?: @"idle",
        self.app.host.uuid,
        displayName.length > 0 ? displayName : @"Host Default",
        useVdd ? 1 : 0,
        (long)screenMode);
}

/**
 * Handles successful stream startup and schedules input/UI activation on main.
 *
 * Binds both input backends, retries briefly if initialization is delayed, refreshes controller
 * delivery after binding and reconnect completion, and starts rendering/overlay diagnostics.
 * May be invoked from the native connection callback thread.
 */
- (void)connectionStarted {
    Log(LOG_I, @"[diag] StreamViewController connectionStarted received: main=%d activeGen=%lu",
        [NSThread isMainThread] ? 1 : 0,
        (unsigned long)self.activeStreamGeneration);
    Connection *callbackConn = [Connection currentConnection];
    void *callbackInputContext = callbackConn ? [callbackConn inputStreamContext] : NULL;
    dispatch_async(dispatch_get_main_queue(), ^{
        Log(LOG_I, @"[diag] StreamViewController connectionStarted main block begin: window=%p callbackConn=%p callbackInput=%p streamConn=%p",
            self.view.window,
            callbackConn,
            callbackInputContext,
            self.streamMan.connection);
        @try {
                // Notify session manager (main-thread only for window access)
                [[StreamingSessionManager shared] startStreamingWithHost:self.app.host.uuid
                                                                                                                     appId:self.app.id
                                                                                                                 appName:self.app.name
                                                                                                windowController:self.view.window.windowController];

                [self resetClipboardActivationDiagnosticState];
                self.clipboardRuntimeConnection = callbackConn ?: self.streamMan.connection;
                Log(LOG_I, @"[clipboard] Runtime clipboard connection selected: callback=%p stream=%p active=%p",
                    callbackConn,
                    self.streamMan.connection,
                    self.clipboardRuntimeConnection);

                void *inputContext = callbackInputContext;
                if (!inputContext && self.streamMan.connection) {
                    inputContext = [self.streamMan.connection inputStreamContext];
                }
                if (inputContext) {
                    PML_INPUT_STREAM_CONTEXT ctx = (PML_INPUT_STREAM_CONTEXT)inputContext;
                    Log(LOG_I, @"Input ABI: size=%u off_init=%u off_conn=%u", LiGetInputContextStructSize(), LiGetInputContextOffsetInitialized(), LiGetInputContextOffsetConnectionContext());
                    Log(LOG_I, @"Binding input context on connection start: ctx=%p initialized=%d libInit=%d libConn=%p", ctx, ctx->initialized, LiInputContextIsInitialized(ctx), LiInputContextGetConnectionCtx(ctx));
                    self.hidSupport.inputContext = inputContext;
                    self.controllerSupport.inputContext = inputContext;
                    // Ensure input is enabled immediately after stream start
                    self.hidSupport.shouldSendInputEvents = YES;
                    [self refreshControllerInputSendingState];

                    // If input stream isn't initialized yet, retry briefly to bind after start
                    __block int remainingAttempts = 20;
                    __weak typeof(self) weakSelf = self;
                    __block void (^retryBind)(void) = nil;
                    __weak void (^weakRetryBind)(void) = nil;
                    retryBind = ^{
                        __strong typeof(weakSelf) strongSelf = weakSelf;
                        if (!strongSelf) {
                            return;
                        }
                        PML_INPUT_STREAM_CONTEXT ctx = (PML_INPUT_STREAM_CONTEXT)inputContext;
                        if (ctx != NULL && LiInputContextIsInitialized(ctx)) {
                            strongSelf.hidSupport.inputContext = inputContext;
                            strongSelf.controllerSupport.inputContext = inputContext;
                            [strongSelf refreshControllerInputSendingState];
                            [strongSelf rearmMouseCaptureIfPossibleWithReason:@"input-context-retry-bound"];
                            return;
                        }
                        if (remainingAttempts-- <= 0) {
                            Log(LOG_W, @"Input context still not initialized after retries");
                            return;
                        }
                        void (^strongRetryBind)(void) = weakRetryBind;
                        if (!strongRetryBind) {
                            return;
                        }
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), strongRetryBind);
                    };
                    weakRetryBind = retryBind;
                    retryBind();
                }

        self.waitingForFirstRenderedFrame = YES;
        self.pendingDisconnectSource = nil;
        [self startStreamHealthDiagnostics];
        self.streamHealthConnectionStartedMs = [self nowMs];
        [self refreshInputDiagnosticsPreference];
        [self scheduleInitialRenderedFrameCheckForGeneration:self.activeStreamGeneration remainingAttempts:80];

        Log(LOG_I, @"connectionStarted (t=%.0fms) window style=%llu level=%ld", CACurrentMediaTime() * 1000.0, (unsigned long long)self.view.window.styleMask, (long)self.view.window.level);

        BOOL wasReconnect = self.reconnectInProgress;
        [self publishSunshineDisplayRuntimeState:wasReconnect ? @"reconnected" : @"active"];
        Log(LOG_I, @"[hdr] Foundation dynamic HDR result: format=%d fallback=%d clientDolbyDirectSurface=0",
            LiGetNegotiatedDynamicHdrFormat(),
            LiGetNegotiatedDynamicHdrFallback());
        if (self.reconnectInProgress) {
            self.reconnectInProgress = NO;
            [self hideReconnectOverlay];
            [self refreshControllerInputSendingState];
        }

        // Create overlay after streaming starts so it stays on top of the video view.
        if ([SettingsClass showPerformanceOverlayFor:self.app.host.uuid] && !self.overlayContainer) {
            [self setupOverlay];
        }
        
        NSInteger displayMode = [SettingsClass displayModeFor:self.app.host.uuid];
        // 0: Windowed, 1: Fullscreen, 2: Borderless Windowed
        
        if (wasReconnect && self.reconnectPreserveFullscreenStateValid) {
            // If we were reconnecting, try to preserve state
            displayMode = self.reconnectPreservedWindowMode;
        }
        self.reconnectPreserveFullscreenStateValid = NO;
        NSString *displayModeName = [self displayModeDebugName:displayMode];
        Log(LOG_I, @"[diag] connectionStarted display mode=%ld (%@) wasReconnect=%d",
            (long)displayMode,
            displayModeName,
            wasReconnect ? 1 : 0);
        [self resetEdgeMenuPlacementForNewStreamSession];
        [self logCurrentWindowStateWithContext:@"connection-started-before-capture"];

        // Make the stream interactive as soon as we have video.
        // Without this, fullscreen transitions can leave input disabled until AppKit
        // finishes space/key-window transitions, which can take several seconds.
        [self captureMouse];
        [self logCurrentWindowStateWithContext:@"connection-started-after-capture"];
        [self claimClipboardSyncOwnershipIfNeeded];
        NSUInteger clipboardRetryGeneration = self.activeStreamGeneration;
        for (NSNumber *delay in @[@0.15, @0.50, @1.00, @2.00, @4.00, @8.00, @12.00]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.activeStreamGeneration != clipboardRetryGeneration) {
                    return;
                }
                if (![self isClipboardSyncOwner] || self.clipboardSessionBound) {
                    return;
                }
                [self activateClipboardBindingIfPossible];
            });
        }

        NSInteger startupDisplayMode = displayMode;
        BOOL startupModeAlreadyPrimed =
            (startupDisplayMode == 1 && ([self isWindowFullscreen] || self.fullscreenTransitionInProgress));
        NSTimeInterval startupDisplayDelay = (startupDisplayMode == 0 || startupModeAlreadyPrimed) ? 0.0 : 0.12;
        Log(LOG_I, @"[diag] Scheduling startup display mode apply: mode=%ld (%@) delay=%.2fs",
            (long)startupDisplayMode,
            displayModeName,
            startupDisplayDelay);
        if (startupModeAlreadyPrimed) {
            Log(LOG_I, @"[diag] Startup display mode already primed; skipping duplicate apply");
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(startupDisplayDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self applyStartupDisplayMode:startupDisplayMode];
            });
        }

        // Re-assert capture shortly after mode switches in case AppKit temporarily steals focus.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((startupDisplayDelay + 0.35) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!self.isMouseCaptured) {
                [self captureMouse];
            }
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            VideoStats stats = (VideoStats){0};
            if (self.streamMan.connection && self.streamMan.connection.renderer) {
                stats = self.streamMan.connection.renderer.videoStats;
            }
            [self logCurrentWindowStateWithContext:@"post-start-checkpoint-1s"];
            Log(LOG_D, @"[diag] Post-start checkpoint: rf=%u df=%u ren=%u total=%u bytes=%llu captured=%d input=%d",
                stats.receivedFrames,
                stats.decodedFrames,
                stats.renderedFrames,
                stats.totalFrames,
                (unsigned long long)stats.receivedBytes,
                self.isMouseCaptured ? 1 : 0,
                self.hidSupport.shouldSendInputEvents ? 1 : 0);
        });
        } @catch (NSException *exception) {
            Log(LOG_E, @"[diag] connectionStarted main block exception: %@ - %@",
                exception.name ?: @"(unknown)",
                exception.reason ?: @"(no reason)");
        }
    });
}

- (void)connectionTerminated:(int)errorCode {
    Log(LOG_I, @"Connection terminated: %ld (0x%08x)", (long)errorCode, (unsigned int)errorCode);
    [self publishSunshineDisplayRuntimeState:@"idle"];
    LiSetThreadConnectionContext(NULL);
    self.clipboardRuntimeConnection = nil;
    self.waitingForFirstRenderedFrame = NO;
    [self stopStreamHealthDiagnostics];
    [[MLRemoteUSBForwardingSession sharedSession] stop];
    [self finalizeInputDiagnosticsWithReason:[NSString stringWithFormat:@"connection-terminated:%d", errorCode]];
    self.streamHealthConnectionStartedMs = 0;
    [self logStreamHealthSummaryWithReason:[NSString stringWithFormat:@"connection-terminated:%d", errorCode]];
    [[AwdlHelperManager sharedManager] endStreamSessionWithReason:[NSString stringWithFormat:@"connection-terminated:%d", errorCode]];

    // Notify session manager
    if (self.app.host.uuid) {
        [[StreamingSessionManager shared] didDisconnectForHost:self.app.host.uuid];
    }

    self.hidSupport.inputContext = NULL;
    self.controllerSupport.inputContext = NULL;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self releaseClipboardSyncOwnershipWithUnbind:NO];
        [self hideConnectionTimeoutOverlay];
        if (self.statsTimer) {
            [self.statsTimer invalidate];
            self.statsTimer = nil;
        }
        if (self.overlayContainer) {
            [self.overlayContainer removeFromSuperview];
            self.overlayContainer = nil;
            self.overlayLabel = nil;
        }
        if (self.mouseModeContainer) {
            [self.mouseModeContainer removeFromSuperview];
            self.mouseModeContainer = nil;
            self.mouseModeLabel = nil;
        }
        if (self.edgeMenuPanel) {
            [self.edgeMenuPanel orderOut:nil];
        }

        if (self.reconnectInProgress) {
            return;
        }
        
        // If it was user initiated, just close normally.
        if (self.disconnectWasUserInitiated) {
             if ([SettingsClass quitAppAfterStreamFor:self.app.host.uuid]) {
                 [self.delegate quitApp:self.app completion:nil];
             } else {
                 [self closeWindowFromMainQueueWithMessage:nil];
             }
             return;
        }
        
        // Once a stream has been established, any termination here should close the stream window
        // instead of leaving the last frame or an error page behind. Launch/setup failures are
        // handled separately by stageFailed/launchFailed.
        if (errorCode != 0) {
            Log(LOG_W, @"[diag] Closing stream window after non-zero termination code: %d", errorCode);
        }

        if ([SettingsClass quitAppAfterStreamFor:self.app.host.uuid]) {
            [self.delegate quitApp:self.app completion:nil];
        } else {
            [self closeWindowFromMainQueueWithMessage:nil];
        }
    });
}

- (void)stageFailed:(const char *)stageName withError:(int)errorCode {
    Log(LOG_I, @"Stage %s failed: %ld", stageName, errorCode);
    [self publishSunshineDisplayRuntimeState:@"failed"];
    self.connectWatchdogToken += 1;
    [self stopStreamHealthDiagnostics];
    [self finalizeInputDiagnosticsWithReason:[NSString stringWithFormat:@"stage-failed:%s", stageName ?: "unknown"]];
    self.streamHealthConnectionStartedMs = 0;
    [[AwdlHelperManager sharedManager] endStreamSessionWithReason:[NSString stringWithFormat:@"stage-failed:%s", stageName ?: "unknown"]];
    if (self.streamMan) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [weakSelf.streamMan stopStream];
        });
    }
    [self closeWindowFromMainQueueWithMessage:[NSString stringWithFormat:@"%s failed with error %d", stageName, errorCode]];
}

- (void)launchFailed:(NSString *)message {
    [self publishSunshineDisplayRuntimeState:@"failed"];
    self.connectWatchdogToken += 1;
    [self stopStreamHealthDiagnostics];
    [self finalizeInputDiagnosticsWithReason:@"launch-failed"];
    self.streamHealthConnectionStartedMs = 0;
    [[AwdlHelperManager sharedManager] endStreamSessionWithReason:@"launch-failed"];
    if (self.streamMan) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [weakSelf.streamMan stopStream];
        });
    }
    [self closeWindowFromMainQueueWithMessage:message];
}

/**
 * Forwards controller rumble to the active backend when profile and delivery gates allow it.
 * @param controllerNumber Host controller slot for GameController; direct HID targets its single device.
 * @param lowFreqMotor Low-frequency motor intensity in the protocol's 16-bit range.
 * @param highFreqMotor High-frequency motor intensity in the protocol's 16-bit range.
 */
- (void)rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor {
    if ([SettingsClass rumbleFor:self.app.host.uuid]) {
        if (self.hidSupport.shouldSendControllerEvents) {
            if (self.controllerSupport != nil) {
                [self.controllerSupport rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
            } else {
                [self.hidSupport rumbleLowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
            }
        }
    }
}

/**
 * Forwards trigger rumble to GameController when rumble and controller delivery are enabled.
 * @param controllerNumber Host controller slot.
 * @param leftTriggerMotor Left-trigger motor intensity in the protocol's 16-bit range.
 * @param rightTriggerMotor Right-trigger motor intensity in the protocol's 16-bit range.
 */
- (void)rumbleTriggers:(unsigned short)controllerNumber
      leftTriggerMotor:(unsigned short)leftTriggerMotor
     rightTriggerMotor:(unsigned short)rightTriggerMotor {
    if (![SettingsClass rumbleFor:self.app.host.uuid] || !self.hidSupport.shouldSendControllerEvents) {
        return;
    }
    [self.controllerSupport rumbleTriggers:controllerNumber leftTriggerMotor:leftTriggerMotor rightTriggerMotor:rightTriggerMotor];
}

/**
 * Forwards controller LED output to GameController only while controller delivery is enabled.
 * @param controllerNumber Host controller slot.
 * @param red Red channel intensity, zero through 255.
 * @param green Green channel intensity, zero through 255.
 * @param blue Blue channel intensity, zero through 255.
 */
- (void)setControllerLED:(unsigned short)controllerNumber
                       red:(unsigned char)red
                     green:(unsigned char)green
                      blue:(unsigned char)blue {
    if (!self.hidSupport.shouldSendControllerEvents) {
        return;
    }
    [self.controllerSupport setControllerLED:controllerNumber red:red green:green blue:blue];
}

/**
 * Forwards adaptive-trigger output to GameController while controller delivery is enabled.
 *
 * The backend consumes the borrowed effect buffers synchronously; this method does not retain them.
 * @param controllerNumber Host controller slot.
 * @param eventFlags Protocol flags identifying the trigger effects to apply.
 * @param typeLeft Protocol left-trigger effect type.
 * @param typeRight Protocol right-trigger effect type.
 * @param left Borrowed left-trigger effect payload in the protocol-defined format.
 * @param right Borrowed right-trigger effect payload in the protocol-defined format.
 */
- (void)setAdaptiveTriggers:(unsigned short)controllerNumber
                 eventFlags:(unsigned char)eventFlags
                   typeLeft:(unsigned char)typeLeft
                  typeRight:(unsigned char)typeRight
                       left:(const unsigned char *)left
                      right:(const unsigned char *)right {
    if (!self.hidSupport.shouldSendControllerEvents) {
        return;
    }
    [self.controllerSupport setAdaptiveTriggers:controllerNumber eventFlags:eventFlags typeLeft:typeLeft typeRight:typeRight left:left right:right];
}

- (void)ds5HapticsIrV2:(const LI_DS5_HAPTICS_IR_FRAME_V2 *)frame {
    if ([SettingsClass rumbleFor:self.app.host.uuid] && self.controllerSupport.shouldSendInputEvents) {
        [self.controllerSupport ds5HapticsIrV2:frame];
    }
}

/**
 * Applies legacy direct-HID rumble only for slot zero while controller delivery is enabled.
 * @param number Host controller slot; all nonzero slots are ignored.
 * @param low Low-frequency motor intensity in the protocol's 16-bit range.
 * @param high High-frequency motor intensity in the protocol's 16-bit range.
 */
- (void)controllerRumbleFallback:(unsigned short)number low:(unsigned short)low high:(unsigned short)high {
    // Legacy HID backend is single-device. Never misroute another player's output.
    if (number == 0 && self.hidSupport.shouldSendControllerEvents) {
        [self.hidSupport rumbleLowFreqMotor:low highFreqMotor:high];
    }
}

/**
 * Forwards DualSense PCM haptics to GameController while controller delivery is enabled.
 * @param frame Borrowed protocol PCM frame consumed by the backend during this call.
 */
- (void)ds5HapticsPcm:(const LI_DS5_HAPTICS_PCM_FRAME *)frame {
    if (!self.hidSupport.shouldSendControllerEvents) {
        return;
    }
    [self.controllerSupport ds5HapticsPcm:frame];
}

/**
 * Passes a host motion request to the selected controller backend even while input is paused.
 *
 * Called on main by the stream-scoped proxy. The backend retains requested rates, rejects stale
 * contexts and separately gates outgoing samples, allowing motion to resume after focus returns.
 * @param controllerNumber Host controller slot; direct HID supports only zero.
 * @param motionType Protocol gyro or accelerometer sensor type.
 * @param reportRateHz Requested sensor frequency in Hz, or zero to stop reporting.
 */
- (void)setMotionEventState:(unsigned short)controllerNumber
                  motionType:(unsigned char)motionType
                reportRateHz:(unsigned short)reportRateHz {
    // Store host requests even while delivery is paused; backends gate samples.
    if (self.controllerSupport != nil) {
        [self.controllerSupport setMotionEventState:controllerNumber motionType:motionType reportRateHz:reportRateHz];
    } else {
        [self.hidSupport setMotionEventState:controllerNumber motionType:motionType reportRateHz:reportRateHz];
    }
}

- (void)connectionStatusUpdate:(int)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        Log(LOG_I, @"[diag] Connection status update: status=%d captured=%d input=%d reconnect=%d stopInProgress=%d",
            status,
            self.isMouseCaptured ? 1 : 0,
            self.hidSupport.shouldSendInputEvents ? 1 : 0,
            self.reconnectInProgress ? 1 : 0,
            self.stopStreamInProgress ? 1 : 0);
        uint64_t now = [self nowMs];
        if (status == CONN_STATUS_POOR) {
            if (self.lastConnectionStatus != CONN_STATUS_POOR) {
                if (self.connectionPoorStatusBurstWindowStartMs == 0 ||
                    now - self.connectionPoorStatusBurstWindowStartMs > 25000) {
                    self.connectionPoorStatusBurstWindowStartMs = now;
                    self.connectionPoorStatusBurstCount = 1;
                } else {
                    self.connectionPoorStatusBurstCount += 1;
                }
            }

            if (self.connectionPoorStatusBurstCount >= 2) {
                Log(LOG_W, @"[diag] Connection status flap detected (poor bursts=%lu in %.1fs), attempting adaptive mitigation",
                    (unsigned long)self.connectionPoorStatusBurstCount,
                    (now - self.connectionPoorStatusBurstWindowStartMs) / 1000.0);
                self.connectionPoorStatusBurstCount = 0;
                self.connectionPoorStatusBurstWindowStartMs = now;
                [self attemptAdaptiveMitigationForDropRate:100.0f];
            }

            if (self.disconnectWasUserInitiated || now < self.suppressConnectionWarningsUntilMs) {
                // Avoid showing a misleading warning during intentional teardown/detach.
                [self hideConnectionWarning];
            } else if ([SettingsClass showConnectionWarningsFor:self.app.host.uuid]) {
                [self showConnectionWarning];
            }
        } else if (status == CONN_STATUS_OKAY) {
            [self hideConnectionWarning];
            if (self.lastConnectionStatus == CONN_STATUS_POOR &&
                (self.connectionLastIdrRequestMs == 0 || now - self.connectionLastIdrRequestMs > 3000)) {
                LiRequestIdrFrame();
                self.connectionLastIdrRequestMs = now;
                Log(LOG_I, @"[diag] Requested IDR on POOR->OKAY transition");
            }
        }
        self.lastConnectionStatus = status;
    });
}

- (Connection *)currentClipboardConnection {
    return self.clipboardRuntimeConnection;
}

- (BOOL)isClipboardSyncEnabledForCurrentHost {
    NSString *hostKey = self.app.host.uuid;
    if (hostKey.length == 0) {
        NSString *address = self.app.host.activeAddress ?: self.app.host.address ?: @"";
        hostKey = [SettingsClass getHostUUIDFrom:address];
    }
    if (hostKey.length == 0) {
        hostKey = @"__global__";
    }
    return [SettingsClass clipboardSyncEnabledFor:hostKey];
}

- (BOOL)isClipboardSyncOwner {
    return MLActiveClipboardController == self;
}

- (BOOL)usesClipboardAgentProtocolForConnection:(Connection *)connection {
    // The negotiated protocol is authoritative. A UI host label can be absent
    // when display/VDD discovery is unavailable, despite clipboard support.
    uint32_t flags = [connection clipboardHostFeatureFlags];
    return (flags & (LI_FF_CLIPBOARD_TEXT | LI_FF_CLIPBOARD_IMAGE)) != 0;
}

- (void)logClipboardActivationStateIfNeeded:(MLClipboardActivationDiagnosticState)state
                                    message:(NSString *)message {
    uint64_t nowMs = [self nowMs];
    BOOL sameState = (self.clipboardLastActivationDiagnosticState == state);
    BOOL sameMessage = ((self.clipboardLastActivationDiagnosticMessage == nil && message.length == 0) ||
                        [self.clipboardLastActivationDiagnosticMessage isEqualToString:message ?: @""]);
    if (sameState &&
        sameMessage &&
        nowMs - self.clipboardLastActivationDiagnosticLogMs < MLClipboardActivationRepeatLogIntervalMs) {
        return;
    }

    self.clipboardLastActivationDiagnosticState = state;
    self.clipboardLastActivationDiagnosticMessage = [message copy] ?: @"";
    self.clipboardLastActivationDiagnosticLogMs = nowMs;
    if (message.length > 0) {
        Log(LOG_I, @"[clipboard] %@", message);
    }
}

- (void)resetClipboardActivationDiagnosticState {
    self.clipboardLastActivationDiagnosticState = MLClipboardActivationDiagnosticStateIdle;
    self.clipboardLastActivationDiagnosticMessage = nil;
    self.clipboardLastActivationDiagnosticLogMs = 0;
}

- (void)claimClipboardSyncOwnershipIfNeeded {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self claimClipboardSyncOwnershipIfNeeded];
        });
        return;
    }

    if (![self isClipboardSyncEnabledForCurrentHost]) {
        [self logClipboardActivationStateIfNeeded:MLClipboardActivationDiagnosticStateDisabled
                                          message:[NSString stringWithFormat:@"Clipboard sync disabled for host=%@", self.app.host.uuid ?: @"(unknown)"]];
        return;
    }

    StreamViewController *previousOwner = MLActiveClipboardController;
    if (previousOwner != self) {
        MLActiveClipboardController = self;
        [self resetClipboardActivationDiagnosticState];
        Log(LOG_I, @"[clipboard] Claimed clipboard sync ownership for host=%@", self.app.host.uuid ?: @"(unknown)");

        if (previousOwner != nil) {
            [previousOwner releaseClipboardSyncOwnershipWithUnbind:YES];
        }
    }

    [self activateClipboardBindingIfPossible];
}

- (void)releaseClipboardSyncOwnershipWithUnbind:(BOOL)shouldUnbind {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self releaseClipboardSyncOwnershipWithUnbind:shouldUnbind];
        });
        return;
    }

    Connection *connection = [self currentClipboardConnection];
    BOOL shouldRequestUnbind = shouldUnbind && self.clipboardSessionBound;

    [self stopClipboardMonitor];
    self.clipboardAwaitingInitialSnapshot = NO;
    self.clipboardInitialSnapshotDeadlineMs = 0;
    self.clipboardSessionBound = NO;
    self.clipboardHasPendingEchoSuppressionHash = NO;
    self.clipboardPendingEchoSuppressionHash = 0;
    [self resetClipboardActivationDiagnosticState];

    if (shouldRequestUnbind && connection != nil && ![self usesClipboardAgentProtocolForConnection:connection]) {
        int err = [connection unbindClipboardSession];
        if (err != 0 && err != LI_ERR_UNSUPPORTED) {
            Log(LOG_W, @"[clipboard] Failed to unbind clipboard session: %d", err);
        }
    }

    if (MLActiveClipboardController == self) {
        MLActiveClipboardController = nil;
    }
    self.clipboardRuntimeConnection = nil;
}

- (void)activateClipboardBindingIfPossible {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self activateClipboardBindingIfPossible];
        });
        return;
    }

    if (![self isClipboardSyncOwner]) {
        [self logClipboardActivationStateIfNeeded:MLClipboardActivationDiagnosticStateNotOwner
                                          message:@"Skipping clipboard activation because this stream is not the active clipboard owner"];
        return;
    }

    if (![self isClipboardSyncEnabledForCurrentHost]) {
        if (self.clipboardSessionBound) {
            [self releaseClipboardSyncOwnershipWithUnbind:YES];
        }
        [self logClipboardActivationStateIfNeeded:MLClipboardActivationDiagnosticStateDisabled
                                          message:[NSString stringWithFormat:@"Clipboard activation stopped because sync is disabled for host=%@", self.app.host.uuid ?: @"(unknown)"]];
        return;
    }

    Connection *connection = [self currentClipboardConnection];
    if (connection == nil) {
        [self logClipboardActivationStateIfNeeded:MLClipboardActivationDiagnosticStateNoConnection
                                          message:@"Clipboard activation is waiting for the stream connection object"];
        return;
    }

    if (self.stopStreamInProgress || self.reconnectInProgress) {
        [self logClipboardActivationStateIfNeeded:MLClipboardActivationDiagnosticStateControlNotReady
                                          message:@"Clipboard activation is paused while the stream is stopping or reconnecting"];
        return;
    }

    uint64_t nowMs = [self nowMs];
    if (self.streamHealthConnectionStartedMs != 0 &&
        (self.waitingForFirstRenderedFrame ||
         nowMs - self.streamHealthConnectionStartedMs < MLClipboardControlStartupGraceMs)) {
        [self logClipboardActivationStateIfNeeded:MLClipboardActivationDiagnosticStateControlNotReady
                                          message:@"Clipboard activation is waiting for the stream startup window to settle"];
        return;
    }

    if (self.clipboardSessionBound) {
        [self resetClipboardActivationDiagnosticState];
        [self startClipboardMonitorIfNeeded];
        return;
    }

    [self resetClipboardActivationDiagnosticState];
    if ([self usesClipboardAgentProtocolForConnection:connection]) {
        NSString *readiness = [connection clipboardControlReadinessReason];
        if (![readiness hasPrefix:@"ready-stage-"]) return;
        // Foundation v1 has text/PNG/blob frames, not legacy bind/snapshot
        // commands. Match its GUI agent's existing bidirectional transport.
        self.clipboardSessionBound = YES;
        self.clipboardAwaitingInitialSnapshot = NO;
        self.clipboardInitialSnapshotDeadlineMs = 0;
        self.clipboardHasPendingEchoSuppressionHash = NO;
        self.clipboardPendingEchoSuppressionHash = 0;
        self.clipboardLastChangeCount = [NSPasteboard generalPasteboard].changeCount;
        [self startClipboardMonitorIfNeeded];
        Log(LOG_I, @"[clipboard] Activated Foundation v1 text/PNG/blob transport from negotiated capabilities");
        return;
    }
    int bindErr = [connection bindClipboardSession];
    if (bindErr == LI_ERR_UNSUPPORTED) {
        Log(LOG_I, @"[clipboard] Host does not advertise clipboard sync");
        return;
    }
    if (bindErr != 0) {
        [self logClipboardActivationStateIfNeeded:MLClipboardActivationDiagnosticStateControlNotReady
                                          message:[NSString stringWithFormat:@"Clipboard activation is waiting for bind to succeed (err=%d)", bindErr]];
        return;
    }

    self.clipboardSessionBound = YES;
    self.clipboardAwaitingInitialSnapshot = YES;
    self.clipboardInitialSnapshotDeadlineMs = [self nowMs] + 1500;
    self.clipboardHasPendingEchoSuppressionHash = NO;
    self.clipboardPendingEchoSuppressionHash = 0;
    self.clipboardLastChangeCount = [NSPasteboard generalPasteboard].changeCount;
    Log(LOG_I, @"[clipboard] Clipboard session bound locally; requesting initial host snapshot");
    [self startClipboardMonitorIfNeeded];

    int snapshotErr = [connection requestClipboardSnapshot];
    if (snapshotErr == LI_ERR_UNSUPPORTED) {
        Log(LOG_I, @"[clipboard] Clipboard snapshot request was not supported by host");
        self.clipboardSessionBound = NO;
        self.clipboardAwaitingInitialSnapshot = NO;
        self.clipboardInitialSnapshotDeadlineMs = 0;
        [self stopClipboardMonitor];
        return;
    }
    if (snapshotErr != 0) {
        Log(LOG_W, @"[clipboard] Initial clipboard snapshot request failed: %d", snapshotErr);
        self.clipboardAwaitingInitialSnapshot = NO;
        self.clipboardInitialSnapshotDeadlineMs = 0;
    }
}

- (void)startClipboardMonitorIfNeeded {
    if (self.clipboardMonitorTimer != nil) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    NSTimer *timer = [NSTimer timerWithTimeInterval:MLClipboardMonitorInterval repeats:YES block:^(NSTimer * _Nonnull timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            [timer invalidate];
            return;
        }
        [strongSelf handleClipboardMonitorTick];
    }];
    timer.tolerance = 0.05;
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.clipboardMonitorTimer = timer;
}

- (void)stopClipboardMonitor {
    if (self.clipboardMonitorTimer != nil) {
        [self.clipboardMonitorTimer invalidate];
        self.clipboardMonitorTimer = nil;
    }
}

- (void)handleClipboardMonitorTick {
    if (![self isClipboardSyncEnabledForCurrentHost]) {
        if (self.clipboardSessionBound) {
            [self releaseClipboardSyncOwnershipWithUnbind:YES];
        } else {
            [self stopClipboardMonitor];
        }
        return;
    }

    if (![self isClipboardSyncOwner]) {
        [self stopClipboardMonitor];
        return;
    }

    if (!self.clipboardSessionBound) {
        [self activateClipboardBindingIfPossible];
        return;
    }

    if (self.clipboardAwaitingInitialSnapshot) {
        uint64_t nowMs = [self nowMs];
        if (self.clipboardInitialSnapshotDeadlineMs != 0 &&
            nowMs >= self.clipboardInitialSnapshotDeadlineMs) {
            self.clipboardAwaitingInitialSnapshot = NO;
            self.clipboardInitialSnapshotDeadlineMs = 0;
            Log(LOG_I, @"[clipboard] Initial host clipboard snapshot timed out; continuing with local clipboard sync");
        }
        else {
        return;
        }
    }

    [self sendCurrentLocalClipboardIfNeeded];
}

- (void)sendCurrentLocalClipboardIfNeeded {
    Connection *connection = [self currentClipboardConnection];
    if (connection == nil) {
        return;
    }

    BOOL foundationRawClipboard = [self usesClipboardAgentProtocolForConnection:connection];

    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    NSInteger changeCount = pasteboard.changeCount;
    if (changeCount == self.clipboardLastChangeCount) {
        return;
    }

    NSData *payload = nil;
    NSData *compoundTextPayload = nil;
    NSString *mimeType = nil;
    NSString *itemName = nil;
    uint8_t itemType = LI_CLIPBOARD_ITEM_TYPE_NONE;

    NSData *pngData = [pasteboard dataForType:NSPasteboardTypePNG];
    if (pngData.length > 0) {
        NSUInteger imageLimit = foundationRawClipboard ? MLClipboardBlobSizeLimit : MLClipboardImageSizeLimit;
        if (pngData.length > imageLimit) {
            self.clipboardLastChangeCount = changeCount;
            Log(LOG_I, @"[clipboard] Rejecting image clipboard payload larger than %lu bytes",
                (unsigned long)imageLimit);
            return;
        }
        payload = pngData;
        mimeType = @"image/png";
        itemType = LI_CLIPBOARD_ITEM_TYPE_IMAGE;
    } else {
        NSArray<NSImage *> *images = [pasteboard readObjectsForClasses:@[[NSImage class]] options:nil];
        if (images.count > 1) {
            self.clipboardLastChangeCount = changeCount;
            Log(LOG_I, @"[clipboard] Ignoring multi-image clipboard payload");
            return;
        } else if (images.count == 1) {
            NSImage *image = images.firstObject;
            NSBitmapImageRep *bitmapRep = nil;
            for (NSImageRep *rep in image.representations) {
                if ([rep isKindOfClass:[NSBitmapImageRep class]]) {
                    bitmapRep = (NSBitmapImageRep *)rep;
                    break;
                }
            }
            if (bitmapRep == nil && image.TIFFRepresentation != nil) {
                bitmapRep = [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
            }
            pngData = bitmapRep != nil ? [bitmapRep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] : nil;
            if (pngData.length == 0) {
                self.clipboardLastChangeCount = changeCount;
                Log(LOG_I, @"[clipboard] Ignoring image clipboard payload that could not be normalized to PNG");
                return;
            }
            NSUInteger imageLimit = foundationRawClipboard ? MLClipboardBlobSizeLimit : MLClipboardImageSizeLimit;
            if (pngData.length > imageLimit) {
                self.clipboardLastChangeCount = changeCount;
                Log(LOG_I, @"[clipboard] Rejecting image clipboard payload larger than %lu bytes",
                    (unsigned long)imageLimit);
                return;
            }
            payload = pngData;
            mimeType = @"image/png";
            itemType = LI_CLIPBOARD_ITEM_TYPE_IMAGE;
        } else {
            NSString *text = [pasteboard stringForType:NSPasteboardTypeString];
            if (text == nil) {
                self.clipboardLastChangeCount = changeCount;
                Log(LOG_I, @"[clipboard] Ignoring unsupported clipboard payload");
                return;
            }
            text = MLNormalizeClipboardText(text);
            NSData *textData = [text dataUsingEncoding:NSUTF8StringEncoding];
            if (textData == nil) {
                self.clipboardLastChangeCount = changeCount;
                Log(LOG_W, @"[clipboard] Failed to encode clipboard text as UTF-8");
                return;
            }
            payload = textData;
            mimeType = @"text/plain;charset=utf-8";
            itemType = LI_CLIPBOARD_ITEM_TYPE_TEXT;
        }
    }

    if (payload == nil || itemType == LI_CLIPBOARD_ITEM_TYPE_NONE) {
        return;
    }

    if (foundationRawClipboard && itemType == LI_CLIPBOARD_ITEM_TYPE_IMAGE) {
        NSString *compoundText = MLNormalizeClipboardText([pasteboard stringForType:NSPasteboardTypeString]);
        NSData *textData = [compoundText dataUsingEncoding:NSUTF8StringEncoding];
        if (textData.length > 0 && textData.length <= MLClipboardAgentInlinePayloadLimit) {
            compoundTextPayload = textData;
        }
    }

    uint64_t contentHash = MLComputeClipboardHash(itemType, payload, itemName);
    if (self.clipboardHasPendingEchoSuppressionHash &&
        self.clipboardPendingEchoSuppressionHash == contentHash) {
        self.clipboardLastChangeCount = changeCount;
        self.clipboardHasPendingEchoSuppressionHash = NO;
        self.clipboardPendingEchoSuppressionHash = 0;
        Log(LOG_I, @"[clipboard] Suppressed echoed local clipboard item hash=%llu", contentHash);
        return;
    }

    NSData *rawFrame = nil;
    int err = 0;
    BOOL sentCompoundRawFrame = NO;
    if (foundationRawClipboard && payload.length > MLClipboardAgentInlinePayloadLimit) {
        self.clipboardLastChangeCount = changeCount;
        [self uploadClipboardBlob:payload mimeType:mimeType contentHash:contentHash];
        return;
    }
    if (foundationRawClipboard && compoundTextPayload.length > 0) {
        uint32_t token = arc4random() | 1U;
        NSData *textFrame = MLClipboardAgentEncodeFrame(LI_CLIPBOARD_KIND_TEXT, token, compoundTextPayload);
        NSData *imageFrame = MLClipboardAgentEncodeFrame(LI_CLIPBOARD_KIND_PNG, token, payload);
        err = textFrame != nil && imageFrame != nil ? [connection sendClipboardRawData:textFrame] : -1;
        if (err == 0) {
            err = [connection sendClipboardRawData:imageFrame];
        }
        sentCompoundRawFrame = err == 0;
        rawFrame = imageFrame;
    } else {
        rawFrame = foundationRawClipboard
            ? MLClipboardAgentEncodeFrame(itemType == LI_CLIPBOARD_ITEM_TYPE_IMAGE
                                          ? LI_CLIPBOARD_KIND_PNG
                                          : LI_CLIPBOARD_KIND_TEXT,
                                          0,
                                          payload)
            : nil;
        err = rawFrame != nil
            ? [connection sendClipboardRawData:rawFrame]
            : [connection sendClipboardItemData:payload
                                           type:itemType
                                       mimeType:mimeType
                                           name:itemName
                                         itemId:MLGenerateClipboardItemId()
                                    contentHash:contentHash];
    }
    if (err == LI_ERR_UNSUPPORTED && rawFrame != nil) {
        // Keep legacy Sunshine compatibility when a host advertises the old
        // clipboard extension but has no user-session v1 agent.
        err = [connection sendClipboardItemData:payload
                                           type:itemType
                                       mimeType:mimeType
                                           name:itemName
                                         itemId:MLGenerateClipboardItemId()
                                    contentHash:contentHash];
    }
    if (err == LI_ERR_UNSUPPORTED) {
        self.clipboardLastChangeCount = changeCount;
        Log(LOG_I, @"[clipboard] Host rejected clipboard item type=%u; keeping sync active for supported types",
            itemType);
        return;
    }
    if (err != 0) {
        self.clipboardSessionBound = NO;
        self.clipboardAwaitingInitialSnapshot = NO;
        self.clipboardInitialSnapshotDeadlineMs = 0;
        [self logClipboardActivationStateIfNeeded:MLClipboardActivationDiagnosticStateControlNotReady
                                          message:[NSString stringWithFormat:@"Clipboard send failed; will retry bind (err=%d)", err]];
        Log(LOG_W, @"[clipboard] Failed to send local clipboard item: %d", err);
        return;
    }

    self.clipboardLastChangeCount = changeCount;
    [self resetClipboardActivationDiagnosticState];
    Log(LOG_I, @"[clipboard] Sent local clipboard item: type=%u length=%lu raw=%d compound=%d name=%@",
        itemType,
        (unsigned long)payload.length,
        rawFrame != nil ? 1 : 0,
        sentCompoundRawFrame ? 1 : 0,
        itemName ?: @"");
}

- (void)applyReceivedClipboardSnapshot:(MLClipboardItemSnapshot *)item {
    if (item == nil) {
        return;
    }

    if (![self isClipboardSyncOwner]) {
        Log(LOG_I, @"[clipboard] Ignoring clipboard item for inactive stream session");
        return;
    }

    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    uint64_t suppressionHash = item.contentHash;

    if (item.type == LI_CLIPBOARD_ITEM_TYPE_NONE) {
        if ((item.flags & LI_CLIPBOARD_ITEM_FLAG_SNAPSHOT) != 0) {
            [pasteboard clearContents];
            self.clipboardLastChangeCount = pasteboard.changeCount;
            self.clipboardHasPendingEchoSuppressionHash = NO;
            self.clipboardPendingEchoSuppressionHash = 0;
            Log(LOG_I, @"[clipboard] Applied empty host clipboard snapshot");
        }
        self.clipboardAwaitingInitialSnapshot = NO;
        self.clipboardInitialSnapshotDeadlineMs = 0;
        return;
    }

    switch (item.type) {
        case LI_CLIPBOARD_ITEM_TYPE_TEXT: {
            NSData *textData = item.data ?: [NSData data];
            NSString *text = [[NSString alloc] initWithData:textData encoding:NSUTF8StringEncoding];
            if (text == nil) {
                Log(LOG_W, @"[clipboard] Failed to decode remote text clipboard payload");
                self.clipboardAwaitingInitialSnapshot = NO;
                self.clipboardInitialSnapshotDeadlineMs = 0;
                return;
            }
            text = MLNormalizeClipboardText(text);
            [pasteboard clearContents];
            [pasteboard setString:text forType:NSPasteboardTypeString];
            if (suppressionHash == 0) {
                NSData *normalizedData = [text dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
                suppressionHash = MLComputeClipboardHash(LI_CLIPBOARD_ITEM_TYPE_TEXT, normalizedData, nil);
            }
            break;
        }
        case LI_CLIPBOARD_ITEM_TYPE_IMAGE: {
            NSData *pngData = item.data ?: [NSData data];
            NSImage *image = [[NSImage alloc] initWithData:pngData];
            if (image == nil) {
                Log(LOG_W, @"[clipboard] Failed to decode remote image clipboard payload");
                self.clipboardAwaitingInitialSnapshot = NO;
                self.clipboardInitialSnapshotDeadlineMs = 0;
                return;
            }
            [pasteboard clearContents];
            [pasteboard declareTypes:@[NSPasteboardTypePNG, NSPasteboardTypeTIFF] owner:nil];
            [pasteboard setData:pngData forType:NSPasteboardTypePNG];
            NSData *tiffData = image.TIFFRepresentation;
            if (tiffData.length > 0) {
                [pasteboard setData:tiffData forType:NSPasteboardTypeTIFF];
            }
            if (suppressionHash == 0) {
                suppressionHash = MLComputeClipboardHash(LI_CLIPBOARD_ITEM_TYPE_IMAGE, pngData, nil);
            }
            break;
        }
        default:
            Log(LOG_W, @"[clipboard] Ignoring unsupported remote clipboard item type: %u", item.type);
            self.clipboardAwaitingInitialSnapshot = NO;
            self.clipboardInitialSnapshotDeadlineMs = 0;
            return;
    }

    self.clipboardLastChangeCount = pasteboard.changeCount;
    self.clipboardAwaitingInitialSnapshot = NO;
    self.clipboardInitialSnapshotDeadlineMs = 0;
    if (suppressionHash != 0) {
        self.clipboardHasPendingEchoSuppressionHash = YES;
        self.clipboardPendingEchoSuppressionHash = suppressionHash;
    } else {
        self.clipboardHasPendingEchoSuppressionHash = NO;
        self.clipboardPendingEchoSuppressionHash = 0;
    }
}

- (void)clipboardItemReceived:(const LI_CLIPBOARD_ITEM *)item {
    MLClipboardItemSnapshot *snapshot = [MLClipboardItemSnapshot snapshotWithClipboardItem:item];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self isClipboardSyncEnabledForCurrentHost]) {
            Log(LOG_I, @"[clipboard] Ignoring clipboard item because clipboard sync is disabled");
            return;
        }
        Log(LOG_I, @"[clipboard] StreamViewController received item: type=%u length=%u flags=0x%x itemId=%llu mime=%s name=%s",
            snapshot != nil ? snapshot.type : 0,
            snapshot != nil ? (unsigned int)snapshot.data.length : 0,
            snapshot != nil ? snapshot.flags : 0,
            snapshot != nil ? snapshot.itemId : 0,
            snapshot.mimeType.UTF8String ?: "",
            snapshot.name.UTF8String ?: "");
        [self applyReceivedClipboardSnapshot:snapshot];
    });
}

- (void)resetPendingClipboardAgentBurst {
    [self.clipboardPendingAgentTimer invalidate];
    self.clipboardPendingAgentTimer = nil;
    self.clipboardPendingAgentToken = 0;
    self.clipboardPendingAgentText = nil;
    self.clipboardPendingAgentPNG = nil;
}

- (HttpManager *)clipboardHTTPManagerForCurrentHost {
    if (self.clipboardHTTPManager == nil && self.app.host.activeAddress.length > 0 && self.app.host.serverCert != nil) {
        self.clipboardHTTPManager = [[HttpManager alloc] initWithHost:self.app.host.activeAddress
                                                              uniqueId:[IdManager getUniqueId]
                                                            serverCert:self.app.host.serverCert];
    }
    return self.clipboardHTTPManager;
}

- (void)uploadClipboardBlob:(NSData *)payload
                   mimeType:(NSString *)mimeType
                contentHash:(uint64_t)contentHash {
    if (payload.length == 0 || payload.length > MLClipboardBlobSizeLimit) {
        return;
    }

    HttpManager *http = [self clipboardHTTPManagerForCurrentHost];
    NSURLRequest *baseRequest = [http newClipboardRequestWithPath:@"/api/v1/clipboard/blob"];
    if (baseRequest == nil) {
        Log(LOG_W, @"[clipboard] Cannot create blob upload request");
        return;
    }

    NSMutableURLRequest *request = [baseRequest mutableCopy];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
    [request setValue:mimeType ?: @"application/octet-stream" forHTTPHeaderField:@"X-Clipboard-Mime"];
    request.HTTPBody = payload;

    [http executeDataRequest:request completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        if (error != nil || response.statusCode < 200 || response.statusCode >= 300) {
            Log(LOG_W, @"[clipboard] Blob upload failed: status=%ld error=%@",
                (long)response.statusCode, error.localizedDescription ?: @"none");
            return;
        }

        NSError *jsonError = nil;
        NSDictionary *json = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
        NSString *blobId = [json isKindOfClass:[NSDictionary class]] ? json[@"id"] : nil;
        if (![blobId isKindOfClass:[NSString class]] || blobId.length == 0 || blobId.length > 128) {
            Log(LOG_W, @"[clipboard] Blob upload returned no valid id: %@", jsonError.localizedDescription ?: @"invalid response");
            return;
        }

        NSDictionary *descriptor = @{
            @"id": blobId,
            @"mime": mimeType ?: @"application/octet-stream",
            @"size": @(payload.length),
            @"hash": @(contentHash),
        };
        NSData *descriptorData = [NSJSONSerialization dataWithJSONObject:descriptor options:0 error:&jsonError];
        NSData *frame = descriptorData != nil ? MLClipboardAgentEncodeFrame(LI_CLIPBOARD_KIND_REF, 0, descriptorData) : nil;
        Connection *connection = [self currentClipboardConnection];
        if (frame == nil || connection == nil || [connection sendClipboardRawData:frame] != 0) {
            Log(LOG_W, @"[clipboard] Failed to send blob reference after upload");
            return;
        }
        Log(LOG_I, @"[clipboard] Sent blob reference id=%@ length=%lu", blobId, (unsigned long)payload.length);
    }];
}

- (void)fetchClipboardBlobWithDescriptor:(NSDictionary *)descriptor {
    NSString *blobId = descriptor[@"id"];
    NSString *mimeType = descriptor[@"mime"];
    NSNumber *advertisedSize = descriptor[@"size"];
    NSCharacterSet *allowedIdCharacters = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"];
    if (![blobId isKindOfClass:[NSString class]] || blobId.length == 0 || blobId.length > 128 ||
        ![mimeType isKindOfClass:[NSString class]] ||
        [blobId rangeOfCharacterFromSet:[allowedIdCharacters invertedSet]].location != NSNotFound) {
        Log(LOG_W, @"[clipboard] Dropping malformed blob reference");
        return;
    }
    if (advertisedSize != nil && (advertisedSize.longLongValue < 0 || advertisedSize.unsignedLongLongValue > MLClipboardBlobSizeLimit)) {
        Log(LOG_W, @"[clipboard] Dropping oversized blob reference id=%@", blobId);
        return;
    }

    HttpManager *http = [self clipboardHTTPManagerForCurrentHost];
    NSURLRequest *request = [http newClipboardRequestWithPath:[NSString stringWithFormat:@"/api/v1/clipboard/blob/%@", blobId]];
    if (request == nil) {
        return;
    }
    [http executeDataRequest:request completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        if (error != nil || response.statusCode < 200 || response.statusCode >= 300 || data.length == 0 || data.length > MLClipboardBlobSizeLimit) {
            Log(LOG_W, @"[clipboard] Blob fetch failed id=%@ status=%ld error=%@", blobId, (long)response.statusCode, error.localizedDescription ?: @"none");
            return;
        }
        if (advertisedSize != nil && advertisedSize.unsignedIntegerValue != data.length) {
            Log(LOG_W, @"[clipboard] Blob size mismatch id=%@ got=%lu advertised=%@", blobId, (unsigned long)data.length, advertisedSize);
            return;
        }
        if ([mimeType isEqualToString:@"image/png"]) {
            [self handleClipboardAgentFrameKind:LI_CLIPBOARD_KIND_PNG token:0 payload:data];
        } else if ([mimeType hasPrefix:@"text/"] && [data rangeOfData:[NSData dataWithBytes:"\0" length:1] options:0 range:NSMakeRange(0, data.length)].location == NSNotFound) {
            [self handleClipboardAgentFrameKind:LI_CLIPBOARD_KIND_TEXT token:0 payload:data];
        } else {
            Log(LOG_I, @"[clipboard] Ignoring fetched blob with unsupported mime=%@", mimeType);
        }
    }];
}

- (void)applyPendingClipboardAgentCompoundIfReady {
    if (self.clipboardPendingAgentText.length == 0 || self.clipboardPendingAgentPNG.length == 0) {
        return;
    }

    NSImage *image = [[NSImage alloc] initWithData:self.clipboardPendingAgentPNG];
    NSString *text = [[NSString alloc] initWithData:self.clipboardPendingAgentText encoding:NSUTF8StringEncoding];
    if (image == nil || text == nil) {
        [self resetPendingClipboardAgentBurst];
        return;
    }

    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard declareTypes:@[NSPasteboardTypeString, NSPasteboardTypePNG, NSPasteboardTypeTIFF] owner:nil];
    [pasteboard setString:MLNormalizeClipboardText(text) forType:NSPasteboardTypeString];
    [pasteboard setData:self.clipboardPendingAgentPNG forType:NSPasteboardTypePNG];
    NSData *tiff = image.TIFFRepresentation;
    if (tiff.length > 0) {
        [pasteboard setData:tiff forType:NSPasteboardTypeTIFF];
    }

    self.clipboardLastChangeCount = pasteboard.changeCount;
    self.clipboardHasPendingEchoSuppressionHash = YES;
    self.clipboardPendingEchoSuppressionHash = MLComputeClipboardHash(
        LI_CLIPBOARD_ITEM_TYPE_IMAGE, self.clipboardPendingAgentPNG, nil);
    [self resetPendingClipboardAgentBurst];
}

- (void)handleClipboardAgentFrameKind:(uint8_t)kind
                                token:(uint32_t)token
                              payload:(NSData *)payload {
    if (token == 0) {
        MLClipboardItemSnapshot *snapshot = [[MLClipboardItemSnapshot alloc] init];
        snapshot.type = kind == LI_CLIPBOARD_KIND_TEXT ? LI_CLIPBOARD_ITEM_TYPE_TEXT : LI_CLIPBOARD_ITEM_TYPE_IMAGE;
        snapshot.data = payload;
        snapshot.mimeType = kind == LI_CLIPBOARD_KIND_TEXT ? @"text/plain;charset=utf-8" : @"image/png";
        snapshot.contentHash = MLComputeClipboardHash(snapshot.type, payload, nil);
        [self applyReceivedClipboardSnapshot:snapshot];
        return;
    }

    if (self.clipboardPendingAgentToken != token) {
        [self resetPendingClipboardAgentBurst];
        self.clipboardPendingAgentToken = token;
    }
    if (kind == LI_CLIPBOARD_KIND_TEXT) {
        self.clipboardPendingAgentText = payload;
    } else if (kind == LI_CLIPBOARD_KIND_PNG) {
        self.clipboardPendingAgentPNG = payload;
    }

    [self.clipboardPendingAgentTimer invalidate];
    self.clipboardPendingAgentTimer = nil;
    if (self.clipboardPendingAgentText.length > 0 && self.clipboardPendingAgentPNG.length > 0) {
        [self applyPendingClipboardAgentCompoundIfReady];
        return;
    }

    __weak typeof(self) weakSelf = self;
    self.clipboardPendingAgentTimer = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:NO block:^(__unused NSTimer *timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.clipboardPendingAgentToken != token) {
            return;
        }
        NSData *singlePayload = strongSelf.clipboardPendingAgentText ?: strongSelf.clipboardPendingAgentPNG;
        uint8_t singleKind = strongSelf.clipboardPendingAgentText != nil ? LI_CLIPBOARD_KIND_TEXT : LI_CLIPBOARD_KIND_PNG;
        [strongSelf resetPendingClipboardAgentBurst];
        if (singlePayload.length > 0) {
            [strongSelf handleClipboardAgentFrameKind:singleKind token:0 payload:singlePayload];
        }
    }];
}

- (void)clipboardDataReceived:(const uint8_t *)data length:(uint32_t)length {
    if (data == NULL || length == 0) {
        return;
    }

    NSData *frame = [NSData dataWithBytes:data length:length];
    dispatch_async(dispatch_get_main_queue(), ^{
        uint8_t kind = 0;
        uint32_t token = 0;
        NSData *payload = nil;
        if (!MLClipboardAgentDecodeFrame(frame.bytes, frame.length, &kind, &token, &payload)) {
            Log(LOG_W, @"[clipboard] Dropping malformed Foundation clipboard agent frame length=%u", length);
            return;
        }
        if (![self isClipboardSyncEnabledForCurrentHost] || ![self isClipboardSyncOwner]) {
            return;
        }
        if (kind == LI_CLIPBOARD_KIND_REF) {
            NSError *jsonError = nil;
            NSDictionary *descriptor = [NSJSONSerialization JSONObjectWithData:payload options:0 error:&jsonError];
            if (![descriptor isKindOfClass:[NSDictionary class]]) {
                Log(LOG_W, @"[clipboard] Dropping malformed blob reference: %@", jsonError.localizedDescription ?: @"invalid JSON");
                return;
            }
            [self fetchClipboardBlobWithDescriptor:descriptor];
            return;
        }
        [self handleClipboardAgentFrameKind:kind token:token payload:payload];
    });
}

@end
