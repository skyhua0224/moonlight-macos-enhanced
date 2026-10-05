#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MLRemoteUSBReverseTunnelState) {
    MLRemoteUSBReverseTunnelStateIdle = 0,
    MLRemoteUSBReverseTunnelStateConnecting,
    MLRemoteUSBReverseTunnelStateHandshaking,
    MLRemoteUSBReverseTunnelStateForwarding,
    MLRemoteUSBReverseTunnelStateStopping,
    MLRemoteUSBReverseTunnelStateFailed,
};

/// Client initiated mTLS tunnel for one USB/IP exporter instance. The first
/// line is the authenticated JSON handshake; after `ready`, both directions
/// are opaque USB/IP bytes with bounded queues and TCP backpressure.
@interface MLRemoteUSBReverseTunnel : NSObject <NSURLSessionDelegate, NSStreamDelegate>

@property(nonatomic, readonly) MLRemoteUSBReverseTunnelState state;
@property(nonatomic, copy, readonly, nullable) NSError *error;

- (void)startWithHost:(NSString *)host
                 port:(uint16_t)port
                token:(NSString *)token
                busID:(NSString *)busID
            localPort:(uint16_t)localPort
          serverCert:(NSData *)serverCert
           completion:(void (^)(NSError * _Nullable error))completion;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
