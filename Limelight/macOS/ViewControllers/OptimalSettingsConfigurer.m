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

@interface OptimalSettingsConfigurer ()
@property (weak) IBOutlet NSTextField *gameTitleLabel;
@property (weak) IBOutlet NSPopUpButton *displayModeSelector;
@property (weak) IBOutlet NSSlider *settingsIndexSlider;
@property (weak) IBOutlet NSGridView *settingsGrid;
@property (weak) IBOutlet NSButton *doneButton;

@property (nonatomic, strong) NSProgressIndicator *spinner;

@property (nonatomic, strong) TemporaryApp *app;
@property (nonatomic, strong) NSString *appId;
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
    
    self.gameTitleLabel.stringValue = [NSString stringWithFormat:@"Configure %@ Optimal Settings:", self.app.name];

    [PrivateGfeApiRequester requestStateOfApp:self.appId hostIP:self.app.host.activeAddress withCompletionBlock:^(NSDictionary<NSString *,id> *stateJSON) {
        NSArray<NSString *> *displayModes = stateJSON[@"REGULAR"][@"sliderSettingsDC"][@"displayMode"][@"values"];
        displayModes = [displayModes sortedArrayUsingComparator:^NSComparisonResult(NSString *obj1, NSString *obj2) {
            return [obj1 compare:obj2 options:NSCaseInsensitiveSearch];
        }];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray<NSMenuItem *> *allItems = self.displayModeSelector.menu.itemArray;
            [self.displayModeSelector.menu removeAllItems];
            
            for (NSString *displayMode in displayModes) {
                for (NSMenuItem *item in allItems) {
                    if ([item.title isEqualToString:displayMode]) {
                        item.state = NSControlStateValueOff;
                        [self.displayModeSelector.menu addItem:item];
                    }
                }
            }
            
            [self hideLoadingView];
        });
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

- (void)showLoadingView {
    self.displayModeSelector.enabled = NO;
    self.settingsIndexSlider.enabled = NO;
    for (NSView *view in self.view.subviews) {
        view.hidden = YES;
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


#pragma mark - Actions

- (IBAction)didChangeDisplayMode:(id)sender {
}
- (IBAction)didChangeIndexOfSettingsSlider:(id)sender {
}

- (IBAction)didClickDoneButton:(id)sender {
    [self dismissViewController:self];
}

@end
