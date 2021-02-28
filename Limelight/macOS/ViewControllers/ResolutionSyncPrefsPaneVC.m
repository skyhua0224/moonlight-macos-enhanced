//
//  ResolutionSyncPrefsPaneVC.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 25/2/21.
//  Copyright © 2021 Moonlight Game Streaming Project. All rights reserved.
//

#import "ResolutionSyncPrefsPaneVC.h"

#import "MASPreferences.h"

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

@interface ResolutionSyncPrefsPaneVC () <MASPreferencesViewController>
@property (nonatomic, strong) NSUserDefaults *standard;
@property (nonatomic, strong) NSControl *enableResolutionControl;
@property (weak) IBOutlet NSStackView *enableResolutionSyncStackView;
@property (weak) IBOutlet NSGridView *gridView;
@property (weak) IBOutlet NSButton *shouldSyncCustomResolutionCheckbox;
@property (weak) IBOutlet NSTextField *widthLabel;
@property (weak) IBOutlet NSTextField *heightLabel;
@property (weak) IBOutlet NSTextField *customResWidthTextField;
@property (weak) IBOutlet NSTextField *customResHeightTextField;
@property (weak) IBOutlet NSSlider *pointerSpeedSlider;
@property (weak) IBOutlet NSTextField *pointerSpeedLabel;
@property (weak) IBOutlet NSButton *disablePointerPrecisionCheckbox;
@property (weak) IBOutlet NSTextField *scrollWheelLinesTextField;
@property (weak) IBOutlet NSPopUpButton *mouseScrollMethodSelector;
@property (weak) IBOutlet NSPopUpButton *controllerMethodSelector;
@end

@implementation ResolutionSyncPrefsPaneVC

- (id)init {
    return [super initWithNibName:@"ResolutionSyncPrefsPaneView" bundle:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    [self setPreferredContentSize:NSMakeSize(self.view.bounds.size.width, self.view.bounds.size.height)];

    self.standard = [NSUserDefaults standardUserDefaults];

    [self createEnableResolutionControl];

    self.shouldSyncCustomResolutionCheckbox.state = [self.standard boolForKey:@"shouldSync"];
    [self updateShouldSyncCheckboxRelatedControlStates];
    self.customResWidthTextField.stringValue = [self.standard safeStringForKey:@"syncWidth"];
    self.customResHeightTextField.stringValue = [self.standard safeStringForKey:@"syncHeight"];
    self.pointerSpeedSlider.integerValue = [self.standard integerForKey:@"pointerSpeed"] / 2;
    [self updatePointerSpeedLabel];
    self.disablePointerPrecisionCheckbox.state = [self.standard boolForKey:@"disablePointerPrecision"];
    self.scrollWheelLinesTextField.integerValue = [self.standard integerForKey:@"scrollWheelLines"];
    [self.mouseScrollMethodSelector selectItemWithTag:[self.standard integerForKey:@"mouseScrollMethod"]];
    [self.controllerMethodSelector selectItemWithTag:[self.standard integerForKey:@"controllerMethod"]];

}

#pragma mark - Helpers

- (void)createEnableResolutionControl {
    self.enableResolutionSyncStackView.userInterfaceLayoutDirection = NSUserInterfaceLayoutDirectionRightToLeft;
    NSControl *enableResolutionControl;
    NSControlStateValue state = [self.standard boolForKey:@"enableResolutionSync"] ? NSControlStateValueOn : NSControlStateValueOff;
    [self setAllSettingControlStatesToReflectResolutionSyncState:state];
    NSString *enableResolutionSyncString = @"Enable Resolution Sync";
    
    if (@available(macOS 10.15, *)) {
        enableResolutionControl = [[NSSwitch alloc] init];
        ((NSSwitch *)enableResolutionControl).state = state;
        
        NSTextField *enableResolutionSyncLabel = [[NSTextField alloc] init];
        enableResolutionSyncLabel.stringValue = enableResolutionSyncString;
        enableResolutionSyncLabel.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
        enableResolutionSyncLabel.alignment = NSTextAlignmentCenter;
        [enableResolutionSyncLabel sizeToFit];
        enableResolutionSyncLabel.bezeled = NO;
        enableResolutionSyncLabel.editable = NO;
        enableResolutionSyncLabel.drawsBackground = NO;
        
        [self.enableResolutionSyncStackView addView:enableResolutionSyncLabel inGravity:NSStackViewGravityLeading];
    } else {
        enableResolutionControl = [[NSButton alloc] init];
        [((NSButton *)enableResolutionControl) setButtonType:NSButtonTypeSwitch];
        [((NSButton *)enableResolutionControl) setTitle:enableResolutionSyncString];
        ((NSButton *)enableResolutionControl).state = state;
    }
    
    enableResolutionControl.target = self;
    enableResolutionControl.action = @selector(didChangeEnableResolutionSync:);
    [self.enableResolutionSyncStackView addView:enableResolutionControl inGravity:NSStackViewGravityLeading];
    
    self.enableResolutionControl = enableResolutionControl;
}

- (void)updateShouldSyncCheckboxRelatedControlStates {
    self.widthLabel.textColor = self.shouldSyncCustomResolutionCheckbox.state == NSControlStateValueOn ? NSColor.labelColor : NSColor.secondaryLabelColor;
    self.heightLabel.textColor = self.shouldSyncCustomResolutionCheckbox.state == NSControlStateValueOn ? NSColor.labelColor : NSColor.secondaryLabelColor;
    if ([self.standard boolForKey:@"enableResolutionSync"]) {
        self.customResWidthTextField.enabled = self.shouldSyncCustomResolutionCheckbox.state == NSControlStateValueOn;
        self.customResHeightTextField.enabled = self.shouldSyncCustomResolutionCheckbox.state == NSControlStateValueOn;
    }
}

- (void)updatePointerSpeedLabel {
    self.pointerSpeedLabel.integerValue = self.pointerSpeedSlider.integerValue;
}

- (void)performOnDescendants:(NSView *)view withBlock:(BOOL (^ _Nonnull)(NSView *))block {
    if (block(view)) {
        for (NSView *v in view.subviews) {
            [self performOnDescendants:v withBlock:block];
        }
    }
}


#pragma mark - Actions

- (void)setAllSettingControlStatesToReflectResolutionSyncState:(NSControlStateValue)state {
    for (int i = 0; i < self.gridView.numberOfRows; i++) {
        NSGridRow *row = [self.gridView rowAtIndex:i];
        for (int j = 0; j < 2; j++) {
            NSGridCell *cell = [row cellAtIndex:j];
            [self performOnDescendants:cell.contentView withBlock:^(NSView *view) {
                if ([view isKindOfClass:NSTextField.class]) {
                    ((NSTextField *)view).textColor = state == NSControlStateValueOn ? NSColor.labelColor : NSColor.secondaryLabelColor;
                    if (view == self.customResWidthTextField || view == self.customResHeightTextField) {
                        if (self.shouldSyncCustomResolutionCheckbox.state == NSControlStateValueOn) {
                            ((NSTextField *)view).enabled = state == NSControlStateValueOn;
                        }
                    }
                    return NO;
                } else if ([view respondsToSelector:@selector(setEnabled:)]) {
                    ((NSControl *)view).enabled = state == NSControlStateValueOn;
                    return NO;
                }
                
                return YES;
            }];
        }
    }
}

- (IBAction)didChangeEnableResolutionSync:(id)sender {
    NSControlStateValue state;
    if (@available(macOS 10.15, *)) {
        state = ((NSSwitch *)sender).state;
    } else {
        state = ((NSButton *)sender).state;
    }
    [self setAllSettingControlStatesToReflectResolutionSyncState:state];
    
    [self.standard setBool:state == NSControlStateValueOn forKey:@"enableResolutionSync"];
}

- (IBAction)didChangeShouldSyncCustomResolution:(id)sender {
    [self updateShouldSyncCheckboxRelatedControlStates];
    [self.standard setBool:self.shouldSyncCustomResolutionCheckbox.state == NSControlStateValueOn forKey:@"shouldSync"];
}

- (IBAction)didChangeCustomResWidth:(id)sender {
    [self.standard setInteger:self.customResWidthTextField.integerValue forKey:@"syncWidth"];
}

- (IBAction)didChangeCustomResHeight:(id)sender {
    [self.standard setInteger:self.customResHeightTextField.integerValue forKey:@"syncHeight"];
}

- (IBAction)didChangePointerSpeed:(id)sender {
    [self updatePointerSpeedLabel];
    [self.standard setInteger:self.pointerSpeedSlider.integerValue * 2 forKey:@"pointerSpeed"];
}

- (IBAction)didChangeDisablePointerPrecision:(id)sender {
    [self.standard setBool:self.disablePointerPrecisionCheckbox.state == NSControlStateValueOn forKey:@"disablePointerPrecision"];
}

- (IBAction)didChangeNumberOfLinesToScroll:(id)sender {
    [self.standard setInteger:self.scrollWheelLinesTextField.integerValue forKey:@"scrollWheelLines"];
}

- (IBAction)didChangeMouseScrollMethod:(id)sender {
    [self.standard setInteger:self.mouseScrollMethodSelector.selectedTag forKey:@"mouseScrollMethod"];
}

- (IBAction)didChangeControllerMethod:(id)sender {
    [self.standard setInteger:self.controllerMethodSelector.selectedTag forKey:@"controllerMethod"];
}


#pragma mark - MASPreferencesViewController

- (NSString *)viewIdentifier {
    return @"resolutionSyncPrefs";
}

- (NSImage *)toolbarItemImage {
    if (@available(macOS 11.0, *)) {
        return [NSImage imageWithSystemSymbolName:@"network" accessibilityDescription:nil];
    } else {
        return [NSImage imageNamed:NSImageNameNetwork];
    }
}

- (NSString *)toolbarItemLabel {
    return @"Resolution Sync";
}

- (NSView *)initialKeyView {
    return self.enableResolutionControl;
}

@end
