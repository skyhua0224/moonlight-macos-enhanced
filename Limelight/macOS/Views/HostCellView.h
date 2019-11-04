//
//  HostCellView.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 4/11/19.
//  Copyright © 2019 Moonlight Game Streaming Project. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@interface HostCellView : NSView
@property (nonatomic, weak) id<NSMenuDelegate> delegate;

@end
