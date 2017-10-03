//
//  SettingsViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 10/27/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "SettingsViewController.h"
#import "TemporarySettings.h"
#import "DataManager.h"

#define BITRATE_INTERVAL 5000 // in kbps

@implementation SettingsViewController {
    NSInteger _bitrate;
    NSArray *numbers;
    Boolean _adjustedForSafeArea;
}
static NSString* bitrateFormat = @"Bitrate: %d Mbps";

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
    // Adjust the subviews for the safe area on the iPhone X.
    if (!_adjustedForSafeArea) {
        if (@available(iOS 11.0, *)) {
            for (UIView* view in self.view.subviews) {
                // HACK: The official safe area is much too large for our purposes
                // so we'll just use the presence of any safe area to indicate we should
                // pad by 20.
                if (self.view.safeAreaInsets.left >= 20 || self.view.safeAreaInsets.right >= 20) {
                    view.frame = CGRectMake(view.frame.origin.x + 20, view.frame.origin.y, view.frame.size.width, view.frame.size.height);
                }
            }
        }

        _adjustedForSafeArea = true;
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* currentSettings = [dataMan getSettings];
    
    // Bitrate is persisted in kbps
    _bitrate = [currentSettings.bitrate integerValue];
    NSInteger framerate = [currentSettings.framerate integerValue] == 30 ? 0 : 1;
    NSInteger resolution;
    if ([currentSettings.height integerValue] == 720) {
        resolution = 0;
    } else if ([currentSettings.height integerValue] == 1080) {
        resolution = 1;
    } else if ([currentSettings.height integerValue] == 1440) {
        resolution = 2;
    } else {
        resolution = 3;
    }
    NSInteger onscreenControls = [currentSettings.onscreenControls integerValue];
    
    [self.resolutionSelector setSelectedSegmentIndex:resolution];
    [self.resolutionSelector addTarget:self action:@selector(newResolutionFpsChosen) forControlEvents:UIControlEventValueChanged];
    [self.framerateSelector setSelectedSegmentIndex:framerate];
    [self.framerateSelector addTarget:self action:@selector(newResolutionFpsChosen) forControlEvents:UIControlEventValueChanged];
    [self.onscreenControlSelector setSelectedSegmentIndex:onscreenControls];


    numbers = @[@(0.5), @(1), @(1.5), @(2), @(2.5), @(3), @(3.5), @(4), @(4.5), @(5), @(5.5), @(6), @(6.5), @(7), @(7.5), @(8), @(8.5), @(9), @(9.5), @(10)];
    NSInteger numberOfSteps = ((float)[numbers count]);
    self.bitrateSlider.maximumValue = numberOfSteps;
    self.bitrateSlider.minimumValue = 1;
    
    self.bitrateSlider.continuous = YES;

    [self.bitrateSlider setValue:(_bitrate / BITRATE_INTERVAL) animated:YES];
    [self.bitrateSlider addTarget:self action:@selector(bitrateSliderMoved) forControlEvents:UIControlEventValueChanged];
    [self updateBitrateText];
}

- (void) newResolutionFpsChosen {
    NSInteger frameRate = [self getChosenFrameRate];
    NSInteger resHeight = [self getChosenStreamHeight];
    NSInteger defaultBitrate;
    
    // 2160p60 is 40 Mbps
    if (frameRate == 60 && resHeight == 2160) {
        defaultBitrate = 40000;
    }
    // 1440p60 is 30 Mbps
    else if ((frameRate == 60 && resHeight == 1440) || resHeight == 2160) {
        defaultBitrate = 30000;
    }
    // 1080p60 is 20 Mbps
    else if ((frameRate == 60 && resHeight == 1080) || resHeight == 1440) {
        defaultBitrate = 20000;
    }
    // 720p60 and 1080p30 are 10 Mbps
    else if (frameRate == 60 || resHeight == 1080) {
        defaultBitrate = 10000;
    }
    // 720p30 is 5 Mbps
    else {
        defaultBitrate = 5000;
    }
    
    _bitrate = defaultBitrate;
    [self.bitrateSlider setValue:defaultBitrate / BITRATE_INTERVAL animated:YES];
    
    [self updateBitrateText];
}

- (void) bitrateSliderMoved {
    NSUInteger index = (NSUInteger)(self.bitrateSlider.value);
    [self.bitrateSlider setValue:index animated:NO];
    
    _bitrate = BITRATE_INTERVAL * (int)self.bitrateSlider.value;
    [self updateBitrateText];
}

- (void) updateBitrateText {
    // Display bitrate in Mbps
    [self.bitrateLabel setText:[NSString stringWithFormat:bitrateFormat, _bitrate / 1000]];
}

- (NSInteger) getChosenFrameRate {
    return [self.framerateSelector selectedSegmentIndex] == 0 ? 30 : 60;
}

- (NSInteger) getChosenStreamHeight {
    NSInteger selectedSegment = [self.resolutionSelector selectedSegmentIndex];
    if (selectedSegment == 0) {
        return 720;
    } else if (selectedSegment == 1) {
        return 1080;
    } else if (selectedSegment == 2) {
        return 1440;
    } else {
        return 2160;
    }
}

- (NSInteger) getChosenStreamWidth {
    NSInteger selectedSegmentHeight = [self getChosenStreamHeight];
    if (selectedSegmentHeight == 720) {
        return 1280;
    } else if (selectedSegmentHeight == 1080) {
        return 1920;
    } else if (selectedSegmentHeight == 1440) {
        return 2560;
    } else {
        return 3840;
    }
}

- (void) saveSettings {
    DataManager* dataMan = [[DataManager alloc] init];
    NSInteger framerate = [self getChosenFrameRate];
    NSInteger height = [self getChosenStreamHeight];
    NSInteger width = [self getChosenStreamWidth];
    NSInteger onscreenControls = [self.onscreenControlSelector selectedSegmentIndex];
    [dataMan saveSettingsWithBitrate:_bitrate framerate:framerate height:height width:width onscreenControls:onscreenControls];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


#pragma mark - Navigation

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
}


@end
