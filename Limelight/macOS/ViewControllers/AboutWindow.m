//
//  AboutWindow.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 5/11/19.
//  Copyright © 2019 Moonlight Game Streaming Project. All rights reserved.
//

#import "AboutWindow.h"
#import "NSWindow+Moonlight.h"

@interface AboutWindow ()
@property (weak) IBOutlet NSVisualEffectView *backgroundEffectView;
@property (weak) IBOutlet NSTextField *creditsTextFieldLink;
@end

@implementation AboutWindow

#pragma mark - Lifecycle

- (void)awakeFromNib {
    [super awakeFromNib];

    if (@available(macOS 11.0, *)) {
        self.backgroundEffectView.material = NSVisualEffectMaterialHUDWindow;
    }

    self.frameAutosaveName = @"About Window";
    [self moonlight_centerWindowOnFirstRun];

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
