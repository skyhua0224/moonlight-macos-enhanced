//
//  BackgroundColorView.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 19/6/2024.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface BackgroundColorView : NSView
@property (nonatomic, strong) NSString *backgroundColorName;
@property (nonatomic) BOOL clear;
@end

NS_ASSUME_NONNULL_END
