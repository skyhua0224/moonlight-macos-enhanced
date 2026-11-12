//
//  AppAssetResponse.m
//  Moonlight
//
//  Created by Diego Waxemberg on 2/1/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "AppAssetResponse.h"

@implementation AppAssetResponse
@synthesize data, statusCode, statusMessage;

- (void)populateWithData:(NSData *)imageData {
    self.data = imageData;
    self.statusMessage = @"App asset has no status message";
    self.statusCode = -1;
}
- (void) receivedHTTPStatus:(NSInteger)status headers:(NSDictionary *)headers {
    self.httpStatus = status;
    self.httpHeaders = headers;
}

- (NSString *) headerValue:(NSString *)name {
    for (id key in self.httpHeaders) {
        if ([key isKindOfClass:[NSString class]] && [(NSString *)key caseInsensitiveCompare:name] == NSOrderedSame) {
            id value = self.httpHeaders[key];
            return [value isKindOfClass:[NSString class]] ? value : nil;
        }
    }
    return nil;
}

- (OSImage*) getImage {
    return [[OSImage alloc] initWithData:self.data];
}

@end
