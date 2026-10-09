//
//  MLMenuItemImage.h
//  Moonlight for macOS
//

#import <AppKit/AppKit.h>

// macOS 27 hides menu item images unless the item opts in through
// preferredImageVisibility. Set via the selector so older SDKs still build.
static inline void MLSetMenuItemImage(NSMenuItem *item, NSImage *image) {
    item.image = image;
    SEL setter = NSSelectorFromString(@"setPreferredImageVisibility:");
    if (image != nil && [item respondsToSelector:setter]) {
        [item setValue:@1 forKey:@"preferredImageVisibility"];
    }
}
