//
//  NSCollectionView+Moonlight.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 9/2/18.
//  Copyright © 2018 Moonlight Stream. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@interface NSCollectionView (Moonlight)

- (void)moonlight_reloadDataKeepingSelection;

@end
