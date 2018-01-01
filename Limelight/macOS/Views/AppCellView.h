//
//  AppCellView.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 30/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@interface AppCellView : NSView
@property (nonatomic, weak) id<NSMenuDelegate> delegate;

@end
