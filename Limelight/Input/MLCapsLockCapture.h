#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The stream creates and uses this capture on the main thread.
@interface MLCapsLockCapture : NSObject

- (instancetype)initWithOwnsInput:(BOOL (^)(void))ownsInput
                         sendEdge:(void (^)(BOOL down))sendEdge NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) BOOL hasKeyboards;

- (BOOL)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
