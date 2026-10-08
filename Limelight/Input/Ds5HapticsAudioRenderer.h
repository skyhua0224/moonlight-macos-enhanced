// GPL application adapter: this interface depends on the common-c frame type.
// The Core Audio API underneath does not remove that integration dependency.
#import <Foundation/Foundation.h>

#include "Limelight.h"

NS_ASSUME_NONNULL_BEGIN

/// Sends Foundation's authored DualSense PCM to the controller's native
/// four-channel Core Audio output endpoint when macOS exposes one.
///
/// Game Controller's public haptics API remains the fallback. This class does
/// not claim success unless a real DualSense endpoint was found and the frame
/// was accepted by its AudioQueue.
@interface Ds5HapticsAudioRenderer : NSObject

+ (BOOL)hasPhysicalEndpoint;
- (BOOL)submitPCMFrame:(const LI_DS5_HAPTICS_PCM_FRAME *)frame;
- (void)reset;

@end

NS_ASSUME_NONNULL_END
