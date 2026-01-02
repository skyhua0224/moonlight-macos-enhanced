//
//  StreamConfiguration.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface StreamConfiguration : NSObject

@property(nonatomic, copy) NSString *host;
@property(nonatomic, copy) NSString *appVersion;
@property(nonatomic, copy) NSString *gfeVersion;
@property(nonatomic, copy) NSString *appID;
@property(nonatomic, copy) NSString *appName;
@property(nonatomic) int width;
@property(nonatomic) int height;
@property(nonatomic) int frameRate;
@property(nonatomic) int bitRate;
@property(nonatomic) int riKeyId;
@property(nonatomic) BOOL streamingRemotely;
@property(nonatomic, copy) NSData *riKey;
@property(nonatomic) int gamepadMask;
@property(nonatomic) BOOL optimizeGameSettings;
@property(nonatomic) BOOL playAudioOnPC;
@property(nonatomic) int audioConfiguration;
@property(nonatomic) BOOL enableHdr;
@property(nonatomic) BOOL enableVsync;
@property(nonatomic) BOOL showPerformanceOverlay;
@property(nonatomic) BOOL multiController;
@property(nonatomic) BOOL allowHevc;
@property(nonatomic, copy) NSData *serverCert;
@property(nonatomic) int serverCodecModeSupport;
@property(nonatomic, copy) NSString *sessionUrl;

@end
