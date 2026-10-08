//
//  HapticContext.h
//  Moonlight
//
//  Created by Cameron Gutman on 9/17/20.
//  Copyright © 2020 Moonlight Game Streaming Project. All rights reserved.
//

@import CoreHaptics;
@import GameController;

@interface HapticContext : NSObject

-(void)setMotorAmplitude:(unsigned short)amplitude;
-(void)cleanup;
- (BOOL)setIntensity:(float)intensity sharpness:(float)sharpness;
@property(nonatomic, readonly) BOOL available;

+(HapticContext*) createContextForHighFreqMotor:(GCController*)gamepad;
+(HapticContext*) createContextForLowFreqMotor:(GCController*)gamepad;
#if TARGET_OS_IPHONE
+(HapticContext*) createContext;
#endif

@end
