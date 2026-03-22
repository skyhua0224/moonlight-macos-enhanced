//
//  AboutViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 5/11/19.
//  Copyright © 2019 Moonlight Game Streaming Project. All rights reserved.
//

#import "AboutViewController.h"
#import "Helpers.h"
#import "Moonlight-Swift.h"

@interface AboutViewController ()
@property (weak) IBOutlet NSVisualEffectView *backgroundEffectView;
@property (weak) IBOutlet NSImageView *appIconImageView;
@property (weak) IBOutlet NSTextField *versionNumberTextField;
@property (weak) IBOutlet NSTextField *copyrightTextField;
@property (weak) IBOutlet NSTextField *githubTextFieldLink;
@property (weak) IBOutlet NSTextField *creditsTextFieldLink;
@end

@implementation AboutViewController

static NSString * const MoonlightEnhancedRepositoryURL = @"https://github.com/skyhua0224/moonlight-macos-enhanced";
static NSString * const MoonlightEnhancedReadmeURL = @"https://github.com/skyhua0224/moonlight-macos-enhanced/blob/master/README.md";

#pragma mark - Lifecycle

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.backgroundEffectView.material = NSVisualEffectMaterialMenu;

    [self setPreferredContentSize:NSMakeSize(self.view.bounds.size.width, self.view.bounds.size.height)];

    self.appIconImageView.image = [NSApp applicationIconImage];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(languageChanged:) name:@"LanguageChanged" object:nil];
    [self refreshAboutContent];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    [self refreshAboutContent];
}

- (void)languageChanged:(NSNotification *)notification {
    [self refreshAboutContent];
}

- (void)refreshAboutContent {
    self.versionNumberTextField.stringValue = [Helpers versionNumberString];
    self.copyrightTextField.stringValue = [Helpers copyrightString];

    self.githubTextFieldLink.stringValue = [[LanguageManager shared] localize:@"GitHub Repository"];
    self.creditsTextFieldLink.stringValue = [[LanguageManager shared] localize:@"README & Credits"];

    self.githubTextFieldLink.attributedStringValue = [self makeTextFieldLinkWithURLString:MoonlightEnhancedRepositoryURL :self.githubTextFieldLink];
    self.creditsTextFieldLink.attributedStringValue = [self makeTextFieldLinkWithURLString:MoonlightEnhancedReadmeURL :self.creditsTextFieldLink];

    if (self.view.window != nil) {
        self.view.window.title = [[LanguageManager shared] localize:@"About Moonlight macOS Enhanced"];
    }
}

- (NSAttributedString *)makeTextFieldLinkWithURLString:(NSString *)link :(NSTextField *)textField {
    [textField setAllowsEditingTextAttributes: YES];
    [textField setSelectable: YES];

    NSURL *url = [NSURL URLWithString:link];

    NSMutableParagraphStyle *paragraphStyle = [[[NSParagraphStyle alloc] init] mutableCopy];
    paragraphStyle.alignment = textField.alignment;
    
    NSDictionary *attrs = @{NSLinkAttributeName: url, NSParagraphStyleAttributeName: paragraphStyle, NSForegroundColorAttributeName: textField.textColor, NSFontAttributeName: textField.font, NSCursorAttributeName: [NSCursor pointingHandCursor], NSUnderlineColorAttributeName: [NSColor clearColor]};
    NSAttributedString *attrString = [[NSAttributedString alloc] initWithString:textField.stringValue attributes:attrs];

    return attrString;
}

@end
