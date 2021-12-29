//
//  OptimalSettingsConfigurer.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 28/12/2021.
//  Copyright © 2021 Moonlight Game Streaming Project. All rights reserved.
//

#import "OptimalSettingsConfigurer.h"
#import "BackgroundColorView.h"

@interface OptimalSettingsConfigurer ()
@property (weak) IBOutlet NSTextField *gameTitleLabel;
@property (weak) IBOutlet NSPopUpButton *displayModeSelector;
@property (weak) IBOutlet NSSlider *settingsIndexSlider;
@property (weak) IBOutlet NSGridView *settingsGrid;
@property (weak) IBOutlet NSButton *doneButton;

@property (nonatomic, strong) NSProgressIndicator *spinner;

@property (nonatomic, strong) NSString *appName;
@property (nonatomic, strong) NSString *appId;
@end

@implementation OptimalSettingsConfigurer

- (instancetype)initWithAppName:(NSString *)appName andPrivateId:(NSString *)appId {
    self = [super init];
    if (self) {
        self.appName = appName;
        self.appId = appId;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.gameTitleLabel.stringValue = [NSString stringWithFormat:@"Configure %@ Optimal Settings:", self.appName];

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
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self hideLoadingView];
    });
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
