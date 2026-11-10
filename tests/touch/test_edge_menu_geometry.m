// Control ball placement (MLEdgeMenuGeometry.h): the docked ball is on screen on every display size, in every dock
// position, with and without a notch or menu bar. A test build showed it 50 pt past the right edge of a 1920x1080 borderless
// window with only 11 pt of plate left, which read as "the ball is gone". Exit status = failed checks.

#import <Foundation/Foundation.h>
#import "../../Limelight/macOS/ViewControllers/MLEdgeMenuGeometry.h"

static int g_failures = 0, g_checks = 0;
#define CHECK(...) do { g_checks++; if (!(__VA_ARGS__)) { g_failures++; \
    fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, #__VA_ARGS__); } } while (0)

static MLEdgeMenuMetrics metrics(void) {
    MLEdgeMenuMetrics m = { .size = 78.0, .plateRatio = 0.58, .plateEdgeGap = 4.0, .collapsedFraction = 0.5, .crossInset = 88.0 };
    return m;
}

static double visibleShare(CGRect frame, CGRect rect, MLEdgeMenuMetrics m) {
    CGRect v = MLEdgeMenuVisiblePlate(frame, rect, m);
    double plate = m.size * m.plateRatio;
    if (CGRectIsNull(v)) return 0;
    return (v.size.width * v.size.height) / (plate * plate);
}

static void testSizes(void) {
    struct { double w, h; MLEdgeMenuInsets safe; const char *name; } cases[] = {
        { 1920, 1080, {0, 0, 0, 0}, "borderless 1920x1080 (the reported screen)" },
        { 1512, 982,  {0, 0, 0, 0}, "14-inch window" },
        { 1512, 944,  {38, 0, 0, 0}, "14-inch fullscreen under the notch" },
        { 1512, 982,  {38, 0, 0, 0}, "borderless with the notch inset" },
        { 3456, 2234, {0, 0, 0, 0}, "16-inch native" },
        { 2560, 1440, {24, 0, 0, 0}, "external with a menu bar" },
        { 1280, 720,  {0, 0, 0, 0}, "windowed 720p" },
        { 640, 480,   {0, 0, 0, 0}, "small window" },
        { 100, 100,   {0, 0, 0, 0}, "tiny window: shorter than the keep-out" },
        { 3840, 2160, {0, 0, 0, 0}, "4K" },
    };
    MLEdgeMenuMetrics m = metrics();
    double ratios[] = { 0.0, 0.25, 0.5, 1.0, -1.0, 7.0 };   // out-of-range ratios (a stale default) are clamped
    for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); c++) {
        CGRect rect = CGRectMake(0, 0, cases[c].w, cases[c].h);
        MLEdgeMenuInsets safe = cases[c].safe;
        // The rectangle the plate must lie in when fully docked.
        CGRect safeRect = CGRectMake(safe.left, safe.bottom, cases[c].w - safe.left - safe.right, cases[c].h - safe.bottom - safe.top);
        for (int dock = 0; dock < 4; dock++) {
            for (size_t r = 0; r < sizeof(ratios) / sizeof(ratios[0]); r++) {
                CGRect shown = MLEdgeMenuComputeFrame(rect, safe, (MLEdgeMenuDock)dock, ratios[r], NO, m);
                CGRect tucked = MLEdgeMenuComputeFrame(rect, safe, (MLEdgeMenuDock)dock, ratios[r], YES, m);
                CGRect plateShown = MLEdgeMenuVisiblePlate(shown, rect, m);
                double plate = m.size * m.plateRatio;
                bool ok = CGRectContainsRect(safeRect, CGRectMake(plateShown.origin.x, plateShown.origin.y, plateShown.size.width, plateShown.size.height))
                          && fabs(plateShown.size.width - plate) < 1e-6 && fabs(plateShown.size.height - plate) < 1e-6;
                if (!ok) fprintf(stderr, "  not docked on screen: %s dock=%d ratio=%.2f frame=%s\n", cases[c].name, dock, ratios[r], NSStringFromRect(NSRectFromCGRect(shown)).UTF8String);
                CHECK(ok);
                double share = visibleShare(tucked, safeRect, m);   // what shows below a notch / menu bar band
                if (share < 0.5 - 1e-6) fprintf(stderr, "  tucked too far out: %s dock=%d ratio=%.2f share=%.2f\n", cases[c].name, dock, ratios[r], share);
                CHECK(share >= 0.5 - 1e-6);
                CHECK(share <= 0.5 + 1e-6);   // half-tucked, the designed look: not still fully out, not further in
                // Tucked and docked sit on the same line along the edge, only the depth differs.
                if (dock < 2) CHECK(fabs(shown.origin.y - tucked.origin.y) < 1e-6);
                else CHECK(fabs(shown.origin.x - tucked.origin.x) < 1e-6);
            }
        }
    }
}

static void testExactFrames(void) {
    MLEdgeMenuMetrics m = metrics();
    CGRect rect = CGRectMake(0, 0, 1920, 1080);
    MLEdgeMenuInsets none = {0, 0, 0, 0};
    // Right dock, middle: docked plate 4 pt from the edge (ball view 16.38 pt further out); the old tucked frame had
    // x = 1892.31 with 11 pt of plate visible, now 22.6 pt.
    CGRect docked = MLEdgeMenuComputeFrame(rect, none, MLEdgeMenuDockRight, 0.5, NO, m);
    CHECK(fabs(CGRectGetMaxX(docked) - (1920 + (78 * 0.42 / 2) - 4)) < 1e-6);
    CHECK(fabs(docked.origin.y - (88 + (1080 - 78 - 176) * 0.5)) < 1e-6);
    CGRect tucked = MLEdgeMenuComputeFrame(rect, none, MLEdgeMenuDockRight, 0.5, YES, m);
    double plate = 78 * 0.58, pad = (78 - plate) / 2;
    CHECK(fabs((1920 - (tucked.origin.x + pad)) - plate * 0.5) < 1e-6);
    CHECK(tucked.origin.x + pad < 1920 - 20);   // at least 20 pt of plate on screen: not the 11 pt sliver
    // The notch: a top dock is pushed below it when docked.
    MLEdgeMenuInsets notch = {38, 0, 0, 0};
    CGRect top = MLEdgeMenuComputeFrame(CGRectMake(0, 0, 1512, 982), notch, MLEdgeMenuDockTop, 0.5, NO, m);
    CHECK(CGRectGetMaxY(top) - pad <= 982 - 38 - 4 + 1e-6);
    // Left dock, ratio 0 and 1 stay inside the vertical keep-out.
    CGRect lo = MLEdgeMenuComputeFrame(rect, none, MLEdgeMenuDockLeft, 0.0, NO, m);
    CGRect hi = MLEdgeMenuComputeFrame(rect, none, MLEdgeMenuDockLeft, 1.0, NO, m);
    CHECK(lo.origin.y >= 88 - 1e-6 && CGRectGetMaxY(hi) <= 1080 - 88 + 1e-6);
}

int main(void) {
    @autoreleasepool {
        testSizes();
        testExactFrames();
    }
    fprintf(stderr, "edge menu geometry: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures > 255 ? 255 : g_failures;
}
