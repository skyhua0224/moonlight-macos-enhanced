//
//  AppsViewControllerDelegate.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 24/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TemporaryApp.h"

@protocol AppsViewControllerDelegate <NSObject>

- (void)openApp:(TemporaryApp *)app;

- (void)quitApp:(TemporaryApp *)app;

- (void)appDidClose:(TemporaryApp *)app;

@end
