//
//  RendererLayerContainer.m
//  Moonlight
//
//  Created by Michael Kenny on 28/6/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "RendererLayerContainer.h"

@implementation RendererLayerContainer

+ (Class)layerClass {
    return [AVSampleBufferDisplayLayer class];
}

@end
