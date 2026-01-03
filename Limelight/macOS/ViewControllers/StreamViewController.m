//
//  StreamViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 25/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "StreamViewController.h"
#import <QuartzCore/QuartzCore.h>
#import "StreamViewMac.h"
#import "AppsViewController.h"
#import "NSWindow+Moonlight.h"
#import "AlertPresenter.h"

#import "Connection.h"
#import "StreamConfiguration.h"
#import "DataManager.h"
#import "ControllerSupport.h"
#import "StreamManager.h"
#import "VideoDecoderRenderer.h"
#import "HIDSupport.h"

#import "Moonlight-Swift.h"

#undef NSLocalizedString
#define NSLocalizedString(key, comment) [[LanguageManager shared] localize:key]

#include "Limelight.h"

@import VideoToolbox;

#import <IOKit/pwr_mgt/IOPMLib.h>
#import <Carbon/Carbon.h>

@interface StreamViewController () <ConnectionCallbacks, KeyboardNotifiableDelegate, InputPresenceDelegate>

@property (nonatomic, strong) ControllerSupport *controllerSupport;
@property (nonatomic, strong) HIDSupport *hidSupport;
@property (nonatomic) BOOL useSystemControllerDriver;
@property (nonatomic, strong) StreamManager *streamMan;
@property (nonatomic, readonly) StreamViewMac *streamView;
@property (nonatomic, strong) id windowDidExitFullScreenNotification;
@property (nonatomic, strong) id windowDidEnterFullScreenNotification;
@property (nonatomic, strong) id windowDidResignKeyNotification;
@property (nonatomic, strong) id windowDidBecomeKeyNotification;
@property (nonatomic, strong) id windowWillCloseNotification;
@property (nonatomic) int cursorHiddenCounter;

@property (nonatomic) IOPMAssertionID powerAssertionID;

@property (nonatomic, strong) NSVisualEffectView *overlayContainer;
@property (nonatomic, strong) NSTextField *overlayLabel;
@property (nonatomic, strong) NSTimer *statsTimer;

@property (nonatomic, strong) NSVisualEffectView *connectionWarningContainer;
@property (nonatomic, strong) NSTextField *connectionWarningLabel;

@property (nonatomic, strong) NSVisualEffectView *notificationContainer;
@property (nonatomic, strong) NSTextField *notificationLabel;
@property (nonatomic, strong) NSTimer *notificationTimer;

@property (nonatomic, strong) NSVisualEffectView *mouseModeContainer;
@property (nonatomic, strong) NSTextField *mouseModeLabel;

@end

@implementation StreamViewController

#pragma mark - Lifecycle

- (BOOL)useSystemControllerDriver {
    return [SettingsClass controllerDriverFor:self.app.host.uuid] == 1;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.cursorHiddenCounter = 0;
    
    [self prepareForStreaming];
    
    __weak typeof(self) weakSelf = self;

    self.windowDidExitFullScreenNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidExitFullScreenNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            if ([weakSelf.view.window isKeyWindow]) {
                [weakSelf uncaptureMouse];
                [weakSelf captureMouse];
            }
        }
    }];

    self.windowDidEnterFullScreenNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidEnterFullScreenNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            if ([weakSelf isWindowInCurrentSpace]) {
                if ([weakSelf isWindowFullscreen]) {
                    if ([weakSelf.view.window isKeyWindow]) {
                        [weakSelf uncaptureMouse];
                        [weakSelf captureMouse];
                    }
                }
            }
        }
    }];
    
    self.windowDidResignKeyNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResignKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            if (![weakSelf isWindowInCurrentSpace] || ![weakSelf isWindowFullscreen]) {
                [weakSelf uncaptureMouse];
            }
        }
    }];
    self.windowDidBecomeKeyNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            if ([weakSelf isWindowInCurrentSpace]) {
                if ([weakSelf isWindowFullscreen]) {
                    if ([weakSelf.view.window isKeyWindow]) {
                        [weakSelf uncaptureMouse];
                        [weakSelf captureMouse];
                    }
                }
            }
        } else {
            [weakSelf uncaptureMouse];
        }
    }];
    
    self.windowWillCloseNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (weakSelf.useSystemControllerDriver) {
                    [weakSelf.controllerSupport cleanup];
                }
                // Stopping the stream can block while common-c tears down sockets/ENet.
                // Do it off the main thread so window close doesn't feel like a hang.
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [weakSelf.streamMan stopStream];
                });
            });
        }
    }];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleMouseModeToggledNotification:) name:HIDMouseModeToggledNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleGamepadQuitNotification:) name:HIDGamepadQuitNotification object:nil];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    
    self.streamView.keyboardNotifiable = self;
    self.streamView.appName = self.app.name;
    self.streamView.statusText = @"Starting";
    self.view.window.tabbingMode = NSWindowTabbingModeDisallowed;
    [self.view.window makeFirstResponder:self];
    
    NSDictionary* prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
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
    [self.view.window moonlight_centerWindowOnFirstRunWithSize:CGSizeMake(1008, 595)];
    
    self.view.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidExitFullScreenNotification];
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidEnterFullScreenNotification];
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidResignKeyNotification];
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidBecomeKeyNotification];
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowWillCloseNotification];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:HIDMouseModeToggledNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:HIDGamepadQuitNotification object:nil];

    [self.hidSupport tearDownHidManager];
    self.hidSupport = nil;
}

- (void)flagsChanged:(NSEvent *)event {
    [self.hidSupport flagsChanged:event];
    
    // Uncapture mouse when Option key is pressed
    if ((event.keyCode == kVK_Option || event.keyCode == kVK_RightOption) &&
        (event.modifierFlags & NSEventModifierFlagOption)) {
        [self.hidSupport releaseAllModifierKeys];
        [self uncaptureMouse];
    }
}

- (void)keyDown:(NSEvent *)event {
    [self.hidSupport keyDown:event];
}

- (void)keyUp:(NSEvent *)event {
    [self.hidSupport keyUp:event];
}


- (void)mouseDown:(NSEvent *)event {
    [self.hidSupport mouseDown:event withButton:BUTTON_LEFT];
    [self captureMouse];
}

- (void)mouseUp:(NSEvent *)event {
    [self.hidSupport mouseUp:event withButton:BUTTON_LEFT];
}

- (void)rightMouseDown:(NSEvent *)event {
    [self.hidSupport mouseDown:event withButton:BUTTON_RIGHT];
}

- (void)rightMouseUp:(NSEvent *)event {
    [self.hidSupport mouseUp:event withButton:BUTTON_RIGHT];
}

- (void)otherMouseDown:(NSEvent *)event {
    int button = [self getMouseButtonFromEvent:event];
    if (button == 0) {
        return;
    }
    [self.hidSupport mouseDown:event withButton:button];
}

- (void)otherMouseUp:(NSEvent *)event {
    int button = [self getMouseButtonFromEvent:event];
    if (button == 0) {
        return;
    }
    [self.hidSupport mouseUp:event withButton:button];
}

- (void)mouseMoved:(NSEvent *)event {
    [self.hidSupport mouseMoved:event];
}

- (void)mouseDragged:(NSEvent *)event {
    [self.hidSupport mouseMoved:event];
}

- (void)rightMouseDragged:(NSEvent *)event {
    [self.hidSupport mouseMoved:event];
}

- (void)otherMouseDragged:(NSEvent *)event {
    [self.hidSupport mouseMoved:event];
}

- (void)scrollWheel:(NSEvent *)event {
    [self.hidSupport scrollWheel:event];
}

- (int)getMouseButtonFromEvent:(NSEvent *)event {
    int button;
    switch (event.buttonNumber) {
        case 2:
            button = BUTTON_MIDDLE;
            break;
        case 3:
            button = BUTTON_X1;
            break;
        case 4:
            button = BUTTON_X2;
            break;
        default:
            return 0;
            break;
    }
    
    return button;
}


#pragma mark - KeyboardNotifiable

- (BOOL)onKeyboardEquivalent:(NSEvent *)event {
    const NSEventModifierFlags modifierFlags = NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand | NSEventModifierFlagFunction;
    const NSEventModifierFlags eventModifierFlags = event.modifierFlags & modifierFlags;
    
    if (event.keyCode == kVK_ANSI_1 && eventModifierFlags == NSEventModifierFlagCommand) {
        [self.hidSupport releaseAllModifierKeys];
        return NO;
    }
    
    if ((event.keyCode == kVK_ANSI_Grave && eventModifierFlags == NSEventModifierFlagCommand)
        || (event.keyCode == kVK_ANSI_H && eventModifierFlags == NSEventModifierFlagCommand)
        ) {
        if (![self isWindowFullscreen]) {
            [self.hidSupport releaseAllModifierKeys];
            return NO;
        }
    }
    
    if ((event.keyCode == kVK_ANSI_F && eventModifierFlags == (NSEventModifierFlagControl | NSEventModifierFlagCommand))
        || (event.keyCode == kVK_ANSI_F && eventModifierFlags == NSEventModifierFlagFunction)
        || (event.keyCode == kVK_ANSI_W && eventModifierFlags == (NSEventModifierFlagOption | NSEventModifierFlagControl))
        || (event.keyCode == kVK_ANSI_W && eventModifierFlags == (NSEventModifierFlagShift | NSEventModifierFlagControl))
        || (event.keyCode == kVK_ANSI_W && eventModifierFlags == NSEventModifierFlagCommand)
        ) {
        [self.hidSupport releaseAllModifierKeys];
        return NO;
    }
    
    if (event.keyCode == kVK_ANSI_S && eventModifierFlags == (NSEventModifierFlagControl | NSEventModifierFlagOption)) {
        [self toggleOverlay];
        return YES;
    }
    
    [self.hidSupport keyDown:event];
    [self.hidSupport keyUp:event];
    
    return YES;
}


#pragma mark - Actions


- (IBAction)performClose:(id)sender {
    [self uncaptureMouse];
    
    NSAlert *alert = [[NSAlert alloc] init];
    
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = NSLocalizedString(@"Disconnect Alert", @"Disconnect Alert");

    [alert addButtonWithTitle:NSLocalizedString(@"Disconnect from Stream", @"Disconnect from Stream")];
    [alert addButtonWithTitle:NSLocalizedString(@"Close and Quit App", @"Close and Quit App")];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"Cancel")];

    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse returnCode) {
        switch (returnCode) {
            case NSAlertFirstButtonReturn:
                [self doCommandBySelector:@selector(performCloseStreamWindow:)];
                break;
                
            case NSAlertSecondButtonReturn:
                [self doCommandBySelector:@selector(performCloseAndQuitApp:)];
                break;

            default:
                [self captureMouse];
                break;
        }
    }];
}

- (IBAction)performCloseStreamWindow:(id)sender {
    [self.hidSupport releaseAllModifierKeys];
    [self.nextResponder doCommandBySelector:@selector(performClose:)];
}

- (IBAction)performCloseAndQuitApp:(id)sender {
    [self.delegate quitApp:self.app completion:nil];
}

- (IBAction)resizeWindowToActualResulution:(id)sender {
    CGFloat screenScale = [NSScreen mainScreen].backingScaleFactor;
    CGFloat width = (CGFloat)[self.class getResolution].width / screenScale;
    CGFloat height = (CGFloat)[self.class getResolution].height / screenScale;
    [self.view.window setContentSize:NSMakeSize(width, height)];
}


#pragma mark - Helpers

- (void)enableMenuItems:(BOOL)enable {
    NSMenu *appMenu = [[NSApplication sharedApplication].mainMenu itemWithTag:1000].submenu;
    appMenu.autoenablesItems = enable;
    [self itemWithMenu:appMenu andAction:@selector(terminate:)].enabled = enable;
}

- (void)captureMouse {
    NSDictionary* prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    BOOL showLocalCursor = prefs ? [prefs[@"showLocalCursor"] boolValue] : NO;

    if (!showLocalCursor) {
        CGAssociateMouseAndMouseCursorPosition(NO);
        if (self.cursorHiddenCounter == 0) {
            [NSCursor hide];
            self.cursorHiddenCounter ++;
        }
    }
    
    if (!showLocalCursor) {
        CGRect rectInWindow = [self.view convertRect:self.view.bounds toView:nil];
        CGRect rectInScreen = [self.view.window convertRectToScreen:rectInWindow];
        CGFloat screenHeight = self.view.window.screen.frame.size.height;
        CGPoint cursorPoint = CGPointMake(CGRectGetMidX(rectInScreen), screenHeight - CGRectGetMidY(rectInScreen));
        CGWarpMouseCursorPosition(cursorPoint);
    }
    
    [self enableMenuItems:NO];
    
    [self disallowDisplaySleep];
    
    self.hidSupport.shouldSendInputEvents = YES;
    self.controllerSupport.shouldSendInputEvents = YES;
    self.view.window.acceptsMouseMovedEvents = YES;
}

- (void)uncaptureMouse {
    NSDictionary* prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    BOOL showLocalCursor = prefs ? [prefs[@"showLocalCursor"] boolValue] : NO;

    if (!showLocalCursor) {
        CGAssociateMouseAndMouseCursorPosition(YES);
        if (self.cursorHiddenCounter != 0) {
            [NSCursor unhide];
            self.cursorHiddenCounter --;
        }
    }
    
    [self enableMenuItems:YES];
    
    [self allowDisplaySleep];
    
    self.hidSupport.shouldSendInputEvents = NO;
    self.controllerSupport.shouldSendInputEvents = NO;
    self.view.window.acceptsMouseMovedEvents = NO;
}

- (BOOL)isWindowInCurrentSpace {
    BOOL found = NO;
    CFArrayRef windowsInSpace = CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    for (NSDictionary *thisWindow in (__bridge NSArray *)windowsInSpace) {
        NSNumber *thisWindowNumber = (NSNumber *)thisWindow[(__bridge NSString *)kCGWindowNumber];
        if (self.view.window.windowNumber == thisWindowNumber.integerValue) {
            found = YES;
            break;
        }
    }
    if (windowsInSpace != NULL) {
        CFRelease(windowsInSpace);
    }
    return found;
}

- (BOOL)isWindowFullscreen {
    return [self.view.window styleMask] & NSWindowStyleMaskFullScreen;
}

- (BOOL)isOurWindowTheWindowInNotiifcation:(NSNotification *)note {
    return ((NSWindow *)note.object) == self.view.window;
}

- (NSMenuItem *)itemWithMenu:(NSMenu *)menu andAction:(SEL)action {
    return [menu itemAtIndex:[menu indexOfItemWithTarget:nil andAction:action]];
}


- (void)disallowDisplaySleep {
    if (self.powerAssertionID != 0) {
        return;
    }
    
    CFStringRef reasonForActivity= CFSTR("Moonlight streaming");
    
    IOPMAssertionID assertionID;
    IOReturn success = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep, kIOPMAssertionLevelOn, reasonForActivity, &assertionID);
    
    if (success == kIOReturnSuccess) {
        self.powerAssertionID = assertionID;
    } else {
        self.powerAssertionID = 0;
    }
}

- (void)allowDisplaySleep {
    if (self.powerAssertionID != 0) {
        IOPMAssertionRelease(self.powerAssertionID);
        self.powerAssertionID = 0;
    }
}

- (void)closeWindowFromMainQueueWithMessage:(NSString *)message {
    [self.hidSupport releaseAllModifierKeys];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self uncaptureMouse];

        [self.delegate appDidQuit:self.app];
        if (message != nil) {
            [AlertPresenter displayAlert:NSAlertStyleWarning title:@"Connection Failed" message:message window:self.view.window completionHandler:^(NSModalResponse returnCode) {
                [self.view.window close];
            }];
        } else {
            [self.view.window close];
        }
    });
}

- (StreamViewMac *)streamView {
    return (StreamViewMac *)self.view;
}


#pragma mark - Streaming Operations

- (void)prepareForStreaming {
    StreamConfiguration *streamConfig = [[StreamConfiguration alloc] init];
    
    streamConfig.host = self.app.host.activeAddress;
    streamConfig.appID = self.app.id;
    streamConfig.appName = self.app.name;
    streamConfig.serverCert = self.app.host.serverCert;
    streamConfig.serverCodecModeSupport = self.app.host.serverCodecModeSupport;
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];
    
    streamConfig.width = [self.class getResolution].width;
    streamConfig.height = [self.class getResolution].height;

    streamConfig.frameRate = [streamSettings.framerate intValue];

    NSDictionary* prefs = [SettingsClass getSettingsFor:self.app.host.uuid];

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

    // Auto-adjust bitrate (mirrors moonlight-qt default algorithm)
    BOOL autoAdjustBitrate = prefs ? [prefs[@"autoAdjustBitrate"] boolValue] : NO;
    if (autoAdjustBitrate) {
        BOOL enableYuv444 = prefs ? [prefs[@"yuv444"] boolValue] : NO;
        int modeWidth = streamConfig.width;
        int modeHeight = streamConfig.height;
        int modeFps = streamConfig.frameRate;

        // Incorporate remote overrides (host render mode) for bitrate calculation
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
        }

        // Keep even dimensions
        modeWidth &= ~1;
        modeHeight &= ~1;

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
    }
    streamConfig.optimizeGameSettings = streamSettings.optimizeGames;
    streamConfig.playAudioOnPC = streamSettings.playAudioOnPC;
    streamConfig.allowHevc = streamSettings.useHevc;
    streamConfig.enableHdr = streamSettings.useHevc && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) ? streamSettings.enableHdr : NO;

    streamConfig.multiController = streamSettings.multiController;
    streamConfig.gamepadMask = self.useSystemControllerDriver ? [ControllerSupport getConnectedGamepadMask:streamConfig] : 1;
    
    int audioConfigSelection = [SettingsClass audioConfigurationFor:self.app.host.uuid];
    int audioConfig = AUDIO_CONFIGURATION_STEREO;
    if (audioConfigSelection == 1) {
        audioConfig = AUDIO_CONFIGURATION_51_SURROUND;
    } else if (audioConfigSelection == 2) {
        audioConfig = AUDIO_CONFIGURATION_71_SURROUND;
    }
    streamConfig.audioConfiguration = audioConfig;
    
    streamConfig.enableVsync = [SettingsClass enableVsyncFor:self.app.host.uuid];
    streamConfig.showPerformanceOverlay = [SettingsClass showPerformanceOverlayFor:self.app.host.uuid];
    streamConfig.gamepadMouseMode = [SettingsClass gamepadMouseModeFor:self.app.host.uuid];

    if (self.useSystemControllerDriver) {
        if (@available(iOS 13, tvOS 13, macOS 10.15, *)) {
            self.controllerSupport = [[ControllerSupport alloc] initWithConfig:streamConfig presenceDelegate:self];
        }
    }
    self.hidSupport = [[HIDSupport alloc] init:self.app.host];
    
    self.streamMan = [[StreamManager alloc] initWithConfig:streamConfig renderView:self.view connectionCallbacks:self];
    NSOperationQueue* opQueue = [[NSOperationQueue alloc] init];
    [opQueue addOperation:self.streamMan];
    
    // Don’t create the overlay before streaming starts. The video view may be inserted later
    // and would otherwise cover the overlay.
}

- (void)toggleOverlay {
    if (self.overlayContainer) {
        [self.overlayContainer removeFromSuperview];
        self.overlayContainer = nil;
        self.overlayLabel = nil;
        [self.statsTimer invalidate];
        self.statsTimer = nil;
    } else {
        [self setupOverlay];
    }
}

- (void)setupOverlay {
    if (self.overlayContainer) {
        [self.overlayContainer removeFromSuperview];
    }
    
    self.overlayContainer = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    self.overlayContainer.material = NSVisualEffectMaterialHUDWindow;
    self.overlayContainer.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.overlayContainer.state = NSVisualEffectStateActive;
    self.overlayContainer.wantsLayer = YES;
    self.overlayContainer.layer.cornerRadius = 10.0;
    self.overlayContainer.layer.masksToBounds = YES;
    
    self.overlayLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.overlayLabel.bezeled = NO;
    self.overlayLabel.drawsBackground = NO;
    self.overlayLabel.editable = NO;
    self.overlayLabel.selectable = NO;
    self.overlayLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
    
    [self.overlayContainer addSubview:self.overlayLabel];

    // Ensure overlay is always above the video render view.
    [self.view addSubview:self.overlayContainer positioned:NSWindowAbove relativeTo:nil];

    // Hide until we have at least one received frame (avoid showing a black HUD during RTSP handshake).
    self.overlayContainer.hidden = YES;
    
    self.statsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(updateStats) userInfo:nil repeats:YES];
    [self updateStats]; // Initial update
}

- (void)updateStats {
    if (!self.overlayContainer) return;

    VideoStats stats = self.streamMan.connection.renderer.videoStats;
    int videoFormat = self.streamMan.connection.renderer.videoFormat;

    if (stats.receivedFrames == 0) {
        self.overlayContainer.hidden = YES;
        return;
    }
    self.overlayContainer.hidden = NO;
    
    NSString *codecString = @"Unknown";
    if (videoFormat & VIDEO_FORMAT_MASK_H264) {
        codecString = @"H.264";
    } else if (videoFormat & VIDEO_FORMAT_MASK_H265) {
        if (videoFormat & VIDEO_FORMAT_MASK_10BIT) {
            codecString = @"HEVC 10-bit";
        } else {
            codecString = @"HEVC";
        }
    }

    NSString *chromaString = (videoFormat & VIDEO_FORMAT_MASK_YUV444) ? @"4:4:4" : @"4:2:0";
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];

    struct Resolution res = [self.class getResolution];
    int configuredFps = streamSettings.framerate != nil ? [streamSettings.framerate intValue] : 0;
    
    uint32_t rtt = 0;
    uint32_t rttVar = 0;
    LiGetEstimatedRttInfo(&rtt, &rttVar);
    
    float loss = stats.totalFrames > 0 ? (float)stats.networkDroppedFrames / stats.totalFrames * 100.0f : 0;
    
    float renderTime = stats.renderedFrames > 0 ? (float)stats.totalRenderTime / stats.renderedFrames : 0;
    float decodeTime = stats.decodedFrames > 0 ? (float)stats.totalDecodeTime / stats.decodedFrames : 0;
    float encodeTime = stats.framesWithHostProcessingLatency > 0 ? (float)stats.totalHostProcessingLatency / 10.0f / stats.framesWithHostProcessingLatency : 0;
    
    NSMutableAttributedString *attrString = [[NSMutableAttributedString alloc] init];
    
    NSDictionary *labelAttrs = @{
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightRegular]
    };
    
    NSDictionary *valueAttrs = @{
        NSForegroundColorAttributeName: [NSColor colorWithRed:1.0 green:1.0 blue:0.5 alpha:1.0], // Light Yellow
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightBold]
    };
    
    void (^append)(NSString *, NSDictionary *) = ^(NSString *str, NSDictionary *attrs) {
        [attrString appendAttributedString:[[NSAttributedString alloc] initWithString:str attributes:attrs]];
    };
    
    // Resolution & FPS (use configured FPS for the left-side value)
    append([NSString stringWithFormat:@"%dx%d@%d", res.width, res.height, configuredFps], valueAttrs);
    append(@"  ", labelAttrs);
    append(codecString, valueAttrs);
    append(@"  ", labelAttrs);
    append(chromaString, valueAttrs);
    append(@"  FPS ", labelAttrs);
    append([NSString stringWithFormat:@"%.1f", stats.receivedFps], valueAttrs);
    append(@" Rx · ", labelAttrs);
    append([NSString stringWithFormat:@"%.1f", stats.decodedFps], valueAttrs);
    append(@" De · ", labelAttrs);
    append([NSString stringWithFormat:@"%.1f", stats.renderedFps], valueAttrs);
    append(@" Rd", labelAttrs);
    
    // Network
    append(@"  Network ", labelAttrs);
    append([NSString stringWithFormat:@"%u", rtt], valueAttrs);
    append(@" ± ", labelAttrs);
    append([NSString stringWithFormat:@"%u", rttVar], valueAttrs);
    append(@" ms  Loss ", labelAttrs);
    append([NSString stringWithFormat:@"%.2f%%", loss], valueAttrs);
    
    // Latency
    append(@"  |  Render ", labelAttrs);
    append([NSString stringWithFormat:@"%.2f", renderTime], valueAttrs);
    append(@" ms · Decode ", labelAttrs);
    append([NSString stringWithFormat:@"%.2f", decodeTime], valueAttrs);
    append(@" ms · Encode ", labelAttrs);
    append([NSString stringWithFormat:@"%.1f", encodeTime], valueAttrs);
    append(@" ms", labelAttrs);

    self.overlayLabel.attributedStringValue = attrString;
    [self.overlayLabel sizeToFit];
    
    // Layout
    CGFloat padding = 10.0;
    NSRect labelFrame = self.overlayLabel.frame;
    NSRect containerFrame = NSMakeRect(0, 0, labelFrame.size.width + padding * 2, labelFrame.size.height + padding * 2);
    
    // Center top
    CGFloat x = (self.view.bounds.size.width - containerFrame.size.width) / 2;
    CGFloat y = self.view.bounds.size.height - containerFrame.size.height - 20; // 20px from top
    
    containerFrame.origin = NSMakePoint(x, y);
    self.overlayContainer.frame = containerFrame;
    
    self.overlayLabel.frame = NSMakeRect(padding, padding, labelFrame.size.width, labelFrame.size.height);
}


#pragma mark - Resolution

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

- (void)stageComplete:(const char *)stageName {
}

- (void)connectionStarted {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.streamView.statusText = nil;

        // Create overlay after streaming starts so it stays on top of the video view.
        if ([SettingsClass showPerformanceOverlayFor:self.app.host.uuid] && !self.overlayContainer) {
            [self setupOverlay];
        }
        
        if ([SettingsClass autoFullscreenFor:self.app.host.uuid]) {
            if (!(self.view.window.styleMask & NSWindowStyleMaskFullScreen)) {
                [self.view.window toggleFullScreen:self];
            }
        } else {
            [self captureMouse];
        }
    });
}

- (void)connectionTerminated:(int)errorCode {
    Log(LOG_I, @"Connection terminated: %ld", errorCode);
    
    dispatch_async(dispatch_get_main_queue(), ^{
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
        
        if (errorCode == 0 && [SettingsClass quitAppAfterStreamFor:self.app.host.uuid]) {
            [self.delegate quitApp:self.app completion:nil];
        } else {
            [self closeWindowFromMainQueueWithMessage:nil];
        }
    });
}

- (void)stageFailed:(const char *)stageName withError:(int)errorCode {
    Log(LOG_I, @"Stage %s failed: %ld", stageName, errorCode);
    [self closeWindowFromMainQueueWithMessage:[NSString stringWithFormat:@"%s failed with error %d", stageName, errorCode]];
}

- (void)launchFailed:(NSString *)message {
    [self closeWindowFromMainQueueWithMessage:message];
}

- (void)rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor {
    if ([SettingsClass rumbleFor:self.app.host.uuid]) {
        if (self.hidSupport.shouldSendInputEvents) {
            if (self.controllerSupport != nil) {
                [self.controllerSupport rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
            } else {
                [self.hidSupport rumbleLowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
            }
        }
    }
}

- (void)connectionStatusUpdate:(int)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (status == CONN_STATUS_POOR) {
            if ([SettingsClass showConnectionWarningsFor:self.app.host.uuid]) {
                [self showConnectionWarning];
            }
        } else if (status == CONN_STATUS_OKAY) {
            [self hideConnectionWarning];
        }
    });
}

- (void)showConnectionWarning {
    if (self.connectionWarningContainer) {
        return;
    }

    self.connectionWarningContainer = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    self.connectionWarningContainer.material = NSVisualEffectMaterialHUDWindow;
    self.connectionWarningContainer.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.connectionWarningContainer.state = NSVisualEffectStateActive;
    self.connectionWarningContainer.wantsLayer = YES;
    self.connectionWarningContainer.layer.cornerRadius = 10.0;
    self.connectionWarningContainer.layer.masksToBounds = YES;

    self.connectionWarningLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.connectionWarningLabel.bezeled = NO;
    self.connectionWarningLabel.drawsBackground = NO;
    self.connectionWarningLabel.editable = NO;
    self.connectionWarningLabel.selectable = NO;
    self.connectionWarningLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    self.connectionWarningLabel.textColor = [NSColor whiteColor];
    
    // Use a warning symbol if possible, or just text
    NSString *warningText = NSLocalizedString(@"Poor Connection", @"Connection warning overlay");
    self.connectionWarningLabel.stringValue = warningText;
    [self.connectionWarningLabel sizeToFit];

    [self.connectionWarningContainer addSubview:self.connectionWarningLabel];
    [self.view addSubview:self.connectionWarningContainer positioned:NSWindowAbove relativeTo:nil];

    [self layoutConnectionWarning];
    
    // Fade in animation
    self.connectionWarningContainer.alphaValue = 0.0;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.5;
        self.connectionWarningContainer.animator.alphaValue = 1.0;
    } completionHandler:nil];
}

- (void)viewDidLayout {
    [super viewDidLayout];
    [self layoutConnectionWarning];
    [self layoutMouseModeIndicator];
}

- (void)layoutConnectionWarning {
    if (!self.connectionWarningContainer) return;
    
    CGFloat padding = 10.0;
    NSRect labelFrame = self.connectionWarningLabel.frame;
    NSRect containerFrame = NSMakeRect(0, 0, labelFrame.size.width + padding * 2, labelFrame.size.height + padding * 2);

    // Position top right
    CGFloat x = self.view.bounds.size.width - containerFrame.size.width - 20;
    CGFloat y = self.view.bounds.size.height - containerFrame.size.height - 20;

    containerFrame.origin = NSMakePoint(x, y);
    self.connectionWarningContainer.frame = containerFrame;
    self.connectionWarningLabel.frame = NSMakeRect(padding, padding, labelFrame.size.width, labelFrame.size.height);
}

- (void)hideConnectionWarning {
    if (!self.connectionWarningContainer) {
        return;
    }
    
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.5;
        self.connectionWarningContainer.animator.alphaValue = 0.0;
    } completionHandler:^{
        [self.connectionWarningContainer removeFromSuperview];
        self.connectionWarningContainer = nil;
        self.connectionWarningLabel = nil;
    }];
}



#pragma mark - InputPresenceDelegate

- (void)gamepadPresenceChanged {
}

- (void)mousePresenceChanged {
}

- (void)mouseModeToggled:(BOOL)enabled {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *message = enabled ? @"🖱️ Mouse Mode On" : @"🎮 Mouse Mode Off";
        // Localize if possible, but icons help universally
        if (enabled) {
             message = [NSString stringWithFormat:@"🖱️ %@", NSLocalizedString(@"Mouse Mode On", @"Notification")];
             [self showMouseModeIndicator];
        } else {
             message = [NSString stringWithFormat:@"🎮 %@", NSLocalizedString(@"Mouse Mode Off", @"Notification")];
             [self hideMouseModeIndicator];
        }
        [self showNotification:message];
    });
}

- (void)showMouseModeIndicator {
    if (self.mouseModeContainer) {
        return;
    }

    self.mouseModeContainer = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    self.mouseModeContainer.material = NSVisualEffectMaterialHUDWindow;
    self.mouseModeContainer.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.mouseModeContainer.state = NSVisualEffectStateActive;
    self.mouseModeContainer.wantsLayer = YES;
    self.mouseModeContainer.layer.cornerRadius = 10.0;
    self.mouseModeContainer.layer.masksToBounds = YES;

    self.mouseModeLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.mouseModeLabel.bezeled = NO;
    self.mouseModeLabel.drawsBackground = NO;
    self.mouseModeLabel.editable = NO;
    self.mouseModeLabel.selectable = NO;
    self.mouseModeLabel.font = [NSFont systemFontOfSize:24 weight:NSFontWeightRegular]; // Larger font for icon
    self.mouseModeLabel.textColor = [NSColor whiteColor];
    self.mouseModeLabel.stringValue = @"🖱️";
    [self.mouseModeLabel sizeToFit];

    [self.mouseModeContainer addSubview:self.mouseModeLabel];
    [self.view addSubview:self.mouseModeContainer positioned:NSWindowAbove relativeTo:nil];

    [self layoutMouseModeIndicator];
    
    // Fade in animation
    self.mouseModeContainer.alphaValue = 0.0;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.5;
        self.mouseModeContainer.animator.alphaValue = 1.0;
    } completionHandler:nil];
}

- (void)layoutMouseModeIndicator {
    if (!self.mouseModeContainer) return;
    
    CGFloat padding = 10.0;
    NSRect labelFrame = self.mouseModeLabel.frame;
    NSRect containerFrame = NSMakeRect(0, 0, labelFrame.size.width + padding * 2, labelFrame.size.height + padding * 2);

    // Position bottom left to avoid traffic lights
    CGFloat x = 20;
    CGFloat y = 20;

    containerFrame.origin = NSMakePoint(x, y);
    self.mouseModeContainer.frame = containerFrame;
    self.mouseModeLabel.frame = NSMakeRect(padding, padding, labelFrame.size.width, labelFrame.size.height);
}

- (void)hideMouseModeIndicator {
    if (!self.mouseModeContainer) {
        return;
    }
    
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.5;
        self.mouseModeContainer.animator.alphaValue = 0.0;
    } completionHandler:^{
        [self.mouseModeContainer removeFromSuperview];
        self.mouseModeContainer = nil;
        self.mouseModeLabel = nil;
    }];
}

- (void)handleMouseModeToggledNotification:(NSNotification *)note {
    BOOL enabled = [note.userInfo[@"enabled"] boolValue];
    [self mouseModeToggled:enabled];
}

- (void)handleGamepadQuitNotification:(NSNotification *)note {
    [self performCloseAndQuitApp:nil];
}

- (void)showNotification:(NSString *)message {
    [self.notificationTimer invalidate];
    if (self.notificationContainer) {
        [self.notificationContainer removeFromSuperview];
    }

    self.notificationContainer = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    self.notificationContainer.material = NSVisualEffectMaterialHUDWindow;
    self.notificationContainer.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.notificationContainer.state = NSVisualEffectStateActive;
    self.notificationContainer.wantsLayer = YES;
    self.notificationContainer.layer.cornerRadius = 10.0;
    self.notificationContainer.layer.masksToBounds = YES;

    self.notificationLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.notificationLabel.bezeled = NO;
    self.notificationLabel.drawsBackground = NO;
    self.notificationLabel.editable = NO;
    self.notificationLabel.selectable = NO;
    self.notificationLabel.font = [NSFont systemFontOfSize:16 weight:NSFontWeightBold];
    self.notificationLabel.textColor = [NSColor whiteColor];
    self.notificationLabel.stringValue = message;
    [self.notificationLabel sizeToFit];

    [self.notificationContainer addSubview:self.notificationLabel];
    [self.view addSubview:self.notificationContainer positioned:NSWindowAbove relativeTo:nil];

    CGFloat padding = 15.0;
    NSRect labelFrame = self.notificationLabel.frame;
    NSRect containerFrame = NSMakeRect(0, 0, labelFrame.size.width + padding * 2, labelFrame.size.height + padding * 2);

    // Center of screen
    CGFloat x = (self.view.bounds.size.width - containerFrame.size.width) / 2;
    CGFloat y = (self.view.bounds.size.height - containerFrame.size.height) / 2;

    containerFrame.origin = NSMakePoint(x, y);
    self.notificationContainer.frame = containerFrame;
    self.notificationLabel.frame = NSMakeRect(padding, padding, labelFrame.size.width, labelFrame.size.height);

    // Animation
    self.notificationContainer.alphaValue = 0.0;
    self.notificationContainer.layer.transform = CATransform3DMakeScale(0.8, 0.8, 1.0);
    
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.2;
        self.notificationContainer.animator.alphaValue = 1.0;
    } completionHandler:nil];

    CABasicAnimation *scaleAnim = [CABasicAnimation animationWithKeyPath:@"transform"];
    scaleAnim.fromValue = [NSValue valueWithCATransform3D:CATransform3DMakeScale(0.8, 0.8, 1.0)];
    scaleAnim.toValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
    scaleAnim.duration = 0.2;
    self.notificationContainer.layer.transform = CATransform3DIdentity;
    [self.notificationContainer.layer addAnimation:scaleAnim forKey:@"scale"];

    // Auto hide
    self.notificationTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:NO block:^(NSTimer * _Nonnull timer) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.5;
            self.notificationContainer.animator.alphaValue = 0.0;
        } completionHandler:^{
            [self.notificationContainer removeFromSuperview];
            self.notificationContainer = nil;
        }];
    }];
}

@end
