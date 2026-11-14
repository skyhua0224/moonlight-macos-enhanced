//
//  StreamOverlayLegacy.h
//  The original one-line performance overlay (attributed text in a HUD material), kept as the
//  fallback for systems without the SwiftUI overlay (below macOS 14) and for the concept fixture
//  that draws "today". It formats an OverlayMetrics snapshot exactly as updateStats always did.
//

#import <Cocoa/Cocoa.h>

@class MLOverlayMetrics;

NS_ASSUME_NONNULL_BEGIN

@interface MLLegacyOverlay : NSObject
+ (NSVisualEffectView *)makeContainerWithLabel:(NSTextField * _Nullable * _Nonnull)label;
+ (NSAttributedString *)attributedStringForMetrics:(MLOverlayMetrics *)metrics;
/// Sizes the label and puts the container top centre, 20 px from the top (as before).
+ (void)layoutContainer:(NSView *)container label:(NSTextField *)label inParent:(NSView *)parent;
@end

NS_ASSUME_NONNULL_END
