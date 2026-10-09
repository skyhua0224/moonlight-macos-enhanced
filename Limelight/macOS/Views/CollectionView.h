//
//  CollectionView.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 22/1/19.
//  Copyright © 2019 Moonlight Game Streaming Project. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface CollectionView : NSCollectionView
// Selects the first item when a game controller is connected and nothing is selected.
- (void)selectFirstItemForControllerIfNeeded;
@end

NS_ASSUME_NONNULL_END
