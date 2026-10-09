//
//  MLAdaptiveBitrateController.h
//  Moonlight for macOS
//

#import <Foundation/Foundation.h>

@class HttpManager;

// Client side of Foundation Sunshine's /api/abr protocol. The host owns the
// decisions: this object enables ABR for the running session, reports network
// feedback about once per second and logs what the host answers.
@interface MLAdaptiveBitrateController : NSObject

// ceilingKbps (0 = none) is the pre-stream probe result; it bounds how far the
// host may raise the bitrate above the configured value.
- (instancetype)initWithHttpManager:(HttpManager *)httpManager
                 initialBitrateKbps:(int)initialBitrateKbps
                        ceilingKbps:(int)ceilingKbps;

- (void)start;
- (void)stop;

// Thread safe. packetLossPercent is the share of frames lost to the network in
// the latest measurement window; droppedFrames counts frames dropped in it.
- (void)updatePacketLossPercent:(double)packetLossPercent
                          rttMs:(double)rttMs
                      decodeFps:(double)decodeFps
                  droppedFrames:(int)droppedFrames;

@end
