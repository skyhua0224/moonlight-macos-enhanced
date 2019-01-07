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

@interface PreferencesWindow ()

@property (weak) IBOutlet NSPopUpButton *framerateSelector;
@property (weak) IBOutlet NSPopUpButton *resolutionSelector;
@property (weak) IBOutlet NSSlider *bitrateSlider;
@property (weak) IBOutlet NSTextField *bitrateLabel;
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
    
    [self standardWindowButton:NSWindowZoomButton].enabled = NO;
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];
    
    [self.framerateSelector selectItemWithTag:[streamSettings.framerate intValue]];
    if ([streamSettings.height intValue] == 1080 && [streamSettings.width intValue] == 2560) {
        [self.resolutionSelector selectItemWithTag:219];
    } else {
        [self.resolutionSelector selectItemWithTag:[streamSettings.height intValue]];
    }
    self.bitrateSlider.integerValue = [streamSettings.bitrate intValue];
    [self updateBitrateLabel];
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
    if (self.resolutionSelector.selectedTag == 219) {
        resolutionHeight = 1080;
        resolutionWidth = 2560;
    } else {
        resolutionHeight = self.resolutionSelector.selectedTag;
        resolutionWidth = resolutionHeight * 16 / 9;
    }
    [dataMan saveSettingsWithBitrate:self.bitrateSlider.integerValue framerate:self.framerateSelector.selectedTag height:resolutionHeight width:resolutionWidth onscreenControls:0 remote:0];
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
