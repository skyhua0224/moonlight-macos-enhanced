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

// Foundation Sunshine remote display scale: applies the configured Windows display scale
// for a stream, lets the control center change it, and puts it back when the stream ends.
// Every host call runs on one background serial queue; completion blocks run on the main
// queue. Nothing here may block or fail a stream.
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

- (instancetype)initWithHostUUID:(NSString *)hostUUID
                     hostAddress:(NSString *)hostAddress
                      serverCert:(NSData *)serverCert;
- (void)updateHostAddress:(NSString *)hostAddress serverCert:(NSData *)serverCert;

// Stream start. Always reads the display's scale options (so the control center knows
// what to offer); changes the scale only when setting is not 0. setting: 0 = don't
// change, -1 = the host's recommended value, otherwise a percentage. targetDisplay is
// the session's target display id (empty = the host default, its primary display).
- (void)beginSessionWithTargetDisplay:(NSString *)targetDisplay
                       desiredSetting:(NSInteger)setting
                   restoreAfterStream:(BOOL)restore
                           completion:(MLRemoteDisplayScaleCompletion)completion;

// Control center: apply a percentage now. Only acts on the session that is live when this is
// called; if the stream ends (or is replaced) before the request reaches the host it is
// dropped and the completion is not called.
- (void)applyPercent:(NSInteger)percent
  restoreAfterStream:(BOOL)restore
          completion:(MLRemoteDisplayScaleCompletion)completion;

// Re-reads the options in the background (throttled); the results show up in the
// properties above.
- (void)refreshOptionsIfStale;

// Stream end: restores the previous scale when restore is YES and this client changed it,
// otherwise forgets the pending restore.
- (void)endSessionRestoring:(BOOL)restore reason:(NSString *)reason;

// A previous run may have died before restoring. Performs that restore, skipping hosts
// that currently have a live session in this process.
+ (void)recoverPendingRestoreForHostUUID:(NSString *)hostUUID
                             hostAddress:(NSString *)hostAddress
                              serverCert:(NSData *)serverCert;

// Same recovery for every host that has a pending record, using the saved host list for the
// certificate and addresses. Meant for app launch, so a scale left behind by a crash is put
// back without waiting for the next stream. Call it off the main thread (it reads the host
// database); the host calls run on the scale queue and an unreachable host keeps its record.
+ (void)recoverAllPendingRestoresAtLaunch;

@end
