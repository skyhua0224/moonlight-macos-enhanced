//
//  SettingsViewController.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/27/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface SettingsViewController : UIViewController
@property (strong, nonatomic) IBOutlet UILabel *bitrateLabel;
@property (strong, nonatomic) IBOutlet UISlider *bitrateSlider;
@property (strong, nonatomic) IBOutlet UISegmentedControl *framerateSelector;
@property (strong, nonatomic) IBOutlet UISegmentedControl *resolutionSelector;
@property (strong, nonatomic) IBOutlet UISegmentedControl *onscreenControlSelector;
@property (strong, nonatomic) IBOutlet UIScrollView *scrollView;
@property (weak, nonatomic) IBOutlet UISegmentedControl *optimizeGameSettingsSelector;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *leadingContentViewConstraint;

- (void) saveSettings;

@end
