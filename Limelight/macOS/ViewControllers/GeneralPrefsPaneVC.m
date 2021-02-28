//
//  GeneralPrefsPaneVC.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 30/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "GeneralPrefsPaneVC.h"
#import "NSWindow+Moonlight.h"

#import "MASPreferences.h"

#import "DataManager.h"
#import <VideoToolbox/VideoToolbox.h>


static float bitrateSteps[] = {
    0.5,
    1,
    1.5,
    2,
    2.5,
    3,
    4,
    5,
    6,
    7,
    8,
    9,
    10,
    12,
    15,
    18,
    20,
    25,
    30,
    40,
    50,
    60,
    70,
    80,
    90,
    100,
    120,
    150
};

@interface GeneralPrefsPaneVC () <MASPreferencesViewController>
@property (nonatomic, strong) NSUserDefaults *standard;
@property (weak) IBOutlet NSPopUpButton *framerateSelector;
@property (weak) IBOutlet NSPopUpButton *resolutionSelector;
@property (weak) IBOutlet NSSlider *bitrateSlider;
@property (weak) IBOutlet NSTextField *bitrateLabel;
@property (weak) IBOutlet NSPopUpButton *videoCodecSelector;
@property (weak) IBOutlet NSButton *hdrCheckbox;
@property (weak) IBOutlet NSButton *dynamicResolutionCheckbox;
@property (weak) IBOutlet NSButton *optimizeSettingsCheckbox;
@property (weak) IBOutlet NSButton *playAudioOnPCCheckbox;
@property (weak) IBOutlet NSButton *autoFullscreenCheckbox;
@property (weak) IBOutlet NSButton *controllerVibrationCheckbox;
@property (weak) IBOutlet NSPopUpButton *controllerDriverSelector;

@end

@implementation GeneralPrefsPaneVC

#pragma mark - Lifecycle

- (id)init {
    return [super initWithNibName:@"GeneralPrefsPaneView" bundle:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    [self setPreferredContentSize:NSMakeSize(self.view.bounds.size.width, self.view.bounds.size.height)];
    
    self.standard = [NSUserDefaults standardUserDefaults];

    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];
    
    [self.framerateSelector selectItemWithTag:[streamSettings.framerate intValue]];
    [self.resolutionSelector selectItemWithTag:[streamSettings.height intValue]];
    self.bitrateSlider.integerValue = [self getTickMarkFromBitrate:[streamSettings.bitrate intValue]];
    [self updateBitrateLabel];
    [self.videoCodecSelector selectItemWithTag:[self.standard integerForKey:@"videoCodec"]];
    [self getHevcState];
    self.hdrCheckbox.state = streamSettings.enableHdr ? NSControlStateValueOn : NSControlStateValueOff;
    self.dynamicResolutionCheckbox.state = [self.standard boolForKey:@"dynamicResolution"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.optimizeSettingsCheckbox.state = streamSettings.optimizeGames ? NSControlStateValueOn : NSControlStateValueOff;
    self.playAudioOnPCCheckbox.state = streamSettings.playAudioOnPC ? NSControlStateValueOn : NSControlStateValueOff;
    self.autoFullscreenCheckbox.state = [self.standard boolForKey:@"autoFullscreen"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.controllerVibrationCheckbox.state = [self.standard boolForKey:@"rumbleGamepad"] ? NSControlStateValueOn : NSControlStateValueOff;
    [self.controllerDriverSelector selectItemWithTag:[self.standard integerForKey:@"controllerDriver"]];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"enableResolutionSync"]) {
        self.resolutionSelector.enabled = ![self.standard boolForKey:@"shouldSync"];
    } else {
        self.resolutionSelector.enabled = YES;
    }
}


#pragma mark - Helpers

- (NSInteger)getBitrateFromTickMark:(NSInteger)tickmark {
    return bitrateSteps[tickmark] * 1000;
}

- (NSInteger)getTickMarkFromBitrate:(NSInteger)bitrate {
    for (NSInteger i = 0; i < sizeof(bitrateSteps) / sizeof(bitrateSteps[0]); i++) {
        if (bitrate <= bitrateSteps[i] * 1000.0) {
            return i;
        }
    }
    
    return 0;
}

- (void)updateBitrateLabel {
    float bitrate = [self getBitrateFromTickMark:self.bitrateSlider.integerValue] / 1000.0;
    self.bitrateLabel.stringValue = [NSString stringWithFormat:@"%@ Mbps", @(bitrate)];
}

- (BOOL)getHevcState {
    BOOL useHevc;
    switch (self.videoCodecSelector.selectedTag) {
        case 0:
            useHevc = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);
            break;
        case 1:
            useHevc = NO;
            break;
        case 2:
            useHevc = YES;
            break;
        default:
            useHevc = NO;
            break;
    }
    self.hdrCheckbox.enabled = useHevc;
    return useHevc;
}

- (void)saveSettings {
    DataManager* dataMan = [[DataManager alloc] init];
    NSInteger resolutionHeight;
    NSInteger resolutionWidth;
    resolutionHeight = self.resolutionSelector.selectedTag;
    resolutionWidth = resolutionHeight * 16 / 9;
    
    BOOL useHevc = [self getHevcState];

    [dataMan saveSettingsWithBitrate:[self getBitrateFromTickMark:self.bitrateSlider.integerValue] framerate:self.framerateSelector.selectedTag height:resolutionHeight width:resolutionWidth onscreenControls:0 remote:NO optimizeGames:self.optimizeSettingsCheckbox.state == NSControlStateValueOn multiController:NO audioOnPC:self.playAudioOnPCCheckbox.state == NSControlStateValueOn useHevc:useHevc enableHdr:self.hdrCheckbox.state == NSControlStateValueOn btMouseSupport:NO];
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
    [self.standard setInteger:self.videoCodecSelector.selectedTag forKey:@"videoCodec"];
}

- (IBAction)didToggleHDR:(id)sender {
    [self saveSettings];
}

- (IBAction)didToggleDynamicResolution:(id)sender {
    [self.standard setBool:self.dynamicResolutionCheckbox.state == NSControlStateValueOn forKey:@"dynamicResolution"];
}

- (IBAction)didToggleOptimizeSettings:(id)sender {
    [self saveSettings];
}

- (IBAction)didTogglePlayAudioOnPC:(id)sender {
    [self saveSettings];
}

- (IBAction)didToggleAutoFullscreen:(id)sender {
    [self.standard setBool:self.autoFullscreenCheckbox.state == NSControlStateValueOn forKey:@"autoFullscreen"];
}

- (IBAction)didToggleControllerVibration:(id)sender {
    [self.standard setBool:self.controllerVibrationCheckbox.state == NSControlStateValueOn forKey:@"rumbleGamepad"];
}

- (IBAction)didChangeControllerDriver:(id)sender {
    [self.standard setInteger:self.controllerDriverSelector.selectedTag forKey:@"controllerDriver"];
}


#pragma mark - MASPreferencesViewController

- (NSString *)viewIdentifier {
    return @"generalPrefs";
}

- (NSImage *)toolbarItemImage {
    if (@available(macOS 11.0, *)) {
        return [NSImage imageWithSystemSymbolName:@"gearshape" accessibilityDescription:nil];
    } else {
        return [NSImage imageNamed:NSImageNamePreferencesGeneral];
    }
}

- (NSString *)toolbarItemLabel {
    return @"General";
}

- (NSView *)initialKeyView {
    return self.framerateSelector;
}

@end
