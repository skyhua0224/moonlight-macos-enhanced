//
//  AppAssetResponse.h
//  Moonlight
//
//  Created by Diego Waxemberg on 2/1/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "HttpResponse.h"

@interface AppAssetResponse : NSObject <Response, HttpHeaderReceiver>

/// The HTTP status of the answer (200, 304, 404 ...), 0 when none arrived.
@property (nonatomic) NSInteger httpStatus;
@property (nonatomic, copy) NSDictionary *httpHeaders;
- (NSString *) headerValue:(NSString *)name;

@end
