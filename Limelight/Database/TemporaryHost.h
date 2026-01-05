//
//  TemporaryHost.h
//  Moonlight
//
//  Created by Cameron Gutman on 12/1/15.
//  Copyright © 2015 Moonlight Stream. All rights reserved.
//

#import "Host+CoreDataClass.h"
#import "Utils.h"

NS_ASSUME_NONNULL_BEGIN

@interface TemporaryHost : NSObject

@property(atomic) State state;
@property(atomic) PairState pairState;
@property(atomic, nullable, retain) NSString *activeAddress;
@property(atomic, nullable, retain) NSString *currentGame;

@property(nonatomic) BOOL showHiddenApps;

@property(atomic, nullable, retain) NSData *serverCert;
@property(atomic, nullable, retain) NSString *address;
@property(atomic, nullable, retain) NSString *externalAddress;
@property(atomic, nullable, retain) NSString *localAddress;
@property(atomic, nullable, retain) NSString *ipv6Address;
@property(atomic, nullable, retain) NSString *mac;
@property(atomic) int serverCodecModeSupport;

@property(atomic, retain)
    NSDictionary<NSString *, NSNumber *> *_Nullable addressLatencies;
@property(atomic, retain) NSDictionary<NSString *, NSNumber *>
    *_Nullable addressStates; // 1 = Online, 0 = Offline

@property(atomic, retain) NSString *name;
@property(atomic, retain) NSString *uuid;
@property(atomic, retain) NSSet *appList;

- (instancetype)initFromHost:(Host *)host;

- (NSComparisonResult)compareName:(TemporaryHost *)other;

- (void)propagateChangesToParent:(Host *)host;

@end

NS_ASSUME_NONNULL_END
