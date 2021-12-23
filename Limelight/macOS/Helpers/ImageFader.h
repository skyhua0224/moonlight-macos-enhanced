//
//  ImageFader.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 25/1/21.
//  Copyright © 2021 Moonlight Game Streaming Project. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ImageFader : NSObject

+ (void)transitionImageViewWithOldImageView:(NSImageView *)oldImageView newImageViewBlock:(NSImageView *(^)(void))newImageViewBlock duration:(NSTimeInterval)duration image:(NSImage *)image completionBlock:(void (^)(NSImageView *newImageView))completion;

@end

NS_ASSUME_NONNULL_END
