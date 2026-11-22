// Colour-space tests for SDR stream presentation (MLSDRColorSpace.h).
//
// ColorSync does the conversion: what the system produces for a grey patch
// tagged with the stream colour space and shown on an sRGB / Display P3 display. No host, window or GPU is involved.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "MLSDRColorSpace.h"

static int gFailures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { gFailures++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

// Shows an 8-bit grey patch tagged `from` on a display described by `to` and
// returns the displayed 8-bit value of the first channel (and the spread
// between channels, which must stay 0 for a neutral patch).
static double DisplayedValue(CGColorSpaceRef from, CGColorSpaceRef to, int code, double *spread)
{
    CGFloat c = code / 255.0;
    CGFloat comps[4] = { c, c, c, 1.0 };
    CGColorRef in = CGColorCreate(from, comps);
    CGColorRef out = CGColorCreateCopyByMatchingToColorSpace(to, kCGRenderingIntentRelativeColorimetric, in, NULL);
    const CGFloat *o = CGColorGetComponents(out);
    double r = o[0] * 255.0, g = o[1] * 255.0, b = o[2] * 255.0;
    if (spread) {
        double hi = fmax(r, fmax(g, b)), lo = fmin(r, fmin(g, b));
        *spread = hi - lo;
    }
    CGColorRelease(in);
    CGColorRelease(out);
    return r;
}

int main(void)
{
    @autoreleasepool {
        CGColorSpaceRef stream = MLCreateSDRStreamColorSpace();
        CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGColorSpaceRef p3 = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
        CGColorSpaceRef bt709 = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
        CHECK(stream != NULL && srgb != NULL && p3 != NULL && bt709 != NULL, "colour spaces must exist");

        CFStringRef name = CGColorSpaceCopyName(stream);
        CHECK(name != NULL && CFEqual(name, kCGColorSpaceSRGB), "SDR stream space must be sRGB, got %s",
              name ? [(__bridge NSString *)name UTF8String] : "(null)");
        if (name) CFRelease(name);

        // sRGB desktop codes must reach an sRGB display unchanged, and stay
        // neutral on a Display P3 display (both share the sRGB curve).
        double worst = 0.0, worstSpread = 0.0;
        for (int code = 0; code <= 255; code++) {
            double spread = 0.0;
            double shown = DisplayedValue(stream, srgb, code, &spread);
            worst = fmax(worst, fabs(shown - code));
            double p3Spread = 0.0;
            double shownP3 = DisplayedValue(stream, p3, code, &p3Spread);
            worstSpread = fmax(worstSpread, fmax(spread, p3Spread));
            CHECK(fabs(shownP3 - code) < 0.6, "P3 display code %d -> %.2f", code, shownP3);
        }
        CHECK(worst < 0.6, "sRGB display: worst deviation %.3f codes", worst);
        CHECK(worstSpread < 0.6, "grey patches must stay neutral, spread %.3f", worstSpread);
        printf("stream=sRGB: worst deviation on sRGB display %.3f codes, neutral spread %.3f\n", worst, worstSpread);

        // Guard: the BT.709 tag the renderer used before is not the identity,
        // so this test cannot pass by accident if ColorSync ever stopped telling
        // the two spaces apart. (Only the size of the drift is asserted: the
        // window server applies its own BT.709 video curve to tagged layers, and
        // its direction differs between OS releases; see MLSDRColorSpace.h.)
        double drift = 0.0;
        for (int code = 16; code <= 224; code += 16) {
            drift = fmax(drift, fabs(DisplayedValue(bt709, srgb, code, NULL) - code));
        }
        printf("old BT.709 tag: largest deviation from the sRGB code on an sRGB display %.1f codes\n", drift);
        CHECK(drift >= 5.0, "BT.709 tag must differ from sRGB, deviation %.2f", drift);

        CGColorSpaceRelease(stream);
        CGColorSpaceRelease(srgb);
        CGColorSpaceRelease(p3);
        CGColorSpaceRelease(bt709);
    }
    if (gFailures) {
        printf("%d failure(s)\n", gFailures);
        return 1;
    }
    printf("sdr-colorspace: all checks passed\n");
    return 0;
}
