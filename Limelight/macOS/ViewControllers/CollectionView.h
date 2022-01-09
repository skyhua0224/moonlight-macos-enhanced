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
@property (nonatomic) BOOL shouldAllowNavigation;
@end

NS_ASSUME_NONNULL_END
