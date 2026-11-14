//
//  StreamOverlayLegacy.m
//

#import "StreamOverlayLegacy.h"
#import "MoonlightEnhanced-Swift.h"

static NSString *LegacyString(NSString *key) {
    return [[LanguageManager shared] localize:key];
}

@implementation MLLegacyOverlay

+ (NSVisualEffectView *)makeContainerWithLabel:(NSTextField **)outLabel {
    NSVisualEffectView *container = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    container.material = NSVisualEffectMaterialHUDWindow;
    container.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    container.state = NSVisualEffectStateActive;
    container.wantsLayer = YES;
    container.layer.cornerRadius = 10.0;
    container.layer.masksToBounds = YES;

    NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.editable = NO;
    label.selectable = NO;
    label.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
    [container addSubview:label];
    *outLabel = label;
    return container;
}

+ (NSAttributedString *)attributedStringForMetrics:(MLOverlayMetrics *)m {
    NSMutableAttributedString *attrString = [[NSMutableAttributedString alloc] init];

    NSDictionary *labelAttrs = @{
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightRegular]
    };
    NSDictionary *valueAttrs = @{
        NSForegroundColorAttributeName: [NSColor colorWithRed:1.0 green:1.0 blue:0.5 alpha:1.0],
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightBold]
    };
    void (^append)(NSString *, NSDictionary *) = ^(NSString *str, NSDictionary *attrs) {
        [attrString appendAttributedString:[[NSAttributedString alloc] initWithString:str attributes:attrs]];
    };

    append([NSString stringWithFormat:@"%ldx%ld@%ld", (long)m.width, (long)m.height, (long)m.configuredFps], valueAttrs);
    append(@"  ", labelAttrs);
    append(m.codec, valueAttrs);
    append(@"  ", labelAttrs);
    append(m.chroma, valueAttrs);
    if (m.hdrName.length > 0) {
        append(@"  HDR ", labelAttrs);
        append(m.hdrName, valueAttrs);
        if (m.hdrFallback.length > 0) {
            append([NSString stringWithFormat:@" (%@)", m.hdrFallback], labelAttrs);
        }
    }
    append(@"  FPS ", labelAttrs);
    append([NSString stringWithFormat:@"%.1f", m.receivedFps], valueAttrs);
    append(@" Rx · ", labelAttrs);
    append([NSString stringWithFormat:@"%.1f", m.decodedFps], valueAttrs);
    append(@" De · ", labelAttrs);
    append([NSString stringWithFormat:@"%.1f", m.renderedFps], valueAttrs);
    append(@" Rd", labelAttrs);
    append(@"  ", labelAttrs);
    append(LegacyString(@"1% Low"), labelAttrs);
    append(@" ", labelAttrs);
    if (m.onePercentLow > 0.0f) {
        append([NSString stringWithFormat:@"%.1f", m.onePercentLow], valueAttrs);
    } else {
        append(@"--", valueAttrs);
    }

    append(@"  ", labelAttrs);
    append(LegacyString(@"Stream Latency"), labelAttrs);
    append(@" ", labelAttrs);
    if (m.streamLatencyAvailable) {
        if (m.streamLatencyApproximate) {
            append(@"~", labelAttrs);
        }
        append([NSString stringWithFormat:@"%.1f", m.streamLatencyMs], valueAttrs);
        append(@" ms", labelAttrs);
    } else {
        append(LegacyString(@"Not Available"), valueAttrs);
    }
    append(@"  Loss ", labelAttrs);
    append([NSString stringWithFormat:@"%.2f%%", m.lossPercent], valueAttrs);

    if (m.netAvailable) {
        append(@"  Net ", labelAttrs);
        append([NSString stringWithFormat:@"%.2f%%", m.netLossPercent], valueAttrs);
        if (m.fecRecovered > 0 || m.fecFailed > 0) {
            append(@"  FEC ", labelAttrs);
            append([NSString stringWithFormat:@"+%u", m.fecRecovered], valueAttrs);
            append(@"/", labelAttrs);
            append([NSString stringWithFormat:@"-%u", m.fecFailed], valueAttrs);
        }
        if (m.fecFeedbackActive) {
            append(@"  Par ", labelAttrs);
            append([NSString stringWithFormat:@"%u%%", m.blockParityPercent], valueAttrs);
            append(@" Fb ", labelAttrs);
            append([NSString stringWithFormat:@"%u/%u", m.fecFeedbackMissing, m.fecFeedbackData], valueAttrs);
        }
    }

    append(@"  Jit ", labelAttrs);
    append([NSString stringWithFormat:@"%.1f", m.jitterMs], valueAttrs);
    append(@" ms  Br ", labelAttrs);
    append([NSString stringWithFormat:@"%.1f", m.bitrateMbps], valueAttrs);
    append(@" Mbps", labelAttrs);
    append(@"  Pace ", labelAttrs);
    append([NSString stringWithFormat:@"%.1f", m.pacingJitterMs], valueAttrs);
    append(@" ms · p99 ", labelAttrs);
    append([NSString stringWithFormat:@"%.1f", m.renderP99Ms], valueAttrs);
    append(@" ms", labelAttrs);
    if (m.stallCount > 0) {
        append(@" · Stall ", labelAttrs);
        append([NSString stringWithFormat:@"%u", m.stallCount], valueAttrs);
    }

    append(@"  |  ", labelAttrs);
    append(LegacyString(@"Pipeline"), labelAttrs);
    append(@" ", labelAttrs);
    append([NSString stringWithFormat:@"%.2f", m.pipelineMs], valueAttrs);
    append(@" ms · ", labelAttrs);
    append(LegacyString(@"Host"), labelAttrs);
    append(@" ", labelAttrs);
    append([NSString stringWithFormat:@"%.1f", m.hostMs], valueAttrs);
    append(@" ms · Decode ", labelAttrs);
    append([NSString stringWithFormat:@"%.2f", m.decodeMs], valueAttrs);
    append(@" ms · Queue ", labelAttrs);
    append([NSString stringWithFormat:@"%.2f", m.queueMs], valueAttrs);
    append(@" ms", labelAttrs);

    if (m.noPayloadStreakSeconds > 0) {
        append(@"  |  Stall ", labelAttrs);
        append([NSString stringWithFormat:@"%lus", (unsigned long)m.noPayloadStreakSeconds], valueAttrs);
    } else if (m.frozenStatsStreakSeconds > 0) {
        append(@"  |  Stale ", labelAttrs);
        append([NSString stringWithFormat:@"%lus", (unsigned long)m.frozenStatsStreakSeconds], valueAttrs);
    }
    return attrString;
}

+ (void)layoutContainer:(NSView *)container label:(NSTextField *)label inParent:(NSView *)parent {
    [label sizeToFit];
    CGFloat padding = 10.0;
    NSRect labelFrame = label.frame;
    NSRect containerFrame = NSMakeRect(0, 0, labelFrame.size.width + padding * 2, labelFrame.size.height + padding * 2);
    CGFloat x = (parent.bounds.size.width - containerFrame.size.width) / 2;
    CGFloat y = parent.bounds.size.height - containerFrame.size.height - 20;
    containerFrame.origin = NSMakePoint(x, y);
    container.frame = containerFrame;
    label.frame = NSMakeRect(padding, padding, labelFrame.size.width, labelFrame.size.height);
}

@end
