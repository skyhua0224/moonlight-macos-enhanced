//
//  ShadowView.h
//  Moonlight
//
//  Created by Michael Kenny on 10/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface ShadowView : UIView
@property (nonatomic) float shadowOpacity;
@property (nonatomic) CGFloat shadowRadius;
@property (nonatomic) CGSize shadowOffset;
@property (nonatomic) CGFloat shadowCornerRadius;

- (void)updateShadow;

@end
