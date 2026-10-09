//
//  TemporaryApp.h
//  Moonlight
//
//  Created by Cameron Gutman on 9/30/15.
//  Copyright © 2015 Moonlight Stream. All rights reserved.
//

#import "TemporaryHost.h"
#import "App+CoreDataClass.h"

// A host-defined menu command advertised in /applist (SuperCmds) and run via /supercmd.
@interface MLAppSuperCommand : NSObject

@property (nonatomic, copy) NSString *commandId;
@property (nonatomic, copy) NSString *name;

@end

@interface TemporaryApp : NSObject

@property (nullable, nonatomic, retain) NSString *id;
@property (nullable, nonatomic, retain) NSString *name;
@property (nullable, nonatomic, retain) NSString *installPath;
@property (nonatomic)                   BOOL hdrSupported;
@property (nonatomic)                   BOOL hidden;
@property (nonatomic)                   BOOL pinned;
@property (nullable, nonatomic, retain) TemporaryHost *host;
// Session-only: refreshed from every /applist response, never persisted.
@property (nonatomic, copy) NSArray<MLAppSuperCommand *> *superCommands;

NS_ASSUME_NONNULL_BEGIN

- (id) initFromApp:(App*)app withTempHost:(TemporaryHost*)tempHost;

- (NSComparisonResult)compareName:(TemporaryApp *)other;
- (NSComparisonResult)compare:(TemporaryApp *)other;

- (void) propagateChangesToParent:(App*)parent withHost:(Host*)host;

NS_ASSUME_NONNULL_END

@end
