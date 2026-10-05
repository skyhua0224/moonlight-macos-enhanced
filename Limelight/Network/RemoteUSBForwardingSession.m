#import "RemoteUSBForwardingSession.h"
#import "RemoteUSBReverseTunnel.h"

#import "../Utility/Logger.h"

static NSString * const MLRemoteUSBErrorDomain = @"com.skyhua.moonlight.remote-usb";
static const NSUInteger kMLRemoteUSBMaxLineBytes = 4096;
static const NSTimeInterval kMLRemoteUSBStartupTimeout = 12.0;

static NSError *MLRemoteUSBError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:MLRemoteUSBErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: message ?: @"Remote USB error"}];
}

@interface MLRemoteUSBDevice ()
@property(nonatomic, copy, readwrite) NSString *busID;
@property(nonatomic, copy, readwrite) NSString *vidPID;
@property(nonatomic, copy, readwrite) NSString *serial;
@property(nonatomic, copy, readwrite) NSString *manufacturer;
@property(nonatomic, copy, readwrite) NSString *product;
@property(nonatomic, readwrite, getter=isClaimable) BOOL claimable;
@property(nonatomic, readwrite) BOOL isHub;
@end

@implementation MLRemoteUSBDevice

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithDictionary:(NSDictionary *)dictionary {
    self = [super init];
    if (self) {
        _busID = [dictionary[@"busId"] isKindOfClass:NSString.class] ? dictionary[@"busId"] : @"";
        _vidPID = [dictionary[@"vidPid"] isKindOfClass:NSString.class] ? dictionary[@"vidPid"] : @"";
        _serial = [dictionary[@"serial"] isKindOfClass:NSString.class] ? dictionary[@"serial"] : @"";
        _manufacturer = [dictionary[@"manufacturer"] isKindOfClass:NSString.class] ? dictionary[@"manufacturer"] : @"";
        _product = [dictionary[@"product"] isKindOfClass:NSString.class] ? dictionary[@"product"] : @"";
        _claimable = [dictionary[@"claimable"] boolValue];
        _isHub = [dictionary[@"isHub"] boolValue] || [dictionary[@"deviceClass"] integerValue] == 9;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _busID = [coder decodeObjectOfClass:NSString.class forKey:@"busID"] ?: @"";
        _vidPID = [coder decodeObjectOfClass:NSString.class forKey:@"vidPID"] ?: @"";
        _serial = [coder decodeObjectOfClass:NSString.class forKey:@"serial"] ?: @"";
        _manufacturer = [coder decodeObjectOfClass:NSString.class forKey:@"manufacturer"] ?: @"";
        _product = [coder decodeObjectOfClass:NSString.class forKey:@"product"] ?: @"";
        _claimable = [coder decodeBoolForKey:@"claimable"];
        _isHub = [coder decodeBoolForKey:@"isHub"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.busID forKey:@"busID"];
    [coder encodeObject:self.vidPID forKey:@"vidPID"];
    [coder encodeObject:self.serial forKey:@"serial"];
    [coder encodeObject:self.manufacturer forKey:@"manufacturer"];
    [coder encodeObject:self.product forKey:@"product"];
    [coder encodeBool:self.claimable forKey:@"claimable"];
    [coder encodeBool:self.isHub forKey:@"isHub"];
}

- (BOOL)matchesIdentityOfDevice:(MLRemoteUSBDevice *)device {
    if (device == nil || self.vidPID.length == 0 || device.vidPID.length == 0 ||
        [self.vidPID caseInsensitiveCompare:device.vidPID] != NSOrderedSame) {
        return NO;
    }
    // A missing serial is not a stable identity. Keep the conservative result
    // so a port replacement cannot silently inherit an active forwarding slot.
    if (self.serial.length == 0 || device.serial.length == 0) {
        return [self.vidPID caseInsensitiveCompare:device.vidPID] == NSOrderedSame;
    }
    return [self.serial isEqualToString:device.serial];
}

@end

@interface MLRemoteUSBForwardingSession ()
@property(nonatomic, readwrite) MLRemoteUSBForwardingState state;
@property(nonatomic, copy, readwrite) NSArray<MLRemoteUSBDevice *> *devices;
@property(nonatomic, copy, readwrite, nullable) NSError *error;
@property(nonatomic, readwrite) uint16_t localPort;
@property(nonatomic, strong, nullable) NSTask *exporter;
@property(nonatomic, strong, nullable) NSPipe *exporterInput;
@property(nonatomic, strong, nullable) MLRemoteUSBReverseTunnel *tunnel;
@property(nonatomic) dispatch_queue_t workerQueue;
@end

@implementation MLRemoteUSBForwardingSession

+ (instancetype)sharedSession {
    static MLRemoteUSBForwardingSession *session;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        session = [[MLRemoteUSBForwardingSession alloc] init];
    });
    return session;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = MLRemoteUSBForwardingStateIdle;
        _devices = @[];
        _workerQueue = dispatch_queue_create("com.skyhua.moonlight.remote-usb", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (NSString *)helperPath {
    NSString *override = NSProcessInfo.processInfo.environment[@"MOONLIGHT_USB_HELPER"];
    if (override.length > 0) {
        return override;
    }
    NSString *bundlePath = [[NSBundle mainBundle] pathForAuxiliaryExecutable:@"moonlight-usbd"];
    return bundlePath ?: @"";
}

- (void)refreshDevicesWithCompletion:(void (^)(NSArray<MLRemoteUSBDevice *> *, NSError *))completion {
    dispatch_async(self.workerQueue, ^{
        self.state = MLRemoteUSBForwardingStateEnumerating;
        self.error = nil;

        NSString *helperPath = [self helperPath];
        if (helperPath.length == 0 || ![[NSFileManager defaultManager] isExecutableFileAtPath:helperPath]) {
            NSError *error = MLRemoteUSBError(1, @"The macOS USB/IP exporter is not installed");
            self.state = MLRemoteUSBForwardingStateFailed;
            self.error = error;
            dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], error); });
            return;
        }

        NSTask *task = [[NSTask alloc] init];
        NSPipe *stdoutPipe = [NSPipe pipe];
        task.executableURL = [NSURL fileURLWithPath:helperPath];
        task.arguments = @[@"list", @"--json"];
        task.standardOutput = stdoutPipe;
        task.standardError = [NSPipe pipe];
        NSError *launchError = nil;
        if (![task launchAndReturnError:&launchError]) {
            self.state = MLRemoteUSBForwardingStateFailed;
            self.error = launchError ?: MLRemoteUSBError(2, @"Unable to start the macOS USB/IP exporter");
            NSError *error = self.error;
            dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], error); });
            return;
        }

        NSData *data = [stdoutPipe.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];
        if (data.length > kMLRemoteUSBMaxLineBytes * 128 || task.terminationStatus != 0) {
            NSError *error = MLRemoteUSBError(3, @"The USB/IP exporter returned an invalid device list");
            self.state = MLRemoteUSBForwardingStateFailed;
            self.error = error;
            dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], error); });
            return;
        }

        NSError *jsonError = nil;
        id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (![object isKindOfClass:NSArray.class]) {
            NSError *error = jsonError ?: MLRemoteUSBError(4, @"The USB/IP exporter returned malformed JSON");
            self.state = MLRemoteUSBForwardingStateFailed;
            self.error = error;
            dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], error); });
            return;
        }

        NSMutableArray *devices = [NSMutableArray array];
        for (NSDictionary *entry in (NSArray *)object) {
            if (![entry isKindOfClass:NSDictionary.class]) continue;
            MLRemoteUSBDevice *device = [[MLRemoteUSBDevice alloc] initWithDictionary:entry];
            if (device.busID.length > 0 && !device.isHub) [devices addObject:device];
        }
        self.devices = devices.copy;
        self.state = MLRemoteUSBForwardingStateIdle;
        NSArray *result = self.devices;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result, nil); });
    });
}

- (void)startExporterForDevice:(MLRemoteUSBDevice *)device
                    completion:(void (^)(uint16_t, NSError *))completion {
    if (device == nil || device.busID.length == 0 || !device.claimable) {
        NSError *error = MLRemoteUSBError(5, @"The selected USB device cannot be claimed by macOS");
        completion(0, error);
        return;
    }

    dispatch_async(self.workerQueue, ^{
        [self stopExporterLocked];
        self.state = MLRemoteUSBForwardingStateStartingHelper;
        self.error = nil;
        NSString *helperPath = [self helperPath];
        if (helperPath.length == 0) {
            NSError *error = MLRemoteUSBError(6, @"The macOS USB/IP exporter is not installed");
            self.state = MLRemoteUSBForwardingStateFailed;
            self.error = error;
            dispatch_async(dispatch_get_main_queue(), ^{ completion(0, error); });
            return;
        }

        NSTask *task = [[NSTask alloc] init];
        NSPipe *input = [NSPipe pipe];
        NSPipe *output = [NSPipe pipe];
        task.executableURL = [NSURL fileURLWithPath:helperPath];
        task.arguments = @[@"serve", @"--bind", device.busID, @"--listen", @"127.0.0.1:0"];
        task.standardInput = input;
        task.standardOutput = output;
        task.standardError = [NSPipe pipe];
        NSError *launchError = nil;
        if (![task launchAndReturnError:&launchError]) {
            self.state = MLRemoteUSBForwardingStateFailed;
            self.error = launchError ?: MLRemoteUSBError(7, @"Unable to start the USB/IP exporter");
            NSError *error = self.error;
            dispatch_async(dispatch_get_main_queue(), ^{ completion(0, error); });
            return;
        }

        self.exporter = task;
        self.exporterInput = input;
        NSData *lineData = [self readLineFromHandle:output.fileHandleForReading timeout:kMLRemoteUSBStartupTimeout];
        NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
        NSRegularExpression *ready = [NSRegularExpression regularExpressionWithPattern:@"\\AREADY ([1-9][0-9]{0,4})\\z" options:0 error:NULL];
        NSTextCheckingResult *match = [ready firstMatchInString:line ?: @"" options:0 range:NSMakeRange(0, line.length)];
        NSInteger port = match ? [[[line substringWithRange:[match rangeAtIndex:1]] description] integerValue] : 0;
        if (port <= 0 || port > UINT16_MAX) {
            [self stopExporterLocked];
            NSError *error = MLRemoteUSBError(8, line.length > 0 ? line : @"The USB/IP exporter did not become ready");
            self.state = MLRemoteUSBForwardingStateFailed;
            self.error = error;
            dispatch_async(dispatch_get_main_queue(), ^{ completion(0, error); });
            return;
        }

        self.localPort = (uint16_t)port;
        self.state = MLRemoteUSBForwardingStateReady;
        uint16_t resultPort = self.localPort;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(resultPort, nil); });
    });
}

- (NSData *)readLineFromHandle:(NSFileHandle *)handle timeout:(NSTimeInterval)timeout {
    NSMutableData *data = [NSMutableData data];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (data.length <= kMLRemoteUSBMaxLineBytes && [deadline timeIntervalSinceNow] > 0) {
        NSData *chunk = [handle availableData];
        if (chunk.length == 0) break;
        [data appendData:chunk];
        const uint8_t *bytes = data.bytes;
        const uint8_t *newline = memchr(bytes, '\n', data.length);
        if (newline != NULL) {
            NSUInteger length = (NSUInteger)(newline - bytes);
            return [data subdataWithRange:NSMakeRange(0, length)];
        }
    }
    return data;
}

- (void)stopExporterLocked {
    NSTask *task = self.exporter;
    self.exporter = nil;
    self.exporterInput = nil;
    self.localPort = 0;
    if (task == nil) return;
    if (task.running) [task terminate];
    [task waitUntilExit];
}

- (void)startForwardingForDevice:(MLRemoteUSBDevice *)device
                            host:(NSString *)host
                            port:(uint16_t)port
                           token:(NSString *)token
                      serverCert:(NSData *)serverCert
                       completion:(void (^)(NSError * _Nullable))completion {
    [self startExporterForDevice:device completion:^(uint16_t localPort, NSError * _Nullable error) {
        if (error != nil) {
            completion(error);
            return;
        }
        dispatch_async(self.workerQueue, ^{
            MLRemoteUSBReverseTunnel *tunnel = [[MLRemoteUSBReverseTunnel alloc] init];
            self.tunnel = tunnel;
            self.state = MLRemoteUSBForwardingStateForwarding;
            [tunnel startWithHost:host
                             port:port
                            token:token
                            busID:device.busID
                        localPort:localPort
                      serverCert:serverCert
                       completion:^(NSError * _Nullable tunnelError) {
                if (tunnelError != nil) {
                    self.error = tunnelError;
                    self.state = MLRemoteUSBForwardingStateFailed;
                }
                completion(tunnelError);
            }];
        });
    }];
}

- (void)stop {
    dispatch_sync(self.workerQueue, ^{
        self.state = MLRemoteUSBForwardingStateStopping;
        [self.tunnel stop];
        self.tunnel = nil;
        [self stopExporterLocked];
        self.state = MLRemoteUSBForwardingStateIdle;
    });
}

- (void)dealloc {
    [self stop];
}

@end
