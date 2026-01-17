//
//  StreamingSessionManager.m
//  Limelight
//
//  Created by SkyHua on 2025-01-20.
//

#import "StreamingSessionManager.h"

@interface StreamingSessionManager ()

@property (nonatomic, readwrite) StreamingState state;
@property (nonatomic, readwrite, nullable) NSString *activeHostUUID;
@property (nonatomic, readwrite, nullable) NSString *activeAppId;
@property (nonatomic, readwrite, nullable) NSString *activeAppName;

// Stream statistics
@property (nonatomic, readwrite) double currentLatency;
@property (nonatomic, readwrite, nullable) NSString *currentResolution;
@property (nonatomic, readwrite) NSInteger currentFramerate;
@property (nonatomic, readwrite) double connectionQuality;

@end

@implementation StreamingSessionManager

+ (instancetype)shared {
    static StreamingSessionManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[StreamingSessionManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = StreamingStateIdle;
        _currentLatency = 0.0;
        _currentResolution = @"Unknown";
        _currentFramerate = 0;
        _connectionQuality = 1.0;
    }
    return self;
}

- (BOOL)canStartStreamForHost:(NSString *)hostUUID {
    // Allow if no active stream OR different host (multi-host streaming)
    // If you want to restrict to single stream globally, remove the second condition
    return self.state == StreamingStateIdle ||
           ![self.activeHostUUID isEqualToString:hostUUID];
}

- (void)startStreamingWithHost:(NSString *)hostUUID
                         appId:(NSString *)appId
                       appName:(NSString *)appName
            windowController:(NSWindowController *)windowController {

    self.activeHostUUID = hostUUID;
    self.activeAppId = appId;
    self.activeAppName = appName;
    self.streamWindowController = windowController;
    self.state = StreamingStateStreaming;
    
    // Reset stats
    self.currentLatency = 0;
    self.currentResolution = nil;
    self.currentFramerate = 0;
    self.connectionQuality = 1.0;

    [self postStateChangeNotification];
}

- (void)updateStreamStats:(double)latency
               resolution:(NSString *)resolution
                framerate:(NSInteger)framerate
                  quality:(double)quality {
    self.currentLatency = latency;
    self.currentResolution = resolution;
    self.currentFramerate = framerate;
    self.connectionQuality = quality;
    
    // We could post a notification here if we wanted real-time UI updates elsewhere,
    // but for now we just store it.
}

- (void)didDisconnect {
    self.activeHostUUID = nil;
    self.activeAppId = nil;
    self.activeAppName = nil;
    self.streamWindowController = nil;
    self.state = StreamingStateIdle;

    [self postStateChangeNotification];
}

- (void)focusStreamWindow {
    if (self.streamWindowController && self.streamWindowController.window) {
        NSWindow *window = self.streamWindowController.window;

        // This handles Space switching automatically on macOS
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];

        if (window.isMiniaturized) {
            [window deminiaturize:nil];
        }
    }
}

- (void)disconnect {
    // This assumes StreamViewController listens for disconnection requests
    // or we access it directly if we had a strong reference to the VC.
    // However, usually we rely on the VC closing or user action.
    // For this implementation, since we have the window controller,
    // we can try to find the StreamViewController and tell it to stop.

    if (self.streamWindowController) {
        NSViewController *contentVC = self.streamWindowController.contentViewController;
        if ([contentVC respondsToSelector:@selector(performSelector:)]) {
            // Assuming StreamViewController has a method to stop stream or we close window
            // If StreamViewController has a specific stop method, we should call it.
            // For now, let's post a notification that StreamViewController can listen to,
            // or simply close the window which usually triggers cleanup.

            // Notification based approach (cleaner decoupling)
            [[NSNotificationCenter defaultCenter] postNotificationName:@"StreamingSessionRequestDisconnect" object:nil];
        }
    } else if (self.state != StreamingStateIdle) {
        // Fallback: If the window is already gone (controller is nil) but we are still in a streaming state,
        // it means we have a "zombie" session. We should forcibly clean up.
        // This prevents the "Ghost Session" issue where the overlay thinks we are streaming but we aren't.
        [self didDisconnect];
    }
}

- (void)requestDisconnectWithQuitApp:(BOOL)quitApp {
    if (self.streamWindowController) {
        NSDictionary *userInfo = @{ @"quitApp": @(quitApp) };
        [[NSNotificationCenter defaultCenter] postNotificationName:@"StreamingSessionRequestDisconnect"
                                                            object:nil
                                                          userInfo:userInfo];
    } else if (self.state != StreamingStateIdle) {
        [self didDisconnect];
    }
}

- (void)postStateChangeNotification {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[@"state"] = @(self.state);

    if (self.activeHostUUID) userInfo[@"hostUUID"] = self.activeHostUUID;
    if (self.activeAppId) userInfo[@"appId"] = self.activeAppId;
    if (self.activeAppName) userInfo[@"appName"] = self.activeAppName;

    // Dispatch on main thread to ensure UI updates are safe
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"StreamingStateChanged"
                                                            object:self
                                                          userInfo:userInfo];
    });
}

@end
