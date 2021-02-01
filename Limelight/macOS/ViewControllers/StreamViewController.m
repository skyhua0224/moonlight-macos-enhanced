//
//  StreamViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 25/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "StreamViewController.h"
#import "StreamViewMac.h"
#import "NSWindow+Moonlight.h"
#import "AlertPresenter.h"

#import "Connection.h"
#import "StreamConfiguration.h"
#import "DataManager.h"
#import "ControllerSupport.h"
#import "StreamManager.h"
#import "VideoDecoderRenderer.h"
#import "HIDSupport.h"
#include "Limelight.h"

#import <IOKit/pwr_mgt/IOPMLib.h>
#import <Carbon/Carbon.h>

#import "Moonlight-Swift.h"

@interface StreamViewController () <ConnectionCallbacks, KeyboardNotifiableDelegate>

@property (nonatomic, strong) ControllerSupport *controllerSupport;
@property (nonatomic, strong) HIDSupport *hidSupport;
@property (nonatomic, strong) StreamManager *streamMan;
@property (nonatomic, readonly) StreamViewMac *streamView;

@property (nonatomic) IOPMAssertionID powerAssertionID;

@end

@implementation StreamViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    
    [self prepareForStreaming];
    
    __weak typeof(self) weakSelf = self;
    
    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidEnterFullScreenNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"autoFullscreen"]) {
            [NSCursor hide];
        }
    }];
    
    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResignKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if (![weakSelf isWindowInCurrentSpace]) {
            [weakSelf uncaptureMouse];
        }
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isWindowInCurrentSpace]) {
            if ([weakSelf.view.window styleMask] & NSWindowStyleMaskFullScreen) {
                if ([weakSelf.view.window isKeyWindow]) {
                    [weakSelf captureMouse];
                }
            }
        }
    }];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    
    self.streamView.keyboardNotifiable = self;
    self.streamView.appName = self.app.name;
    self.streamView.statusText = @"Starting";
    self.view.window.tabbingMode = NSWindowTabbingModeDisallowed;
    [self.view.window makeFirstResponder:self];
    
    self.view.window.contentAspectRatio = NSMakeSize(16, 9);
    self.view.window.frameAutosaveName = @"Stream Window";
    [self.view.window moonlight_centerWindowOnFirstRun];
    
    self.view.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    
    [self captureMouse];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    
    [self uncaptureMouse];
    [self.streamMan stopStream];
}

- (void)dealloc {
    [self.hidSupport tearDownHidManager];
    self.hidSupport = nil;
}

- (void)flagsChanged:(NSEvent *)event {
    [self.hidSupport flagsChanged:event];
    
    if ((event.modifierFlags & NSEventModifierFlagCommand) && (event.modifierFlags & NSEventModifierFlagOption)) {
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
    [self.hidSupport mouseDown:event withButton:BUTTON_MIDDLE];
}

- (void)otherMouseUp:(NSEvent *)event {
    [self.hidSupport mouseUp:event withButton:BUTTON_MIDDLE];
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


#pragma mark - KeyboardNotifiable

- (BOOL)onKeyboardEquivalent:(NSEvent *)event {
    const NSEventModifierFlags modifierFlags = NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand;
    const NSEventModifierFlags eventModifierFlags = event.modifierFlags & modifierFlags;
    
    if ((event.keyCode == kVK_ANSI_F && eventModifierFlags == (NSEventModifierFlagControl | NSEventModifierFlagCommand))
        || (event.keyCode == kVK_ANSI_W && eventModifierFlags == (NSEventModifierFlagOption | NSEventModifierFlagCommand))
        || (event.keyCode == kVK_ANSI_W && eventModifierFlags == (NSEventModifierFlagShift | NSEventModifierFlagCommand))
        || (event.keyCode == kVK_ANSI_W && eventModifierFlags == NSEventModifierFlagCommand)
        ) {
        return NO;
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
    alert.messageText = @"Disconnect from Stream, or Close and Quit App?";

    [alert addButtonWithTitle:@"Disconnect from Stream"];
    [alert addButtonWithTitle:@"Close and Quit App"];
    [alert addButtonWithTitle:@"Cancel"];

    NSModalResponse response = [alert runModal];
    switch (response) {
        case NSAlertFirstButtonReturn:
            [self doCommandBySelector:@selector(performCloseStreamWindow:)];
            break;
            
        case NSAlertSecondButtonReturn:
            [self doCommandBySelector:@selector(performCloseAndQuitApp:)];
            break;

        default:
            break;
    }
}

- (IBAction)performCloseStreamWindow:(id)sender {
    [self.hidSupport releaseAllModifierKeys];

    [self.nextResponder doCommandBySelector:@selector(performClose:)];
}

- (IBAction)performCloseAndQuitApp:(id)sender {
    [self performCloseStreamWindow:sender];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.delegate quitApp:self.app completion:nil];
    });
}


#pragma mark - Helpers

- (void)enableMenuItems:(BOOL)enable {
    NSMenu *appMenu = [[NSApplication sharedApplication].mainMenu itemWithTag:1000].submenu;
    appMenu.autoenablesItems = enable;
    [self itemWithMenu:appMenu andAction:@selector(terminate:)].enabled = enable;
}

- (void)captureMouse {
    if (!self.hidSupport.shouldSendMouseEvents) {
        CGAssociateMouseAndMouseCursorPosition(NO);
        [NSCursor hide];
        
        CGRect rectInWindow = [self.view convertRect:self.view.bounds toView:nil];
        CGRect rectInScreen = [self.view.window convertRectToScreen:rectInWindow];
        CGFloat screenHeight = self.view.window.screen.frame.size.height;
        CGPoint cursorPoint = CGPointMake(CGRectGetMidX(rectInScreen), screenHeight - CGRectGetMidY(rectInScreen));
        CGWarpMouseCursorPosition(cursorPoint);
        
        [self enableMenuItems:NO];

        [self disallowDisplaySleep];
        
        self.hidSupport.shouldSendMouseEvents = YES;
        self.view.window.acceptsMouseMovedEvents = YES;
    }
}

- (void)uncaptureMouse {
    if (self.hidSupport.shouldSendMouseEvents) {
        CGAssociateMouseAndMouseCursorPosition(YES);
        [NSCursor unhide];
        
        [self enableMenuItems:YES];

        [self allowDisplaySleep];

        self.hidSupport.shouldSendMouseEvents = NO;
        self.view.window.acceptsMouseMovedEvents = NO;
    }
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
        [self.delegate appDidQuit:self.app];
        if (message != nil) {
            [AlertPresenter displayAlert:NSAlertStyleWarning title:@"Connection Failed" message:message window:self.view.window completionHandler:^(NSModalResponse returnCode) {
                [self.view.window close];
            }];
        } else {
            [self.view.window close];
        }
    });
    
    [ResolutionSyncRequester resetResolutionFor:self.app.host.activeAddress];
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
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];
    
    BOOL syncEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"shouldSync"];
    if (syncEnabled) {
        streamConfig.height = (int)[[NSUserDefaults standardUserDefaults] integerForKey:@"syncHeight"];
        streamConfig.width = (int)[[NSUserDefaults standardUserDefaults] integerForKey:@"syncWidth"];
    } else {
        streamConfig.height = [streamSettings.height intValue];
        streamConfig.width = [streamSettings.width intValue];
    }

    streamConfig.frameRate = [streamSettings.framerate intValue];
    streamConfig.bitRate = [streamSettings.bitrate intValue];
    streamConfig.optimizeGameSettings = streamSettings.optimizeGames;
    streamConfig.playAudioOnPC = streamSettings.playAudioOnPC;
    streamConfig.allowHevc = streamSettings.useHevc;
    
    streamConfig.audioConfiguration = AUDIO_CONFIGURATION_STEREO;

    BOOL useSystemControllerDriver = [[NSUserDefaults standardUserDefaults] integerForKey:@"controllerDriver"] == 1;
    if (useSystemControllerDriver) {
        if (@available(iOS 13, tvOS 13, macOS 10.15, *)) {
            self.controllerSupport = [[ControllerSupport alloc] initWithConfig:streamConfig];
        }
    }
    self.hidSupport = [[HIDSupport alloc] init];
    
    self.streamMan = [[StreamManager alloc] initWithConfig:streamConfig renderView:self.view connectionCallbacks:self];
    NSOperationQueue* opQueue = [[NSOperationQueue alloc] init];
    [opQueue addOperation:self.streamMan];
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
    [ResolutionSyncRequester setResolutionFor:self.app.host.activeAddress refreshRate:60];
    
    BOOL useHIDControllerDriver = [[NSUserDefaults standardUserDefaults] integerForKey:@"controllerDriver"] == 0;
    if (useHIDControllerDriver) {
        [self.hidSupport rumbleLowFreqMotor:0 highFreqMotor:0];
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.streamView.statusText = nil;
        
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"autoFullscreen"]) {
            if (!(self.view.window.styleMask & NSWindowStyleMaskFullScreen)) {
                [self.view.window toggleFullScreen:self];
            }
        }
    });
}

- (void)connectionTerminated:(int)errorCode {
    Log(LOG_I, @"Connection terminated: %ld", errorCode);
    [self closeWindowFromMainQueueWithMessage:nil];
}

- (void)stageFailed:(const char *)stageName withError:(int)errorCode {
    Log(LOG_I, @"Stage %s failed: %ld", stageName, errorCode);
    [self closeWindowFromMainQueueWithMessage:[NSString stringWithFormat:@"%s failed with error %d", stageName, errorCode]];
}

- (void)launchFailed:(NSString *)message {
    [self closeWindowFromMainQueueWithMessage:message];
}

- (void)rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor {
    if (self.controllerSupport != nil) {
        [self.controllerSupport rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
    } else {
        [self.hidSupport rumbleLowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
    }
}

- (void)connectionStatusUpdate:(int)status {
}

@end
