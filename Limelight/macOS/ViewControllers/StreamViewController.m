//
//  StreamViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 25/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "StreamViewController.h"

#import "Connection.h"
#import "StreamConfiguration.h"
#import "DataManager.h"
#import "ControllerSupport.h"
#import "StreamManager.h"
#import "VideoDecoderRenderer.h"
#import "HIDSupport.h"
#include "Limelight.h"

@interface StreamViewController () <ConnectionCallbacks>

@property (nonatomic, strong) ControllerSupport *controllerSupport;
@property (nonatomic, strong) HIDSupport *hidSupport;
@property (nonatomic, strong) StreamManager *streamMan;

@end

@implementation StreamViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    
    [self prepareForStreaming];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    
    self.view.window.title = self.app.name;
    [self.view.window makeFirstResponder:self.view];
    
    [self captureMouse];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    
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
    [self captureMouse];
    [self.hidSupport mouseDown:event withButton:BUTTON_LEFT];
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

- (void)captureMouse {
    if (!self.hidSupport.shouldSendMouseEvents) {
        CGAssociateMouseAndMouseCursorPosition(NO);
        [NSCursor hide];
        
        CGRect rectInWindow = [self.view convertRect:self.view.bounds toView:nil];
        CGRect rectInScreen = [self.view.window convertRectToScreen:rectInWindow];
        CGFloat screenHeight = self.view.window.screen.frame.size.height;
        CGPoint cursorPoint = CGPointMake(CGRectGetMidX(rectInScreen), screenHeight - CGRectGetMidY(rectInScreen));
        CGWarpMouseCursorPosition(cursorPoint);
        
        self.hidSupport.shouldSendMouseEvents = YES;
    }
}

- (void)uncaptureMouse {
    if (self.hidSupport.shouldSendMouseEvents) {
        CGAssociateMouseAndMouseCursorPosition(YES);
        [NSCursor unhide];
        self.hidSupport.shouldSendMouseEvents = NO;
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
