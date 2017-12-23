//
//  ContainerViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 23/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "ContainerViewController.h"

@interface ContainerViewController ()

@end

@implementation ContainerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.wantsLayer = YES;
    
    NSViewController *hostsVC = [self.storyboard instantiateControllerWithIdentifier:@"hostsVC"];
    [self addChildViewController:hostsVC];
    [self.view addSubview:hostsVC.view];
    
    hostsVC.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    hostsVC.view.frame = self.view.bounds;
}

@end
