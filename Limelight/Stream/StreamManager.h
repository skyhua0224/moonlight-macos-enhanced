//
//  StreamManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "Connection.h"
#import "StreamConfiguration.h"

@interface StreamManager : NSOperation

@property(nonatomic, readonly) Connection *connection;
@property(nonatomic, readonly) StreamConfiguration *streamConfiguration;

- (id)initWithConfig:(StreamConfiguration *)config
             renderView:(OSView *)view
    connectionCallbacks:(id<ConnectionCallbacks>)callback;

- (void)stopStream;

@end

// Foundation Sunshine remote display scale: reads the Windows display scale of the streamed
// display and lets the user change it from the control center. The host is changed only when
// asked: by hand there, or by a Free Window set to Every Pixel; never when a stream ends. Host calls run on a private serial
// queue; nothing here blocks the caller.
typedef NS_ENUM(NSInteger, MLRemoteDisplayScaleSupport) {
    // Not asked yet, or the last request failed in a way that may be temporary.
    MLRemoteDisplayScaleSupportUnknown = 0,
    MLRemoteDisplayScaleSupportAvailable,
    // Older host, non-Windows host, or a display whose scale cannot be set.
    MLRemoteDisplayScaleSupportUnavailable,
};

// Outcome keys: ok (BOOL), changed (BOOL), percent (NSNumber, resulting value),
// restartRequired (BOOL), errorCode (NSString), httpStatus (NSNumber).
typedef void (^MLRemoteDisplayScaleCompletion)(NSDictionary<NSString *, id> *outcome);

@interface MLRemoteDisplayScale : NSObject

// Thread-safe snapshots of what the host last reported for the streamed display.
@property (nonatomic, readonly) MLRemoteDisplayScaleSupport support;
// YES until the first options query of this object has finished.
@property (nonatomic, readonly) BOOL awaitingFirstQuery;
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *supportedPercents;
@property (nonatomic, readonly) NSInteger currentPercent;      // 0 when unknown
@property (nonatomic, readonly) NSInteger recommendedPercent;  // 0 when unknown

// Called on the main queue after the snapshot above may have changed (an options query
// finished, or a scale was applied), so a control center that is already open can update in
// place. Cleared when the session ends.
@property (nonatomic, copy, nullable) void (^optionsDidChangeHandler)(void);

- (instancetype)initWithHostAddress:(NSString *)hostAddress
                         serverCert:(NSData *)serverCert;
- (void)updateHostAddress:(NSString *)hostAddress serverCert:(NSData *)serverCert;

// Stream start. Reads the display's scale options so the control center knows what to
// offer; the host is left as it is. targetDisplay is the session's target display id
// (empty = the host default, its primary display).
- (void)beginSessionWithTargetDisplay:(NSString *)targetDisplay;

// Control center: the user changes the host's scale by hand. Applied now and kept on the host
// after the stream, exactly as if it had been changed in Windows; it is not saved anywhere and
// nothing puts the old value back. Only acts on the session that is live when this is called;
// if the stream ends (or is replaced) before the request reaches the host it is dropped and the
// completion is not called.
- (void)applyManualPercent:(NSInteger)percent
                completion:(MLRemoteDisplayScaleCompletion)completion;

// Re-reads the options in the background (throttled); the results show up in the
// properties above.
- (void)refreshOptionsIfStale;

// Stream end: later answers and requests of this session are dropped. The host keeps its scale.
- (void)endSession;

@end
