//
//  HttpResponse.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/30/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

static NSString* TAG_STATUS_CODE = @"status_code";
static NSString* TAG_STATUS_MESSAGE = @"status_message";

@protocol Response <NSObject>

- (void) populateWithData:(NSData*)data;

@property (nonatomic) NSInteger statusCode;
@property (nonatomic) NSString* statusMessage;
@property (nonatomic) NSData* data;

@end

/// A response that wants the HTTP status and headers of the answer (the app-asset cache validators: ETag, Last-Modified, 304).
@protocol HttpHeaderReceiver <NSObject>
- (void) receivedHTTPStatus:(NSInteger)status headers:(NSDictionary *)headers;
@end

@interface HttpResponse : NSObject <Response>

/// YES when this answer came over HTTPS with our client certificate. A plain-HTTP answer (the fallback after a failed
/// or too slow HTTPS request) cannot say whether we are paired: Sunshine answers PairStatus=0 to anyone without a
/// client certificate. Only a TLS answer may change the pair state.
@property (nonatomic) BOOL receivedOverClientTLS;

- (void) populateWithData:(NSData*)data;
- (void) parseData;
- (NSString*) getStringTag:(NSString*)tag;
- (BOOL) getIntTag:(NSString *)tag value:(NSInteger*)value;
- (BOOL) isStatusOk;

@end
