//
//  PreferencesViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 30/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "PreferencesViewController.h"
#import "NSWindow+Moonlight.h"

#import "DataManager.h"
#import <VideoToolbox/VideoToolbox.h>


@interface NSUserDefaults (Moonlight)
- (NSString *)safeStringForKey:(NSString *)key;
@end

@implementation NSUserDefaults (Moonlight)
- (NSString *)safeStringForKey:(NSString *)key {
    NSString *value = [self stringForKey:key];
    if (value != nil) {
        return value;
    }
    return @"";
}
@end


@interface PreferencesViewController ()

@property (weak) IBOutlet NSView *preferencesContentView;

@property (weak) IBOutlet NSPopUpButton *framerateSelector;
@property (weak) IBOutlet NSPopUpButton *resolutionSelector;
@property (weak) IBOutlet NSButton *shouldSyncCheckbox;
@property (weak) IBOutlet NSTextField *widthLabel;
@property (weak) IBOutlet NSTextField *heightLabel;
@property (weak) IBOutlet NSTextField *customResWidthTextField;
@property (weak) IBOutlet NSTextField *customResHeightTextField;
@property (weak) IBOutlet NSButtonCell *disablePointerPrecisionCheckbox;
@property (weak) IBOutlet NSSlider *bitrateSlider;
@property (weak) IBOutlet NSTextField *bitrateLabel;
@property (weak) IBOutlet NSPopUpButton *videoCodecSelector;
@property (weak) IBOutlet NSButton *dynamicResolutionCheckbox;
@property (weak) IBOutlet NSButton *optimizeSettingsCheckbox;
@property (weak) IBOutlet NSButton *autoFullscreenCheckbox;
@property (weak) IBOutlet NSPopUpButton *controllerDriverSelector;

@end

@implementation PreferencesViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    [self setPreferredContentSize:NSMakeSize(self.view.bounds.size.width, self.view.bounds.size.height)];
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];
    
    [self.framerateSelector selectItemWithTag:[streamSettings.framerate intValue]];
    [self.resolutionSelector selectItemWithTag:[streamSettings.height intValue]];
    self.shouldSyncCheckbox.state = [[NSUserDefaults standardUserDefaults] boolForKey:@"shouldSync"];
    [self UpdateShoucldSyncCheckboxRelatedControlStates];
    self.customResWidthTextField.stringValue = [[NSUserDefaults standardUserDefaults] safeStringForKey:@"syncWidth"];
    self.customResHeightTextField.stringValue = [[NSUserDefaults standardUserDefaults] safeStringForKey:@"syncHeight"];
    self.disablePointerPrecisionCheckbox.state = [[NSUserDefaults standardUserDefaults] boolForKey:@"disablePointerPrecison"];
    self.bitrateSlider.integerValue = [streamSettings.bitrate intValue];
    [self updateBitrateLabel];
    [self.videoCodecSelector selectItemWithTag:[[NSUserDefaults standardUserDefaults] integerForKey:@"videoCodec"]];
    self.dynamicResolutionCheckbox.state = [[NSUserDefaults standardUserDefaults] boolForKey:@"dynamicResolution"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.optimizeSettingsCheckbox.state = streamSettings.optimizeGames ? NSControlStateValueOn : NSControlStateValueOff;
    self.autoFullscreenCheckbox.state = [[NSUserDefaults standardUserDefaults] boolForKey:@"autoFullscreen"] ? NSControlStateValueOn : NSControlStateValueOff;
    [self.controllerDriverSelector selectItemWithTag:[[NSUserDefaults standardUserDefaults] integerForKey:@"controllerDriver"]];
}


#pragma mark - Helpers

- (void)UpdateShoucldSyncCheckboxRelatedControlStates {
    self.resolutionSelector.enabled = self.shouldSyncCheckbox.state == NSControlStateValueOff;
    self.widthLabel.textColor = self.shouldSyncCheckbox.state == NSControlStateValueOn ? NSColor.labelColor : NSColor.secondaryLabelColor;
    self.heightLabel.textColor = self.shouldSyncCheckbox.state == NSControlStateValueOn ? NSColor.labelColor : NSColor.secondaryLabelColor;
    self.customResWidthTextField.enabled = self.shouldSyncCheckbox.state == NSControlStateValueOn;
    self.customResHeightTextField.enabled = self.shouldSyncCheckbox.state == NSControlStateValueOn;
}

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
    
    [dataMan saveSettingsWithBitrate:self.bitrateSlider.integerValue framerate:self.framerateSelector.selectedTag height:resolutionHeight width:resolutionWidth onscreenControls:0 remote:NO optimizeGames:self.optimizeSettingsCheckbox.state == NSControlStateValueOn multiController:NO audioOnPC:NO useHevc:useHevc enableHdr:NO btMouseSupport:NO];
}


#pragma mark - Actions

- (IBAction)didChangeFramerate:(id)sender {
    [self saveSettings];
}

- (IBAction)didChangeResolution:(id)sender {
    [self saveSettings];
}

- (IBAction)didChangeShouldSync:(id)sender {
    [self UpdateShoucldSyncCheckboxRelatedControlStates];
    [[NSUserDefaults standardUserDefaults] setBool:self.shouldSyncCheckbox.state == NSControlStateValueOn forKey:@"shouldSync"];
}

- (IBAction)didChangeCustomResWidth:(id)sender {
    [[NSUserDefaults standardUserDefaults] setObject:self.customResWidthTextField.stringValue forKey:@"syncWidth"];
}

- (IBAction)didChangeCustomResHeight:(id)sender {
    [[NSUserDefaults standardUserDefaults] setObject:self.customResHeightTextField.stringValue forKey:@"syncHeight"];
}

- (IBAction)didChangeDisablePointerPrecision:(id)sender {
    [[NSUserDefaults standardUserDefaults] setBool:self.disablePointerPrecisionCheckbox.state == NSControlStateValueOn forKey:@"disablePointerPrecison"];
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
    [self saveSettings];
}

- (IBAction)didToggleAutoFullscreen:(id)sender {
    [[NSUserDefaults standardUserDefaults] setBool:self.autoFullscreenCheckbox.state == NSControlStateValueOn forKey:@"autoFullscreen"];
}

- (IBAction)didChangeControllerDriver:(id)sender {
    [[NSUserDefaults standardUserDefaults] setInteger:self.controllerDriverSelector.selectedTag forKey:@"controllerDriver"];
}


@end
