#import "RemoteUSBReverseTunnel.h"

#import "../Crypto/CryptoManager.h"
#import "../Utility/Logger.h"

#import <Security/Security.h>

static NSString * const MLRemoteUSBErrorDomain = @"com.skyhua.moonlight.remote-usb";
static const NSUInteger kMLRemoteUSBHandshakeLimit = 4096;
static const NSUInteger kMLRemoteUSBChunkSize = 64 * 1024;
static const NSUInteger kMLRemoteUSBOutputHighWaterMark = 4 * 1024 * 1024;

static NSError *MLRemoteUSBTunnelError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:MLRemoteUSBErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: message ?: @"Remote USB tunnel error"}];
}

static BOOL MLRemoteUSBStringMatches(NSString *value, NSString *pattern) {
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
    return value.length > 0 && [expression firstMatchInString:value options:0 range:NSMakeRange(0, value.length)] != nil;
}

@interface MLRemoteUSBReverseTunnel ()
@property(nonatomic, readwrite) MLRemoteUSBReverseTunnelState state;
@property(nonatomic, copy, readwrite, nullable) NSError *error;
@property(nonatomic, copy) void (^completion)(NSError * _Nullable error);
@property(nonatomic, strong, nullable) NSURLSession *session;
@property(nonatomic, strong, nullable) NSURLSessionStreamTask *remoteTask;
@property(nonatomic, strong, nullable) NSInputStream *localInput;
@property(nonatomic, strong, nullable) NSOutputStream *localOutput;
@property(nonatomic, strong) NSData *serverCert;
@property(nonatomic) SecIdentityRef clientIdentity;
@property(nonatomic, strong) NSMutableData *handshakeBuffer;
@property(nonatomic, strong) NSMutableData *localOutputBuffer;
@property(nonatomic, strong) NSMutableArray<NSData *> *remoteWriteQueue;
@property(nonatomic) BOOL remoteWriteInFlight;
@property(nonatomic) BOOL secureConnectionStarted;
@end

@implementation MLRemoteUSBReverseTunnel

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = MLRemoteUSBReverseTunnelStateIdle;
        _handshakeBuffer = [NSMutableData data];
        _localOutputBuffer = [NSMutableData data];
        _remoteWriteQueue = [NSMutableArray array];
    }
    return self;
}

- (void)startWithHost:(NSString *)host
                 port:(uint16_t)port
                token:(NSString *)token
                busID:(NSString *)busID
            localPort:(uint16_t)localPort
          serverCert:(NSData *)serverCert
           completion:(void (^)(NSError * _Nullable))completion {
    if (self.state != MLRemoteUSBReverseTunnelStateIdle && self.state != MLRemoteUSBReverseTunnelStateFailed) {
        completion(MLRemoteUSBTunnelError(1, @"Remote USB tunnel is already active"));
        return;
    }
    if (host.length == 0 || port == 0 || localPort == 0 || serverCert.length == 0 ||
        !MLRemoteUSBStringMatches(token, @"\\A[0-9a-fA-F]{64}\\z") ||
        !MLRemoteUSBStringMatches(busID, @"\\A[0-9A-Za-z.-]{1,31}\\z")) {
        completion(MLRemoteUSBTunnelError(2, @"Invalid Remote USB tunnel configuration"));
        return;
    }

    self.state = MLRemoteUSBReverseTunnelStateConnecting;
    self.error = nil;
    self.completion = completion;
    self.serverCert = serverCert;
    [self.handshakeBuffer setLength:0];
    [self.localOutputBuffer setLength:0];
    [self.remoteWriteQueue removeAllObjects];
    self.remoteWriteInFlight = NO;

    NSData *p12 = [CryptoManager readP12FromFile];
    self.clientIdentity = [self copyIdentityFromP12:p12];
    if (self.clientIdentity == NULL) {
        [self fail:MLRemoteUSBTunnelError(3, @"The paired client certificate is unavailable")];
        return;
    }

    CFReadStreamRef readStream = NULL;
    CFWriteStreamRef writeStream = NULL;
    CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault,
                                       (__bridge CFStringRef)@"127.0.0.1",
                                       localPort,
                                       &readStream,
                                       &writeStream);
    if (readStream == NULL || writeStream == NULL) {
        if (readStream) CFRelease(readStream);
        if (writeStream) CFRelease(writeStream);
        [self fail:MLRemoteUSBTunnelError(4, @"Unable to create the local USB/IP socket")];
        return;
    }
    self.localInput = (__bridge_transfer NSInputStream *)readStream;
    self.localOutput = (__bridge_transfer NSOutputStream *)writeStream;
    self.localInput.delegate = self;
    self.localOutput.delegate = self;
    [self.localInput scheduleInRunLoop:NSRunLoop.mainRunLoop forMode:NSDefaultRunLoopMode];
    [self.localOutput scheduleInRunLoop:NSRunLoop.mainRunLoop forMode:NSDefaultRunLoopMode];
    [self.localInput open];
    [self.localOutput open];

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
    delegateQueue.maxConcurrentOperationCount = 1;
    self.session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:delegateQueue];
    self.remoteTask = [self.session streamTaskWithHostName:host port:port];
    [self.remoteTask resume];
    self.state = MLRemoteUSBReverseTunnelStateHandshaking;
    self.secureConnectionStarted = YES;
    [self.remoteTask startSecureConnection];

    NSString *handshake = [NSString stringWithFormat:@"{\"op\":\"forward\",\"token\":\"%@\",\"busid\":\"%@\"}\n",
                           token, busID];
    [self.remoteTask writeData:[handshake dataUsingEncoding:NSUTF8StringEncoding]
                       timeout:12.0
             completionHandler:^(NSError * _Nullable error) {
        if (error) [self fail:error];
    }];
    [self readRemoteHandshake];
}

- (SecIdentityRef)copyIdentityFromP12:(NSData *)p12 {
    if (p12.length == 0) return NULL;
    const void *keys[] = { kSecImportExportPassphrase };
    const void *values[] = { CFSTR("limelight") };
    CFDictionaryRef options = CFDictionaryCreate(kCFAllocatorDefault,
                                                  keys,
                                                  values,
                                                  1,
                                                  &kCFTypeDictionaryKeyCallBacks,
                                                  &kCFTypeDictionaryValueCallBacks);
    CFArrayRef items = NULL;
    OSStatus status = SecPKCS12Import((__bridge CFDataRef)p12, options, &items);
    CFRelease(options);
    if (status != errSecSuccess || items == NULL) {
        if (items) CFRelease(items);
        return NULL;
    }
    SecIdentityRef identity = NULL;
    for (CFIndex index = 0; index < CFArrayGetCount(items); index++) {
        CFDictionaryRef item = CFArrayGetValueAtIndex(items, index);
        SecIdentityRef candidate = (SecIdentityRef)CFDictionaryGetValue(item, kSecImportItemIdentity);
        if (candidate != NULL) {
            identity = (SecIdentityRef)CFRetain(candidate);
            break;
        }
    }
    CFRelease(items);
    return identity;
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition,
                              NSURLCredential * _Nullable credential))completionHandler {
    NSString *method = challenge.protectionSpace.authenticationMethod;
    if ([method isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        SecTrustRef trust = challenge.protectionSpace.serverTrust;
        SecCertificateRef certificate = trust ? SecTrustGetCertificateAtIndex(trust, 0) : NULL;
        NSData *actual = certificate ? CFBridgingRelease(SecCertificateCopyData(certificate)) : nil;
        if (actual.length > 0 && [actual isEqualToData:self.serverCert]) {
            completionHandler(NSURLSessionAuthChallengeUseCredential,
                              [NSURLCredential credentialForTrust:trust]);
        } else {
            completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
        }
        return;
    }
    if ([method isEqualToString:NSURLAuthenticationMethodClientCertificate] && self.clientIdentity != NULL) {
        SecCertificateRef certificate = NULL;
        SecIdentityCopyCertificate(self.clientIdentity, &certificate);
        NSArray *certificates = certificate ? @[(__bridge id)certificate] : @[];
        NSURLCredential *credential = [NSURLCredential credentialWithIdentity:self.clientIdentity
                                                                  certificates:certificates
                                                                   persistence:NSURLCredentialPersistenceForSession];
        if (certificate) CFRelease(certificate);
        completionHandler(NSURLSessionAuthChallengeUseCredential, credential);
        return;
    }
    completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
}

- (void)readRemoteHandshake {
    [self.remoteTask readDataOfMinLength:1 maxLength:kMLRemoteUSBHandshakeLimit timeout:12.0 completionHandler:^(NSData *data, BOOL atEOF, NSError *error) {
        if (error || atEOF || data.length == 0) {
            [self fail:error ?: MLRemoteUSBTunnelError(5, @"Remote USB tunnel closed before ready")];
            return;
        }
        [self.handshakeBuffer appendData:data];
        const uint8_t *bytes = self.handshakeBuffer.bytes;
        const uint8_t *newline = memchr(bytes, '\n', self.handshakeBuffer.length);
        if (newline == NULL && self.handshakeBuffer.length < kMLRemoteUSBHandshakeLimit) {
            [self readRemoteHandshake];
            return;
        }
        if (newline == NULL) {
            [self fail:MLRemoteUSBTunnelError(6, @"Remote USB handshake exceeded its limit")];
            return;
        }
        NSUInteger lineLength = (NSUInteger)(newline - bytes);
        NSData *lineData = [self.handshakeBuffer subdataWithRange:NSMakeRange(0, lineLength)];
        NSData *remainder = [self.handshakeBuffer subdataWithRange:NSMakeRange(lineLength + 1, self.handshakeBuffer.length - lineLength - 1)];
        self.handshakeBuffer = [NSMutableData dataWithData:remainder];
        NSDictionary *object = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:NULL];
        if (![object isKindOfClass:NSDictionary.class] || ![object[@"op"] isEqual:@"ready"]) {
            NSString *reason = [object[@"reason"] isKindOfClass:NSString.class] ? object[@"reason"] : @"Remote USB attach was rejected";
            [self fail:MLRemoteUSBTunnelError(7, reason)];
            return;
        }
        self.state = MLRemoteUSBReverseTunnelStateForwarding;
        if (self.handshakeBuffer.length > 0) [self writeLocalData:self.handshakeBuffer.copy];
        [self.handshakeBuffer setLength:0];
        [self pumpRemoteData];
    }];
}

- (void)pumpRemoteData {
    if (self.state != MLRemoteUSBReverseTunnelStateForwarding) return;
    [self.remoteTask readDataOfMinLength:1 maxLength:kMLRemoteUSBChunkSize timeout:0 completionHandler:^(NSData *data, BOOL atEOF, NSError *error) {
        if (error || atEOF || data.length == 0) {
            [self fail:error ?: MLRemoteUSBTunnelError(8, @"Remote USB tunnel disconnected")];
            return;
        }
        [self writeLocalData:data];
        [self pumpRemoteData];
    }];
}

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)eventCode {
    if (eventCode == NSStreamEventHasBytesAvailable && stream == self.localInput && self.state == MLRemoteUSBReverseTunnelStateForwarding) {
        uint8_t buffer[kMLRemoteUSBChunkSize];
        NSInteger count = [self.localInput read:buffer maxLength:sizeof(buffer)];
        if (count > 0) {
            [self.remoteTask writeData:[NSData dataWithBytes:buffer length:(NSUInteger)count]
                               timeout:0
                     completionHandler:^(NSError * _Nullable error) {
                if (error) [self fail:error];
            }];
        } else if (count < 0) {
            [self fail:self.localInput.streamError ?: MLRemoteUSBTunnelError(9, @"Local USB/IP exporter disconnected")];
        }
    } else if (eventCode == NSStreamEventHasSpaceAvailable && stream == self.localOutput) {
        [self flushLocalOutput];
    } else if (eventCode == NSStreamEventEndEncountered || eventCode == NSStreamEventErrorOccurred) {
        [self fail:stream.streamError ?: MLRemoteUSBTunnelError(10, @"Local USB/IP exporter closed")];
    }
}

- (void)writeLocalData:(NSData *)data {
    if (data.length == 0) return;
    if (self.localOutputBuffer.length + data.length > kMLRemoteUSBOutputHighWaterMark) {
        [self fail:MLRemoteUSBTunnelError(11, @"Remote USB output backpressure limit exceeded")];
        return;
    }
    [self.localOutputBuffer appendData:data];
    [self flushLocalOutput];
}

- (void)flushLocalOutput {
    while (self.localOutputBuffer.length > 0 && self.localOutput.hasSpaceAvailable) {
        NSInteger count = [self.localOutput write:self.localOutputBuffer.bytes maxLength:self.localOutputBuffer.length];
        if (count <= 0) break;
        [self.localOutputBuffer replaceBytesInRange:NSMakeRange(0, (NSUInteger)count) withBytes:NULL length:0];
    }
}

- (void)fail:(NSError *)error {
    if (self.state == MLRemoteUSBReverseTunnelStateFailed || self.state == MLRemoteUSBReverseTunnelStateIdle) return;
    self.state = MLRemoteUSBReverseTunnelStateFailed;
    self.error = error;
    void (^completion)(NSError *) = self.completion;
    self.completion = nil;
    [self stop];
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
}

- (void)stop {
    if (self.state == MLRemoteUSBReverseTunnelStateIdle) return;
    BOOL preserveFailure = self.state == MLRemoteUSBReverseTunnelStateFailed;
    self.state = MLRemoteUSBReverseTunnelStateStopping;
    [self.localInput close];
    [self.localOutput close];
    [self.localInput removeFromRunLoop:NSRunLoop.mainRunLoop forMode:NSDefaultRunLoopMode];
    [self.localOutput removeFromRunLoop:NSRunLoop.mainRunLoop forMode:NSDefaultRunLoopMode];
    [self.remoteTask cancel];
    [self.session invalidateAndCancel];
    self.remoteTask = nil;
    self.session = nil;
    self.localInput = nil;
    self.localOutput = nil;
    if (self.clientIdentity != NULL) {
        CFRelease(self.clientIdentity);
        self.clientIdentity = NULL;
    }
    self.state = preserveFailure ? MLRemoteUSBReverseTunnelStateFailed : MLRemoteUSBReverseTunnelStateIdle;
}

- (void)dealloc {
    [self stop];
}

@end
