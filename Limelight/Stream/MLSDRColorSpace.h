//
//  MLSDRColorSpace.h
//
//  The colour space an SDR stream is presented in.
//
//  The host's SDR desktop is an sRGB image: Windows composes it with the sRGB
//  transfer curve and the host encoder only converts RGB to Y'CbCr with the
//  BT.709 matrix and range, leaving the curve untouched. The stream's VUI still
//  says "transfer = BT.709", but that is a label that goes with the matrix, not
//  a statement about the picture. Tagging decoded frames kCGColorSpaceITUR_709
//  makes the system decode the sRGB code values with its own BT.709 video curve
//  instead of the sRGB curve, so the picture no longer matches the host and how
//  far it drifts depends on the OS release (macOS 26.6: sRGB 128 shows as 140;
//  Moonlight Enhanced issue #123 reports a darker picture on macOS 27.2).
//  BT.709 shares its primaries with sRGB, so tagging the frames sRGB shows the
//  host image exactly on an sRGB display and maps correctly on Display P3.
//
//  Header-only so the standalone tests can include it without the renderer.
//

#ifndef MLSDRColorSpace_h
#define MLSDRColorSpace_h

#include <CoreGraphics/CoreGraphics.h>

// Returns a +1 colour space (caller releases) for presenting SDR stream
// content. sRGB is always available; the generic fallback only guards NULL.
static inline CGColorSpaceRef MLCreateSDRStreamColorSpace(void)
{
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (colorSpace == NULL) {
        colorSpace = CGColorSpaceCreateDeviceRGB();
    }
    return colorSpace;
}

#endif /* MLSDRColorSpace_h */
