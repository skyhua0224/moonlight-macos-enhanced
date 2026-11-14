//
//  ConnectionHelper.h
//  Moonlight macOS
//
//  Created by Felix Kratz on 22.03.18.
//  Copyright © 2018 Felix Kratz. All rights reserved.
//

#import "AppListResponse.h"
#import "TemporaryHost.h"

#ifndef ConnectionHelper_h
#define ConnectionHelper_h


@interface ConnectionHelper : NSObject

+(AppListResponse*) getAppListForHostWithHostIP:(NSString*) hostIP serverCert:(NSData*) serverCert uniqueID:(NSString*) uniqueId;
+(AppListResponse*) getAppListForHostWithHostIP:(NSString*) hostIP serverCert:(NSData*) serverCert uniqueID:(NSString*) uniqueId tries:(int)tries;

/// The app list of a host: the address in use with the host's real port first, then the endpoints discovery has answered on, then
/// the rest; the first that answers wins. (A client asked 192.0.2.133:47984 ten times while the host listens on
/// 57984, and never got an app list: no FsArt, no hero art, no new covers.)
+(AppListResponse*) getAppListForHost:(TemporaryHost*)host uniqueID:(NSString*)uniqueId;

@end

#endif /* ConnectionHelper_h */
