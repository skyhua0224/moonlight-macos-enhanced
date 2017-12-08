//
//  AppCollectionViewCell.h
//  Moonlight
//
//  Created by Michael Kenny on 8/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface AppCollectionViewCell : UICollectionViewCell
@property (weak, nonatomic) IBOutlet UIView *shadowView;
@property (weak, nonatomic) IBOutlet UIImageView *imageView;
@property (weak, nonatomic) IBOutlet UILabel *appTitle;

@end
