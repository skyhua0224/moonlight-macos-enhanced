//
//  AppsViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 23/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "AppsViewController.h"
#import "TemporaryApp.h"
#import "AppsViewControllerDelegate.h"
#import "AppCell.h"

@interface AppsViewController () <NSCollectionViewDataSource, AppsViewControllerDelegate>
@property (weak) IBOutlet NSCollectionView *collectionView;
@property (nonatomic, strong) NSArray<TemporaryApp *> *apps;

@end

@implementation AppsViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.collectionView.dataSource = self;

    TemporaryApp *app = [[TemporaryApp alloc] init];
    app.name = @"Steam";
    self.apps = [NSArray arrayWithObject:app];
}


#pragma mark - NSCollectionViewDataSource

- (nonnull NSCollectionViewItem *)collectionView:(nonnull NSCollectionView *)collectionView itemForRepresentedObjectAtIndexPath:(nonnull NSIndexPath *)indexPath {
    AppCell *item = [collectionView makeItemWithIdentifier:@"AppCell" forIndexPath:indexPath];

    TemporaryApp *app = self.apps[indexPath.item];
    item.appName.stringValue = app.name;
    item.app = app;
    item.delegate = self;

    return item;
}

- (NSInteger)collectionView:(nonnull NSCollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.apps.count;
}

#pragma mark - AppsViewControllerDelegate

- (void)openApp:(TemporaryApp *)app {
}

@end
