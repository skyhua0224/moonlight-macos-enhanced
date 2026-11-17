//
//  DiscoveryWorker.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/2/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "TemporaryHost.h"

@interface DiscoveryWorker : NSOperation

@property(nonatomic, copy) void (^onlineHandler)(TemporaryHost *host);
/// A one-off round on a host record that is not (yet) the one the app keeps, e.g. the record mDNS builds from a plain-HTTP
/// answer: it fills in that record but writes nothing to the database and calls no handler. Otherwise its Unpaired
/// (no pinned certificate, so HTTP only) overwrote the stored Paired state of the real record: a Windows host
/// showed 未配对 from 08:57:29 until the real worker's next round at 08:57:54.
@property(nonatomic) BOOL probeOnly;

/// YES for a caller that reads the answer right after -discoverHost (an mDNS result that has no uuid yet, the running-app
/// state of an open host): -discoverHost then returns only once the round has been committed into the host record
/// (uuid, name, pair state, current game), not as soon as the first address answered. The worker loop leaves it NO:
/// it wants the early online publication, and nothing reads the record straight after.
@property(nonatomic) BOOL waitsForCommit;

- (id) initWithHost:(TemporaryHost*)host uniqueId:(NSString*)uniqueId;
- (void) discoverHost;
- (TemporaryHost*) getHost;

@end
