//
//  PreferencesWindow.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 30/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "PreferencesWindow.h"
#import "NSWindow+Moonlight.h"

#import "DataManager.h"
#import <VideoToolbox/VideoToolbox.h>

@interface PreferencesWindow ()

@property (weak) IBOutlet NSPopUpButton *framerateSelector;
@property (weak) IBOutlet NSPopUpButton *resolutionSelector;
@property (weak) IBOutlet NSSlider *bitrateSlider;
@property (weak) IBOutlet NSTextField *bitrateLabel;
@property (weak) IBOutlet NSPopUpButton *videoCodecSelector;
@property (weak) IBOutlet NSButton *dynamicResolutionCheckbox;
@property (weak) IBOutlet NSButton *optimizeSettingsCheckbox;
@property (weak) IBOutlet NSButton *autoFullscreenCheckbox;

@end

@implementation PreferencesWindow

#pragma mark - Lifecycle

- (void)awakeFromNib {
    [super awakeFromNib];
    
    self.frameAutosaveName = @"Preferences Window";
    [self moonlight_centerWindowOnFirstRun];
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];
    
    [self.framerateSelector selectItemWithTag:[streamSettings.framerate intValue]];
    [self.resolutionSelector selectItemWithTag:[streamSettings.height intValue]];
    self.bitrateSlider.integerValue = [streamSettings.bitrate intValue];
    [self updateBitrateLabel];
    [self.videoCodecSelector selectItemWithTag:[[NSUserDefaults standardUserDefaults] integerForKey:@"videoCodec"]];
    self.dynamicResolutionCheckbox.state = [[NSUserDefaults standardUserDefaults] boolForKey:@"dynamicResolution"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.optimizeSettingsCheckbox.state = [[NSUserDefaults standardUserDefaults] boolForKey:@"optimizeSettings"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.autoFullscreenCheckbox.state = [[NSUserDefaults standardUserDefaults] boolForKey:@"autoFullscreen"] ? NSControlStateValueOn : NSControlStateValueOff;
}


#pragma mark - Helpers

- (void)updateBitrateLabel {
    NSInteger bitrate = self.bitrateSlider.integerValue / 1000;
    self.bitrateLabel.stringValue = [NSString stringWithFormat:@"%@ Mbps", @(bitrate)];
}

- (void)saveSettings {
    DataManager* dataMan = [[DataManager alloc] init];
    NSInteger resolutionHeight;
    NSInteger resolutionWidth;
    resolutionHeight = self.resolutionSelector.selectedTag;
    resolutionWidth = resolutionHeight * 16 / 9;
    
    BOOL useHevc;
    switch (self.videoCodecSelector.selectedTag) {
    case 1:
        useHevc = NO;
        break;
    case 2:
        useHevc = YES;
        break;
    case 0:
    default:
        useHevc = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);
        break;
    }
    
    [dataMan saveSettingsWithBitrate:self.bitrateSlider.integerValue framerate:self.framerateSelector.selectedTag height:resolutionHeight width:resolutionWidth optimizeGames:NO audioOnPC:NO useHevc:useHevc];
}


#pragma mark - Actions

- (IBAction)didChangeFramerate:(id)sender {
    [self saveSettings];
}

- (IBAction)didChangeResolution:(id)sender {
    [self saveSettings];
}

- (IBAction)didChangeBitrate:(id)sender {
    [self updateBitrateLabel];
    [self saveSettings];
}

- (IBAction)didChangeVideoCodec:(id)sender {
    [self saveSettings];
    [[NSUserDefaults standardUserDefaults] setInteger:self.videoCodecSelector.selectedTag forKey:@"videoCodec"];
}

- (IBAction)didToggleDynamicResolution:(id)sender {
    [[NSUserDefaults standardUserDefaults] setBool:self.dynamicResolutionCheckbox.state == NSControlStateValueOn forKey:@"dynamicResolution"];
}

- (IBAction)didToggleOptimizeSettings:(id)sender {
    [[NSUserDefaults standardUserDefaults] setBool:self.optimizeSettingsCheckbox.state == NSControlStateValueOn forKey:@"optimizeSettings"];
}

- (IBAction)didToggleAutoFullscreen:(id)sender {
    [[NSUserDefaults standardUserDefaults] setBool:self.autoFullscreenCheckbox.state == NSControlStateValueOn forKey:@"autoFullscreen"];
}


@end
