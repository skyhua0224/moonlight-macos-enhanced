//
//  StreamView.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#ifdef __OBJC__
#import "ControllerSupport.h"

@protocol EdgeDetectionDelegate <NSObject>

- (void) edgeSwiped;

@end

@interface StreamView : OSView

@property(nonatomic, assign) void *inputStreamContext;

- (void) setupOnScreenControls:(ControllerSupport*)controllerSupport swipeDelegate:(id<EdgeDetectionDelegate>)swipeDelegate;
- (void) setMouseDeltaFactors:(float)x y:(float)y;

@end
#endif
