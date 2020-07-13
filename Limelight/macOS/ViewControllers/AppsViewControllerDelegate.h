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

- (void)quitApp:(TemporaryApp *)app completion:(void (^)(BOOL success))completion;

- (void)appDidQuit:(TemporaryApp *)app;

- (void)didOpenContextMenu:(NSMenu *)menu forApp:(TemporaryApp *)app;

- (void)didHover:(BOOL)hovered forApp:(TemporaryApp *)app;

@end
