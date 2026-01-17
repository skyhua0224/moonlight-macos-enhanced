//
//  StreamingSessionManager.h
//  Limelight
//
//  Created by SkyHua on 2025-01-20.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, StreamingState) {
    StreamingStateIdle,
    StreamingStateConnecting,
    StreamingStateStreaming,
    StreamingStateDisconnecting
};

@interface StreamingSessionManager : NSObject

@property (nonatomic, readonly) StreamingState state;
@property (nonatomic, readonly, nullable) NSString *activeHostUUID;
@property (nonatomic, readonly, nullable) NSString *activeAppId;
@property (nonatomic, readonly, nullable) NSString *activeAppName;
@property (nonatomic, weak, nullable) NSWindowController *streamWindowController;

// Stream statistics
@property (nonatomic, readonly) double currentLatency;
@property (nonatomic, readonly, nullable) NSString *currentResolution;
@property (nonatomic, readonly) NSInteger currentFramerate;
@property (nonatomic, readonly) double connectionQuality; // 0.0 to 1.0

+ (instancetype)shared;

// Check if a new stream can be started for the given host
// Returns YES if idle OR if the active stream is for a DIFFERENT host (allowing parallel streams)
- (BOOL)canStartStreamForHost:(NSString *)hostUUID;

// Start a session
- (void)startStreamingWithHost:(NSString *)hostUUID
                         appId:(NSString *)appId
                       appName:(NSString *)appName
            windowController:(NSWindowController *)windowController;

// Update stream statistics
- (void)updateStreamStats:(double)latency 
               resolution:(NSString *)resolution 
                framerate:(NSInteger)framerate 
                  quality:(double)quality;

// Signal that disconnection occurred (cleanup)
- (void)didDisconnect;

// Focus the streaming window
- (void)focusStreamWindow;

// Request disconnection (active action)
- (void)disconnect;

// Request disconnection with explicit action (quitApp=YES means quit Sunshine app only)
- (void)requestDisconnectWithQuitApp:(BOOL)quitApp;

@end

NS_ASSUME_NONNULL_END
