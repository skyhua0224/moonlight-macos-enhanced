//
//  StreamingSessionManager.m
//  Limelight
//
//  Created by SkyHua on 2025-01-20.
//

#import "StreamingSessionManager.h"
#import "MoonlightEnhanced-Swift.h"

@interface StreamingSessionManager ()

@property (nonatomic, readwrite) StreamingState state;
@property (nonatomic, readwrite, nullable) NSString *activeHostUUID;
@property (nonatomic, readwrite, nullable) NSString *activeAppId;
@property (nonatomic, readwrite, nullable) NSString *activeAppName;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *sessions;
@property (nonatomic, strong) NSMapTable<NSString *, NSViewController *> *launchedControllers;

// Stream statistics
@property (nonatomic, readwrite) double currentLatency;
@property (nonatomic, readwrite, nullable) NSString *currentResolution;
@property (nonatomic, readwrite) NSInteger currentFramerate;
@property (nonatomic, readwrite) double connectionQuality;

@end

@interface StreamingSession : NSObject
@property (nonatomic, copy) NSString *hostUUID;
@property (nonatomic, copy, nullable) NSString *appId;
@property (nonatomic, copy, nullable) NSString *appName;
@property (nonatomic, weak, nullable) NSWindowController *windowController;
@property (nonatomic) StreamingState state;
@property (nonatomic) double latency;
@property (nonatomic, copy, nullable) NSString *resolution;
@property (nonatomic) NSInteger framerate;
@property (nonatomic) double quality;
@end

@implementation StreamingSession
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
        _sessions = [NSMutableDictionary dictionary];
        _launchedControllers = [NSMapTable strongToWeakObjectsMapTable];
    }
    return self;
}

- (void)noteStreamViewController:(id)viewController forHost:(NSString *)hostUUID {
    if (hostUUID.length == 0 || ![viewController isKindOfClass:[NSViewController class]]) return;
    [self.launchedControllers setObject:viewController forKey:hostUUID];
}

- (NSWindow *)liveStreamWindowForHost:(NSString *)hostUUID {
    if (hostUUID.length == 0) return nil;
    NSViewController *controller = [self.launchedControllers objectForKey:hostUUID];
    NSWindow *window = controller.isViewLoaded ? controller.view.window : nil;
    return (window != nil && (window.isVisible || window.isMiniaturized)) ? window : nil;
}

- (BOOL)canStartStreamForHost:(NSString *)hostUUID {
    StreamingSession *session = self.sessions[hostUUID];
    return (session == nil || session.state == StreamingStateIdle || session.state == StreamingStateDisconnecting);
}

- (void)startStreamingWithHost:(NSString *)hostUUID
                         appId:(NSString *)appId
                       appName:(NSString *)appName
            windowController:(NSWindowController *)windowController {

    StreamingSession *session = self.sessions[hostUUID];
    if (!session) {
        session = [[StreamingSession alloc] init];
        session.hostUUID = hostUUID;
        self.sessions[hostUUID] = session;
    }

    session.appId = appId;
    session.appName = appName;
    session.windowController = windowController;
    session.state = StreamingStateStreaming;
    // the launch is over, the stream owns the link now: nothing in the background until it ends
    [MLNetworkQuiet end:[@"launch:" stringByAppendingString:hostUUID]];
    [MLNetworkQuiet beginStream:[@"stream:" stringByAppendingString:hostUUID]];
    session.latency = 0;
    session.resolution = nil;
    session.framerate = 0;
    session.quality = 1.0;

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

    [self postStateChangeNotificationForHost:hostUUID];
}

- (void)updateStreamStats:(double)latency
               resolution:(NSString *)resolution
                framerate:(NSInteger)framerate
                  quality:(double)quality {
    if (!self.activeHostUUID) {
        return;
    }

    StreamingSession *session = self.sessions[self.activeHostUUID];
    if (session) {
        session.latency = latency;
        session.resolution = resolution;
        session.framerate = framerate;
        session.quality = quality;
    }

    self.currentLatency = latency;
    self.currentResolution = resolution;
    self.currentFramerate = framerate;
    self.connectionQuality = quality;
    
    // We could post a notification here if we wanted real-time UI updates elsewhere,
    // but for now we just store it.
}

- (void)didDisconnect {
    if (self.activeHostUUID) {
        [self didDisconnectForHost:self.activeHostUUID];
    }
}

- (BOOL)isStreamingHost:(NSString *)hostUUID {
    StreamingSession *session = self.sessions[hostUUID];
    return session != nil && session.state == StreamingStateStreaming;
}

- (nullable NSString *)appNameForHost:(NSString *)hostUUID {
    StreamingSession *session = self.sessions[hostUUID];
    return session.appName;
}

- (void)didDisconnectForHost:(NSString *)hostUUID {
    // the stream (or the launch that never got to one) is over: the next click may launch, background work resumes
    [MLNetworkQuiet end:[@"stream:" stringByAppendingString:hostUUID ?: @""]];
    [MLNetworkQuiet end:[@"launch:" stringByAppendingString:hostUUID ?: @""]];
    [MLLaunchGate release:hostUUID ?: @""];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MLLaunchStateChanged" object:nil userInfo:@{@"hostUUID": hostUUID ?: @""}];
    StreamingSession *session = self.sessions[hostUUID];
    if (session) {
        session.state = StreamingStateIdle;
        session.windowController = nil;
        session.appId = nil;
        session.appName = nil;
    }

    if ([self.activeHostUUID isEqualToString:hostUUID]) {
        self.activeHostUUID = nil;
        self.activeAppId = nil;
        self.activeAppName = nil;
        self.streamWindowController = nil;
        self.state = StreamingStateIdle;
    }

    [self postStateChangeNotificationForHost:hostUUID];
}

- (void)focusStreamWindow {
    if (self.activeHostUUID) {
        [self focusStreamWindowForHost:self.activeHostUUID];
    }
}

- (void)focusStreamWindowForHost:(NSString *)hostUUID {
    StreamingSession *session = self.sessions[hostUUID];
    NSWindowController *controller = session.windowController;
    if (controller && controller.window) {
        NSWindow *window = controller.window;

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

    if (self.activeHostUUID) {
        [self disconnectHost:self.activeHostUUID];
    } else if (self.state != StreamingStateIdle) {
        [self didDisconnect];
    }
}

- (void)disconnectHost:(NSString *)hostUUID {
    StreamingSession *session = self.sessions[hostUUID];
    if (session.windowController) {
        NSDictionary *userInfo = @{ @"hostUUID": hostUUID };
        [[NSNotificationCenter defaultCenter] postNotificationName:@"StreamingSessionRequestDisconnect"
                                                            object:nil
                                                          userInfo:userInfo];
    } else {
        [self didDisconnectForHost:hostUUID];
    }
}

- (void)requestDisconnectWithQuitApp:(BOOL)quitApp {
    if (self.activeHostUUID) {
        [self requestDisconnectWithQuitApp:quitApp hostUUID:self.activeHostUUID];
    } else if (self.state != StreamingStateIdle) {
        [self didDisconnect];
    }
}

- (void)requestDisconnectWithQuitApp:(BOOL)quitApp hostUUID:(NSString *)hostUUID {
    StreamingSession *session = self.sessions[hostUUID];
    if (session.windowController) {
        NSDictionary *userInfo = @{ @"quitApp": @(quitApp), @"hostUUID": hostUUID };
        [[NSNotificationCenter defaultCenter] postNotificationName:@"StreamingSessionRequestDisconnect"
                                                            object:nil
                                                          userInfo:userInfo];
    } else {
        [self didDisconnectForHost:hostUUID];
    }
}

- (void)postStateChangeNotificationForHost:(NSString *)hostUUID {
    StreamingSession *session = self.sessions[hostUUID];
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[@"state"] = @(session ? session.state : StreamingStateIdle);
    userInfo[@"hostUUID"] = hostUUID;
    if (session.appId) userInfo[@"appId"] = session.appId;
    if (session.appName) userInfo[@"appName"] = session.appName;

    // Dispatch on main thread to ensure UI updates are safe
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"StreamingStateChanged"
                                                            object:self
                                                          userInfo:userInfo];
    });
}

@end
