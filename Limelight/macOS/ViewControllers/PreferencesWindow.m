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
@property (weak) IBOutlet NSButton *optimizeSettingsCheckbox;

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
    [self.resolutionSelector selectItemWithTag:[streamSettings.height intValue]];
    self.bitrateSlider.integerValue = [streamSettings.bitrate intValue];
    [self updateBitrateLabel];
    self.optimizeSettingsCheckbox.state = [[NSUserDefaults standardUserDefaults] boolForKey:@"optimizeSettings"] ? NSOnState : NSOffState;
}


#pragma mark - Helpers

- (void)updateBitrateLabel {
    NSInteger bitrate = self.bitrateSlider.integerValue / 1000;
    self.bitrateLabel.stringValue = [NSString stringWithFormat:@"%@ Mbps", @(bitrate)];
}

- (void)saveSettings {
    DataManager* dataMan = [[DataManager alloc] init];
    NSInteger resolutionHeight = self.resolutionSelector.selectedTag;
    NSInteger resolutionWidth = resolutionHeight * 16 / 9;
    [dataMan saveSettingsWithBitrate:self.bitrateSlider.integerValue framerate:self.framerateSelector.selectedTag height:resolutionHeight width:resolutionWidth onscreenControls:0];
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

- (IBAction)didToggleOptimizeSettings:(id)sender {
    [[NSUserDefaults standardUserDefaults] setBool:self.optimizeSettingsCheckbox.state == NSOnState forKey:@"optimizeSettings"];
}


@end
