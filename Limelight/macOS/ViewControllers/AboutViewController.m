//
//  AboutViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 5/11/19.
//  Copyright © 2019 Moonlight Game Streaming Project. All rights reserved.
//

#import "AboutViewController.h"
#import "NSWindow+Moonlight.h"
#import "Helpers.h"

@interface AboutViewController ()
@property (weak) IBOutlet NSVisualEffectView *backgroundEffectView;
@property (weak) IBOutlet NSImageView *appIconImageView;
@property (weak) IBOutlet NSTextField *versionNumberTextField;
@property (weak) IBOutlet NSTextField *creditsTextFieldLink;
@end

@implementation AboutViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    if (@available(macOS 11.0, *)) {
        self.backgroundEffectView.material = NSVisualEffectMaterialMenu;
    }

    [self setPreferredContentSize:NSMakeSize(self.view.bounds.size.width, self.view.bounds.size.height)];
  
    self.appIconImageView.image = [NSApp applicationIconImage];
    self.versionNumberTextField.stringValue = [Helpers versionNumberString];
    self.creditsTextFieldLink.attributedStringValue = [self makeTextFieldLink:self.creditsTextFieldLink];
}

- (NSAttributedString *)makeTextFieldLink:(NSTextField *)textField {
    [textField setAllowsEditingTextAttributes: YES];
    [textField setSelectable: YES];

    NSURL *url = [NSURL URLWithString:@"https://github.com/moonlight-stream/moonlight-ios"];

    NSMutableParagraphStyle *paragraphStyle = [[[NSParagraphStyle alloc] init] mutableCopy];
    paragraphStyle.alignment = NSTextAlignmentCenter;
    
    NSDictionary *attrs = @{NSLinkAttributeName: url, NSParagraphStyleAttributeName: paragraphStyle, NSForegroundColorAttributeName: textField.textColor, NSFontAttributeName: textField.font, NSCursorAttributeName: [NSCursor pointingHandCursor], NSUnderlineColorAttributeName: [NSColor clearColor]};
    NSAttributedString *attrString = [[NSAttributedString alloc] initWithString:textField.stringValue attributes:attrs];

    return attrString;
}

@end
