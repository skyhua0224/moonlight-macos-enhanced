//
//  HostsViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 22/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "HostsViewController.h"
#import "HostCell.h"

@interface HostsViewController () <NSCollectionViewDataSource, NSCollectionViewDelegate>
@property (weak) IBOutlet NSCollectionView *collectionView;
@property (nonatomic, strong) NSMutableArray<NSString *> *hosts;
@end

@implementation HostsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    
    self.hosts = [NSMutableArray array];
    [self.hosts addObject:@"Michael"];
    [self.hosts addObject:@"Marty"];
}

- (nonnull NSCollectionViewItem *)collectionView:(nonnull NSCollectionView *)collectionView itemForRepresentedObjectAtIndexPath:(nonnull NSIndexPath *)indexPath {
    HostCell *item = [collectionView makeItemWithIdentifier:@"HostCell" forIndexPath:indexPath];
    item.hostName.stringValue = self.hosts[indexPath.item];
    
    return item;
}

- (NSInteger)collectionView:(nonnull NSCollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.hosts.count;
}

@end
