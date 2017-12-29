//
//  StreamViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 25/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "StreamViewController.h"
#import "NSWindow+Moonlight.h"

#import "Connection.h"
#import "StreamConfiguration.h"
#import "DataManager.h"
#import "ControllerSupport.h"
#import "StreamManager.h"
#import "VideoDecoderRenderer.h"
#import "HIDSupport.h"
#include "Limelight.h"

#import <IOKit/pwr_mgt/IOPMLib.h>

@interface StreamViewController () <ConnectionCallbacks>

@property (nonatomic, strong) ControllerSupport *controllerSupport;
@property (nonatomic, strong) HIDSupport *hidSupport;
@property (nonatomic, strong) StreamManager *streamMan;

@property (nonatomic) IOPMAssertionID powerAssertionID;

@end

@implementation StreamViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    
    [self prepareForStreaming];
    
    __weak typeof(self) weakSelf = self;
    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResignKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if (![weakSelf isWindowInCurrentSpace]) {
            [weakSelf uncaptureMouse];
        }
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isWindowInCurrentSpace]) {
            if ([weakSelf.view.window styleMask] & NSWindowStyleMaskFullScreen) {
                [weakSelf captureMouse];
            }
        }
    }];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    
    self.view.window.title = self.app.name;
    [self.view.window makeFirstResponder:self.view];
    
    self.view.window.contentAspectRatio = NSMakeSize(16, 9);
    self.view.window.frameAutosaveName = @"Stream Window";
    [self.view.window moonlight_centerWindowOnFirstRun];
    
    self.view.window.styleMask |= NSWindowStyleMaskTexturedBackground;
    self.view.window.backgroundColor = [NSColor colorWithRed:0.168 green:0.18 blue:0.196 alpha:1];
    self.view.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    
    [self captureMouse];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    
    [self uncaptureMouse];
    [self.streamMan stopStream];
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

- (void)scrollWheel:(NSEvent *)event {
    [self.hidSupport scrollWheel:event];
}


#pragma mark - Helpers

- (void)enableMenuItems:(BOOL)enable {
    NSMenu *appMenu = [[NSApplication sharedApplication].mainMenu itemWithTag:1000].submenu;
    NSMenu *fileMenu = [[NSApplication sharedApplication].mainMenu itemWithTag:2000].submenu;
    appMenu.autoenablesItems = enable;
    fileMenu.autoenablesItems = enable;
    [self itemWithMenu:appMenu andAction:@selector(terminate:)].enabled = enable;
    [self itemWithMenu:fileMenu andAction:@selector(performClose:)].enabled = enable;
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
    }
}

- (void)uncaptureMouse {
    if (self.hidSupport.shouldSendMouseEvents) {
        CGAssociateMouseAndMouseCursorPosition(YES);
        [NSCursor unhide];
        
        [self enableMenuItems:YES];

        [self allowDisplaySleep];

        self.hidSupport.shouldSendMouseEvents = NO;
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


#pragma mark - Streaming Operations

- (void)prepareForStreaming {
    StreamConfiguration *streamConfig = [[StreamConfiguration alloc] init];
    
    streamConfig.host = self.app.host.activeAddress;
    streamConfig.appID = self.app.id;
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];
    
    streamConfig.frameRate = [streamSettings.framerate intValue];
    streamConfig.bitRate = 20000; // [streamSettings.bitrate intValue];
    streamConfig.height = 1080; // [streamSettings.height intValue];
    streamConfig.width = 1920; // [streamSettings.width intValue];
    
    
    self.controllerSupport = [[ControllerSupport alloc] init];
    self.hidSupport = [[HIDSupport alloc] init];
    
    self.streamMan = [[StreamManager alloc] initWithConfig:streamConfig renderView:self.view connectionCallbacks:self];
    NSOperationQueue* opQueue = [[NSOperationQueue alloc] init];
    [opQueue addOperation:self.streamMan];
}


#pragma mark - ConnectionCallbacks

- (void)connectionStarted {
    
}

- (void)connectionTerminated:(long)errorCode {
    Log(LOG_I, @"Connection terminated: %ld", errorCode);
    [self.streamMan stopStream];
}

- (void)displayMessage:(const char *)message {
    
}

- (void)displayTransientMessage:(const char *)message {
    
}

- (void)launchFailed:(NSString *)message {
    
}

- (void)stageComplete:(const char *)stageName {
    
}

- (void)stageFailed:(const char *)stageName withError:(long)errorCode {
    Log(LOG_I, @"Stage %s failed: %ld", stageName, errorCode);
    [self.streamMan stopStream];
}

- (void)stageStarting:(const char *)stageName {
    
}

@end
