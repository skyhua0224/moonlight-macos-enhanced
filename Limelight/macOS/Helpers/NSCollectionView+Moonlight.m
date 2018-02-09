//
//  NSCollectionView+Moonlight.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 9/2/18.
//  Copyright © 2018 Moonlight Stream. All rights reserved.
//

#import "NSCollectionView+Moonlight.h"

@implementation NSCollectionView (Moonlight)

- (void)moonlight_reloadDataKeepingSelection {
    NSSet<NSIndexPath *> *selection = self.selectionIndexPaths;
    [self reloadData];
    [self selectItemsAtIndexPaths:selection scrollPosition:NSCollectionViewScrollPositionNone];
}

@end
