#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MLRemoteUSBForwardingState) {
    MLRemoteUSBForwardingStateIdle = 0,
    MLRemoteUSBForwardingStateEnumerating,
    MLRemoteUSBForwardingStateStartingHelper,
    MLRemoteUSBForwardingStateReady,
    MLRemoteUSBForwardingStateForwarding,
    MLRemoteUSBForwardingStateStopping,
    MLRemoteUSBForwardingStateFailed,
};

/// A device reported by the platform USB/IP exporter. The bus ID is a topology
/// address and the identity fields are used to reject a replacement device on
/// the same port.
@interface MLRemoteUSBDevice : NSObject <NSSecureCoding>
@property(nonatomic, copy, readonly) NSString *busID;
@property(nonatomic, copy, readonly) NSString *vidPID;
@property(nonatomic, copy, readonly) NSString *serial;
@property(nonatomic, copy, readonly) NSString *manufacturer;
@property(nonatomic, copy, readonly) NSString *product;
@property(nonatomic, readonly, getter=isClaimable) BOOL claimable;
@property(nonatomic, readonly) BOOL isHub;

- (instancetype)initWithDictionary:(NSDictionary *)dictionary;
- (BOOL)matchesIdentityOfDevice:(MLRemoteUSBDevice *)device;
@end

/// Owns the short-lived local USB/IP exporter process. The exporter is kept
/// platform-specific and communicates through a bounded line protocol:
/// `list --json` returns one JSON array; `serve` emits exactly one READY line.
/// The TLS reverse tunnel is intentionally a separate phase so helper failure
/// cannot be confused with a remote attach failure.
@interface MLRemoteUSBForwardingSession : NSObject

+ (instancetype)sharedSession;

@property(nonatomic, readonly) MLRemoteUSBForwardingState state;
@property(nonatomic, copy, readonly) NSArray<MLRemoteUSBDevice *> *devices;
@property(nonatomic, copy, readonly, nullable) NSError *error;
@property(nonatomic, readonly) uint16_t localPort;

- (void)refreshDevicesWithCompletion:(void (^)(NSArray<MLRemoteUSBDevice *> *devices,
                                                NSError * _Nullable error))completion;
- (void)startExporterForDevice:(MLRemoteUSBDevice *)device
                    completion:(void (^)(uint16_t localPort,
                                         NSError * _Nullable error))completion;
- (void)startForwardingForDevice:(MLRemoteUSBDevice *)device
                            host:(NSString *)host
                            port:(uint16_t)port
                           token:(NSString *)token
                      serverCert:(NSData *)serverCert
                       completion:(void (^)(NSError * _Nullable error))completion;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
