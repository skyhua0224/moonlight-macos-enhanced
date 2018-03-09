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

- (void)viewDidLoad {
    [super viewDidLoad];
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* currentSettings = [dataMan getSettings];
    
    // Bitrate is persisted in kbps
    _bitrate = [currentSettings.bitrate integerValue];

    NSInteger framerate;
    switch (currentSettings.framerate.integerValue) {
        case 30:
            framerate = 0;
            break;
        case 60:
            framerate = 1;
            break;

        default:
            framerate = 2;
            break;
    }
    
    NSInteger resolution;
    switch ([currentSettings.height integerValue]) {
        case 720:
            resolution = 0;
            break;
        case 1080:
            resolution = 1;
            break;
        case 1440:
            resolution = 2;
            break;
        case 2160:
            resolution = 3;
            break;

        default:
            resolution = 0;
            break;
    }

    NSInteger onscreenControls = [currentSettings.onscreenControls integerValue];
    
    [self.resolutionSelector setSelectedSegmentIndex:resolution];
    [self.resolutionSelector addTarget:self action:@selector(newResolutionFpsChosen) forControlEvents:UIControlEventValueChanged];
    [self.framerateSelector setSelectedSegmentIndex:framerate];
    [self.framerateSelector addTarget:self action:@selector(newResolutionFpsChosen) forControlEvents:UIControlEventValueChanged];
    [self.onscreenControlSelector setSelectedSegmentIndex:onscreenControls];


    numbers = @[@(0.5), @(1), @(1.5), @(2), @(2.5), @(3), @(3.5), @(4), @(4.5), @(5), @(5.5), @(6)];
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
    NSInteger resWidth = [self getChosenStreamWidth];
    NSInteger defaultBitrate;
    
    // 2160p@60 is 60 Mbps
    if (frameRate >= 59 && resHeight == 2160) {
        defaultBitrate = 60000;
    }
    // 2560x1080p@60 is 40 Mbps
    else if ((frameRate >= 59 && resWidth == 2560) || resHeight == 2160) {
        defaultBitrate = 40000;
    }
    // 1440p@60 is 30 Mbps
    else if ((frameRate >= 59 && resHeight == 1440) || resWidth == 2560) {
        defaultBitrate = 30000;
    }
    // 1080p@60 is 20 Mbps
    else if ((frameRate >= 59 && resHeight == 1080) || resHeight == 1440) {
        defaultBitrate = 20000;
    }
    // 720p@60 is 10 Mbps
    else if (frameRate >= 59 || resHeight == 1080) {
        defaultBitrate = 10000;
    }
    // 720p@30 is 5 Mbps
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
    switch (self.framerateSelector.selectedSegmentIndex) {
        case 0:
            return 30;
            break;
        case 1:
            if ([UIScreen mainScreen].maximumFramesPerSecond > 60) {
                return 60;
            } else {
                return 59;
            }
            break;

        default:
            return 60;
            break;
    }
}

- (NSInteger) getChosenStreamHeight {
    switch (self.resolutionSelector.selectedSegmentIndex) {
        case 0:
            return 720;
            break;
        case 1:
            return 1080;
            break;
        case 2:
            return 1080;
            break;
        case 3:
            return 2160;
            break;

        default:
            return 720;
            break;
    }
}

- (NSInteger) getChosenStreamWidth {
    switch (self.resolutionSelector.selectedSegmentIndex) {
        case 0:
            return 1280;
            break;
        case 1:
            return 1920;
            break;
        case 2:
            return 2560;
            break;
        case 3:
            return 3840;
            break;
            
        default:
            return 1280;
            break;
    }
}

- (void) saveSettings {
    DataManager* dataMan = [[DataManager alloc] init];
    NSInteger framerate = [self getChosenFrameRate];
    NSInteger height = [self getChosenStreamHeight];
    NSInteger width = [self getChosenStreamWidth];
    NSInteger onscreenControls = [self.onscreenControlSelector selectedSegmentIndex];
    [dataMan saveSettingsWithBitrate:_bitrate framerate:framerate height:height width:width onscreenControls:onscreenControls];
    [[NSUserDefaults standardUserDefaults] setBool:self.optimizeGameSettingsSelector.selectedSegmentIndex != 0 forKey:@"optimizeSettings"];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


#pragma mark - Navigation

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
}


@end
