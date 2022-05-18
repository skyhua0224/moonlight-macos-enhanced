//
//  OptimalSettingsConfigurer.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 28/12/2021.
//  Copyright © 2021 Moonlight Game Streaming Project. All rights reserved.
//

#import "OptimalSettingsConfigurer.h"
#import "BackgroundColorView.h"
#import "PrivateGfeApiRequester.h"
#import "F.h"
#import "StreamViewController.h"

@interface OptimalSettingsConfigurer ()
@property (weak) IBOutlet NSTextField *gameTitleLabel;
@property (weak) IBOutlet NSButton *enabledCheckbox;
@property (weak) IBOutlet NSPopUpButton *displayModeSelector;
@property (weak) IBOutlet NSSlider *settingsIndexSlider;
@property (weak) IBOutlet NSGridView *settingsGrid;
@property (weak) IBOutlet NSButton *doneButton;

@property (nonatomic, strong) NSProgressIndicator *spinner;

@property (nonatomic, strong) TemporaryApp *app;
@property (nonatomic, strong) NSString *appId;

@property (nonatomic, strong) NSArray<NSArray<NSDictionary<NSString *, NSString *> *> *> *settings;
@end

@implementation OptimalSettingsConfigurer

- (instancetype)initWithApp:(TemporaryApp *)app andPrivateId:(NSString *)appId {
    self = [super init];
    if (self) {
        self.app = app;
        self.appId = appId;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.preferredContentSize = NSMakeSize(380, 650);

    NSString *enabledKey = [NSString stringWithFormat:@"%@: optimalSettingsEnabled", self.appId];
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        enabledKey: @YES,
    }];
 
    self.gameTitleLabel.stringValue = [NSString stringWithFormat:@"Configure %@ Optimal Settings:", self.app.name];
    self.enabledCheckbox.state = [NSUserDefaults.standardUserDefaults boolForKey:enabledKey];
    
    [PrivateGfeApiRequester requestStateOfApp:self.appId hostIP:self.app.host.activeAddress withCompletionBlock:^(NSDictionary<NSString *,id> *stateJSON) {
        NSArray<NSString *> *displayModes = stateJSON[@"REGULAR"][@"sliderSettingsDC"][@"displayMode"][@"values"];
        displayModes = [displayModes sortedArrayUsingComparator:^NSComparisonResult(NSString *obj1, NSString *obj2) {
            return [obj1 compare:obj2 options:NSCaseInsensitiveSearch];
        }];
        NSDictionary *appSettings = [self.class getSavedOptimalSettingsForApp:self.appId withInitialSettingsIndex:0 andIntialDisplayMode:displayModes.firstObject];

        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray<NSMenuItem *> *allItems = self.displayModeSelector.menu.itemArray;
            [self.displayModeSelector.menu removeAllItems];
            
            for (NSString *displayMode in displayModes) {
                for (NSMenuItem *item in allItems) {
                    if ([item.title isEqualToString:@"Windowed Borderless"] && [displayMode isEqualToString:@"Full-screen Borderless"]) {
                        NSMenuItem *differentWindowBorderDisplayModeItem = [[NSMenuItem alloc] init];
                        differentWindowBorderDisplayModeItem.title = displayMode;
                        [self.displayModeSelector.menu addItem:differentWindowBorderDisplayModeItem];
                    }
                    if ([item.title isEqualToString:displayMode]) {
                        item.state = NSControlStateValueOff;
                        [self.displayModeSelector.menu addItem:item];
                    }
                }
            }
            
            NSString *displayMode = appSettings[@"displayMode"];
            NSMenuItem *itemToSelect;
            for (NSMenuItem *item in self.displayModeSelector.menu.itemArray) {
                if ([item.title isEqualToString:displayMode]) {
                    itemToSelect = item;
                }
            }
            [self.displayModeSelector selectItem:itemToSelect];
        });
        
        [PrivateGfeApiRequester getSettingsJSONForApp:self.appId hostIP:self.app.host.activeAddress resolutionWidth:[StreamViewController getResolution].width height:[StreamViewController getResolution].height displayModes:displayModes withCompletionBlock:^(NSDictionary *settingsJSON) {
            self.settings = settingsJSON[@"settings"];
            NSInteger settingsCount = self.settings.count;
            
            dispatch_async(dispatch_get_main_queue(), ^{
                self.settingsIndexSlider.numberOfTickMarks = settingsCount;
                self.settingsIndexSlider.minValue = 0.0;
                self.settingsIndexSlider.maxValue = settingsCount - 1;
                
                int index = ((NSNumber *)appSettings[@"settingsIndex"]).intValue;
                [self.settingsIndexSlider setDoubleValue:index];

                [self populateSettingsGridWithSettings:self.settings[index]];
                [self updateSettingsUI];
                
                [self hideLoadingView];
            });
        }];
    }];
        
    
    [self showLoadingView];
    
    self.spinner = [[NSProgressIndicator alloc] init];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    [self.spinner startAnimation:self];
    [self.view addSubview:self.spinner];
    
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor].active = YES;
    [self.spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor].active = YES;
    [self.spinner.widthAnchor constraintEqualToConstant:32].active = YES;
    [self.spinner.heightAnchor constraintEqualToConstant:32].active = YES;
}

- (NSSize)preferredMinimumSize {
    return NSMakeSize(380, 275);
}

- (void)showLoadingView {
    self.displayModeSelector.enabled = NO;
    self.settingsIndexSlider.enabled = NO;
    for (NSView *view in self.view.subviews) {
        if (view.class != NSButton.class) {
            view.hidden = YES;
        }
    }
}

- (void)hideLoadingView {
    [self.spinner removeFromSuperview];
    for (NSView *view in self.view.subviews) {
        view.hidden = NO;
    }
    self.displayModeSelector.enabled = YES;
    self.settingsIndexSlider.enabled = YES;
}

- (NSTextField *)createSettingLabelWithString:(NSString *)string {
    NSTextField *settingLabel = [NSTextField textFieldWithString:string];
    settingLabel.drawsBackground = NO;
    [settingLabel setBordered:NO];
    settingLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    settingLabel.font = [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSControlSizeSmall]];
    settingLabel.editable = NO;
    
    return settingLabel;
}

- (void)populateSettingsGridWithSettings:(NSArray<NSDictionary<NSString *, NSString *> *> *)settingsSet {
    BOOL isFirst = YES;
    for (NSDictionary *setting in settingsSet) {
        NSTextField *settingNameLabel = [self createSettingLabelWithString:setting[@"name"]];
        NSTextField *settingValueLabel = [self createSettingLabelWithString:setting[@"value"]];
        
        NSArray<NSView *> *settingViews = @[settingNameLabel, settingValueLabel];
        [self.settingsGrid addRowWithViews:settingViews];
        
        if (isFirst) {
            [self.settingsGrid removeRowAtIndex:0];
            isFirst = NO;
        }
    }
}

- (void)updateSettingsGridWithSettings:(NSArray<NSDictionary<NSString *, NSString *> *> *)settingsSet withDisplayMode:(NSString *)displayMode {
    for (int i = 0; i < settingsSet.count - 1; i++) {
        NSGridCell *keyCell = [self.settingsGrid cellAtColumnIndex:0 rowIndex:i];
        NSGridCell *valueCell = [self.settingsGrid cellAtColumnIndex:1 rowIndex:i];

        NSTextField *valuelabel = valueCell.contentView;
        valuelabel.stringValue = settingsSet[i][@"value"];

        NSTextField *keylabel = keyCell.contentView;
        if ([keylabel.stringValue isEqualToString:@"Display Mode"]) {
            valuelabel.stringValue = displayMode;
        }
    }
}

- (void)saveSettings {
    int index = ((int)self.settingsIndexSlider.doubleValue);
    NSString *displayMode = self.displayModeSelector.selectedItem.title;
    NSDictionary<NSString *, id> *object = @{
        @"settingsIndex": @(index),
        @"displayMode": displayMode,
    };
    
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:object requiringSecureCoding:NO error:nil];
    [NSUserDefaults.standardUserDefaults setObject:data forKey:self.appId];
}

- (void)updateSettingsUI {
    int index = ((int)self.settingsIndexSlider.doubleValue);
    [self updateSettingsGridWithSettings:self.settings[index] withDisplayMode:self.displayModeSelector.selectedItem.title];
}

+ (NSDictionary *)getSavedOptimalSettingsForApp:(NSString *)appId withInitialSettingsIndex:(int)index andIntialDisplayMode:(NSString *)displayMode {
    NSData *data = [NSUserDefaults.standardUserDefaults objectForKey:appId];
    NSDictionary *appSettings = nil;
    if (data != nil) {
        NSSet *allowedClasses = [NSSet setWithArray:@[NSDictionary.class, NSString.class, NSNumber.class]];
        appSettings = [NSKeyedUnarchiver unarchivedObjectOfClasses:allowedClasses fromData:data error:nil];
    }
    if (appSettings == nil) {
        appSettings = @{
            @"settingsIndex": @(index),
            @"displayMode": displayMode,
        };
    }
    
    return appSettings;
}


#pragma mark - Actions

- (IBAction)didToggleEnabledCheckbox:(NSButton *)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.state == NSControlStateValueOn forKey:[NSString stringWithFormat:@"%@: optimalSettingsEnabled", self.appId]];
}

- (IBAction)didChangeDisplayMode:(NSPopUpButton *)sender {
    [self saveSettings];
    [self updateSettingsUI];
}
- (IBAction)didChangeIndexOfSettingsSlider:(NSSlider *)sender {
    [self saveSettings];
    [self updateSettingsUI];
}

- (IBAction)didClickDoneButton:(id)sender {
    [self dismissViewController:self];
}

@end
