//
//  ContainerViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 23/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "ContainerViewController.h"
#import "NSWindow+Moonlight.h"
#import "BackgroundColorView.h"

@interface ContainerViewController ()
@property (weak) IBOutlet BackgroundColorView *titleContainer;

@end

@implementation ContainerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.wantsLayer = YES;
    
    NSViewController *hostsVC = [self.storyboard instantiateControllerWithIdentifier:@"hostsVC"];
    [self addChildViewController:hostsVC];
    [self.view addSubview:hostsVC.view positioned:NSWindowBelow relativeTo:self.titleContainer];
    
    hostsVC.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    hostsVC.view.frame = self.view.bounds;
    
    self.titleContainer.backgroundColor = [NSColor selectedTextBackgroundColor];
    self.titleContainer.wantsLayer = YES;
    self.titleContainer.layer.masksToBounds = YES;
    self.titleContainer.layer.cornerRadius = self.titleContainer.frame.size.height / 2;
}

- (void)viewDidAppear {
    [super viewDidAppear];
    
    self.view.window.frameAutosaveName = @"Main Window";
    [self.view.window moonlight_centerWindowOnFirstRun];
}

- (void)setTitle:(NSString *)title {
    ((NSTextField *)self.titleContainer.subviews.firstObject).stringValue = title;
    self.view.window.title = title;
}

@end
