//
//  RendererLayerContainer.m
//  Moonlight
//
//  Created by Michael Kenny on 28/6/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "RendererLayerContainer.h"

@implementation RendererLayerContainer

#if TARGET_OS_IPHONE

+ (Class)layerClass {
    return [AVSampleBufferDisplayLayer class];
}

#else

- (instancetype)init {
    self = [super init];
    if (self) {
        CALayer *layer = [AVSampleBufferDisplayLayer layer];
        self.layer = layer;
        [self setWantsLayer:YES];
    }
    return self;
}

#endif

@end
