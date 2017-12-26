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
}

- (void)flagsChanged:(NSEvent *)event {
    [self.hidSupport flagsChanged:event];
}

- (void)keyDown:(NSEvent *)event {
    [self.hidSupport keyDown:event];
}

- (void)keyUp:(NSEvent *)event {
    [self.hidSupport keyUp:event];
}

#pragma mark - Streaming Operations

- (void)prepareForStreaming {
    StreamConfiguration *streamConfig = [[StreamConfiguration alloc] init];
    
    streamConfig.host = self.app.host.activeAddress;
    streamConfig.appID = self.app.id;
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];
    
    streamConfig.frameRate = [streamSettings.framerate intValue];
    streamConfig.bitRate = [streamSettings.bitrate intValue];
    streamConfig.height = [streamSettings.height intValue];
    streamConfig.width = [streamSettings.width intValue];
    
    
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
    
}

- (void)stageStarting:(const char *)stageName {
    
}

@end
