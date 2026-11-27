#import "AwdlHoldLedger.h"

@implementation MLAwdlHoldLedger {
    MLAwdlInterfaceQuery _query;
    MLAwdlInterfaceSetUp _setUp;
    NSMutableSet<NSString *> *_holders;
    BOOL _restorePending;
    BOOL _originalUp;
}

- (instancetype)initWithQuery:(MLAwdlInterfaceQuery)query setUp:(MLAwdlInterfaceSetUp)setUp {
    self = [super init];
    if (self) {
        _query = [query copy];
        _setUp = [setUp copy];
        _holders = [NSMutableSet set];
    }
    return self;
}

- (NSUInteger)holderCount {
    @synchronized (self) {
        return _holders.count;
    }
}

- (BOOL)restorePending {
    @synchronized (self) {
        return _restorePending;
    }
}

- (NSString *)holdForClient:(NSString *)clientID {
    @synchronized (self) {
        MLAwdlInterfaceSnapshot snapshot = _query();
        if (!snapshot.present) {
            return @"The awdl0 interface is not present.";
        }

        if (_holders.count == 0 && !_restorePending) {
            // First hold: only an interface that is up is ours to put down, and to bring back.
            _originalUp = snapshot.up;
            if (snapshot.up) {
                NSString *error = _setUp(NO);
                if (error.length > 0) {
                    return error;
                }
                _restorePending = YES;
            }
        } else if (snapshot.up && _originalUp) {
            // Held already (or waiting for a restore) but the system brought it up again, e.g. after wake.
            NSString *error = _setUp(NO);
            if (error.length > 0) {
                return error;
            }
            _restorePending = YES;
        }

        [_holders addObject:clientID];
        return @"";
    }
}

- (NSString *)releaseForClient:(NSString *)clientID {
    @synchronized (self) {
        [_holders removeObject:clientID];
        if (_holders.count > 0 || !_restorePending) {
            return @"";
        }

        NSString *error = _setUp(YES);
        if (error.length > 0) {
            return error;
        }
        _restorePending = NO;
        return @"";
    }
}

- (void)clientDisconnected:(NSString *)clientID {
    (void)[self releaseForClient:clientID];
}

@end
