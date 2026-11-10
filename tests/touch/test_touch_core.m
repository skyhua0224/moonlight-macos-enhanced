// Touch core tests: see run.sh. Exit status is the number of failed checks (capped).

#import <Foundation/Foundation.h>
#import "MLTouchCore.h"
#import "Limelight.h"

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(...) do { g_checks++; if (!(__VA_ARGS__)) { g_failures++; \
    fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, #__VA_ARGS__); } } while (0)
#define CHECK_NEAR(a, b, eps) do { g_checks++; if (fabs((double)(a) - (double)(b)) > (eps)) { g_failures++; \
    fprintf(stderr, "FAIL %s:%d  %s (%f) != %s (%f)\n", __FILE__, __LINE__, #a, (double)(a), #b, (double)(b)); } } while (0)

typedef struct { MLTouchWireEvent event; uint32_t pid; float x; float y; } Wire;

static MLTouchSample *S(NSString *id_, MLTouchPhase phase, CGFloat x, CGFloat y, NSTimeInterval t) {
    return [MLTouchSample sampleWithIdentity:id_ phase:phase point:CGPointMake(x, y) timestamp:t];
}

#pragma mark - Mode selection

static void testModeSelection(void) {
    CHECK(MLTouchHostSupportsNative(LI_FF_PEN_TOUCH_EVENTS));
    CHECK(!MLTouchHostSupportsNative(0));
    CHECK(!MLTouchHostSupportsNative(LI_FF_CONTROLLER_TOUCH_EVENTS | LI_FF_CLIPBOARD_TEXT));
    CHECK(MLTouchHostSupportsNative(LI_FF_CLIPBOARD_TEXT | LI_FF_PEN_TOUCH_EVENTS));

    // Native preference: native on a host that can, touchpad on one that cannot.
    CHECK(MLTouchEffectiveMode(MLTouchInputModeNative, LI_FF_PEN_TOUCH_EVENTS) == MLTouchInputModeNative);
    CHECK(MLTouchEffectiveMode(MLTouchInputModeNative, 0) == MLTouchInputModeTrackpad);
    CHECK(MLTouchEffectiveMode(MLTouchInputModeNative, LI_FF_TOUCHPAD_EVENTS) == MLTouchInputModeTrackpad);
    // An explicit choice is kept whatever the host says.
    CHECK(MLTouchEffectiveMode(MLTouchInputModeTrackpad, LI_FF_PEN_TOUCH_EVENTS) == MLTouchInputModeTrackpad);
    CHECK(MLTouchEffectiveMode(MLTouchInputModeTrackpad, 0) == MLTouchInputModeTrackpad);
    CHECK(MLTouchEffectiveMode(MLTouchInputModeDirect, LI_FF_PEN_TOUCH_EVENTS) == MLTouchInputModeDirect);
    CHECK(MLTouchEffectiveMode(MLTouchInputModeDirect, 0) == MLTouchInputModeDirect);
    // Stored values that do not exist (a newer build's setting read by this one) mean native.
    CHECK(MLTouchModeFromStoredValue(-1) == MLTouchInputModeNative);
    CHECK(MLTouchModeFromStoredValue(7) == MLTouchInputModeNative);
    CHECK(MLTouchModeFromStoredValue(1) == MLTouchInputModeTrackpad);
    CHECK(MLTouchModeFromStoredValue(2) == MLTouchInputModeDirect);
}

#pragma mark - Coordinates

static void testVideoRectAndNormalize(void) {
    // Window exactly the picture's shape.
    CGRect r = MLTouchVideoRect(CGSizeMake(1280, 720), CGSizeMake(1920, 1080), NO);
    CHECK_NEAR(r.origin.x, 0, 1e-9); CHECK_NEAR(r.origin.y, 0, 1e-9);
    CHECK_NEAR(r.size.width, 1280, 1e-9); CHECK_NEAR(r.size.height, 720, 1e-9);

    // Windowed, taller than the picture: letterbox bars above and below.
    r = MLTouchVideoRect(CGSizeMake(1600, 1000), CGSizeMake(1920, 1080), NO);
    CHECK_NEAR(r.size.width, 1600, 1e-9); CHECK_NEAR(r.size.height, 900, 1e-9);
    CHECK_NEAR(r.origin.y, 50, 1e-9); CHECK_NEAR(r.origin.x, 0, 1e-9);

    // Full screen on a 3024x1964 point screen (14-inch class): a 16:9 picture is letterboxed.
    r = MLTouchVideoRect(CGSizeMake(3024, 1964), CGSizeMake(2560, 1440), NO);
    CHECK_NEAR(r.size.width, 3024, 1e-6); CHECK_NEAR(r.size.height, 1701, 1e-6);
    CHECK_NEAR(r.origin.y, (1964 - 1701) / 2.0, 1e-6);

    // A 4:3 picture in a wide window: pillarbox bars left and right.
    r = MLTouchVideoRect(CGSizeMake(1600, 900), CGSizeMake(1024, 768), NO);
    CHECK_NEAR(r.size.height, 900, 1e-9); CHECK_NEAR(r.size.width, 1200, 1e-9);
    CHECK_NEAR(r.origin.x, 200, 1e-9);

    // Stretch to fill, and unknown sizes, use the whole view.
    r = MLTouchVideoRect(CGSizeMake(1600, 1000), CGSizeMake(1920, 1080), YES);
    CHECK(CGRectEqualToRect(r, CGRectMake(0, 0, 1600, 1000)));
    r = MLTouchVideoRect(CGSizeMake(1600, 1000), CGSizeZero, NO);
    CHECK(CGRectEqualToRect(r, CGRectMake(0, 0, 1600, 1000)));

    // Normalise: top-left origin out, bottom-left origin in.
    CGRect box = CGRectMake(0, 50, 1600, 900);
    CGPoint n; BOOL inside;
    inside = MLTouchNormalize(CGPointMake(0, 950), box, NO, &n);    // top-left corner of the picture
    CHECK(inside); CHECK_NEAR(n.x, 0, 1e-9); CHECK_NEAR(n.y, 0, 1e-9);
    inside = MLTouchNormalize(CGPointMake(1600, 50), box, NO, &n);  // bottom-right corner
    CHECK(inside); CHECK_NEAR(n.x, 1, 1e-9); CHECK_NEAR(n.y, 1, 1e-9);
    inside = MLTouchNormalize(CGPointMake(800, 500), box, NO, &n);  // centre
    CHECK(inside); CHECK_NEAR(n.x, 0.5, 1e-9); CHECK_NEAR(n.y, 0.5, 1e-9);
    inside = MLTouchNormalize(CGPointMake(400, 725), box, NO, &n);  // a quarter across, a quarter down
    CHECK(inside); CHECK_NEAR(n.x, 0.25, 1e-9); CHECK_NEAR(n.y, 0.25, 1e-9);
    // In the bars: outside, and clamping pulls it to the edge.
    inside = MLTouchNormalize(CGPointMake(800, 20), box, NO, &n);
    CHECK(!inside);
    inside = MLTouchNormalize(CGPointMake(800, 20), box, YES, &n);
    CHECK(!inside); CHECK_NEAR(n.y, 1, 1e-9); CHECK_NEAR(n.x, 0.5, 1e-9);
    inside = MLTouchNormalize(CGPointMake(-30, 990), box, YES, &n);
    CHECK(!inside); CHECK_NEAR(n.x, 0, 1e-9); CHECK_NEAR(n.y, 0, 1e-9);
    // Not a number is never inside.
    inside = MLTouchNormalize(CGPointMake(NAN, 10), box, YES, &n);
    CHECK(!inside);
    inside = MLTouchNormalize(CGPointMake(5, 5), CGRectZero, YES, &n);
    CHECK(!inside);

    // Retina: the view is measured in points, so the same finger gives the same answer whether the
    // backing store is 1x or 2x. A pixel-measured view and point gives the identical ratio.
    CGSize points = CGSizeMake(1440, 900);
    CGSize pixels = CGSizeMake(2880, 1800);
    CGRect rp = MLTouchVideoRect(points, CGSizeMake(1920, 1080), NO);
    CGRect rx = MLTouchVideoRect(pixels, CGSizeMake(1920, 1080), NO);
    CGPoint np, nx;
    MLTouchNormalize(CGPointMake(300, 400), rp, YES, &np);
    MLTouchNormalize(CGPointMake(600, 800), rx, YES, &nx);
    CHECK_NEAR(np.x, nx.x, 1e-9); CHECK_NEAR(np.y, nx.y, 1e-9);

    // Window versus full screen: the same spot on the picture maps to the same numbers.
    CGRect win = MLTouchVideoRect(CGSizeMake(1280, 800), CGSizeMake(1920, 1080), NO);
    CGRect full = MLTouchVideoRect(CGSizeMake(3024, 1964), CGSizeMake(1920, 1080), NO);
    CGPoint inWin = CGPointMake(win.origin.x + win.size.width * 0.3, win.origin.y + win.size.height * 0.8);
    CGPoint inFull = CGPointMake(full.origin.x + full.size.width * 0.3, full.origin.y + full.size.height * 0.8);
    CGPoint nw, nf;
    MLTouchNormalize(inWin, win, NO, &nw);
    MLTouchNormalize(inFull, full, NO, &nf);
    CHECK_NEAR(nw.x, 0.3, 1e-9); CHECK_NEAR(nw.y, 1.0 - 0.8, 1e-9);
    CHECK_NEAR(nf.x, nw.x, 1e-9); CHECK_NEAR(nf.y, nw.y, 1e-9);
}

#pragma mark - Pointer ids

static void testPointerTable(void) {
    MLTouchPointerTable *t = [[MLTouchPointerTable alloc] init];
    CHECK(t.capacity == 10);
    CHECK([t beginIdentity:@"a"] == 0);
    CHECK([t beginIdentity:@"b"] == 1);
    CHECK([t beginIdentity:@"c"] == 2);
    CHECK([t beginIdentity:@"b"] == 1);          // asking again does not take a second slot
    CHECK(t.activeCount == 3);
    CHECK([t pointerIdForIdentity:@"c"] == 2);
    CHECK([t pointerIdForIdentity:@"zz"] == -1);

    // Ending frees the id; the next touch takes the lowest free one.
    CHECK([t endIdentity:@"b"] == 1);
    CHECK([t pointerIdForIdentity:@"b"] == -1);
    CHECK([t endIdentity:@"b"] == -1);           // already gone
    CHECK([t beginIdentity:@"d"] == 1);
    CHECK([t beginIdentity:@"e"] == 3);
    NSArray *active = [t activePointerIds];
    CHECK(active.count == 4 && [active[0] intValue] == 0 && [active[1] intValue] == 1 && [active[2] intValue] == 2 && [active[3] intValue] == 3);

    // Fill every slot: the eleventh finger gets nothing, the freed slot comes back after a lap.
    for (int i = 0; i < 20; i++) [t endIdentity:[NSString stringWithFormat:@"x%d", i]];
    [t reset];
    for (int i = 0; i < 10; i++) CHECK([t beginIdentity:[NSString stringWithFormat:@"f%d", i]] == i);
    CHECK([t beginIdentity:@"f10"] == -1);
    CHECK(t.activeCount == 10);
    CHECK([t endIdentity:@"f4"] == 4);
    CHECK([t beginIdentity:@"f11"] == 4);        // the only free slot, the lowest free one
    CHECK([t beginIdentity:@"f12"] == -1);

    // Re-use over many touches: ids stay inside 0..9 and are unique among live touches.
    [t reset];
    NSMutableSet *live = [NSMutableSet set];
    for (int round = 0; round < 200; round++) {
        NSString *ident = [NSString stringWithFormat:@"t%d", round];
        NSInteger pid = [t beginIdentity:ident];
        CHECK(pid >= 0 && pid < 10);
        CHECK(![live containsObject:@(pid)]);
        [live addObject:@(pid)];
        if (live.count >= 3) {
            NSString *old = [NSString stringWithFormat:@"t%d", round - 2];
            NSInteger freed = [t endIdentity:old];
            CHECK(freed >= 0);
            [live removeObject:@(freed)];
        }
    }
    [t reset];
    CHECK(t.activeCount == 0);
    CHECK([t beginIdentity:@"after-reset"] >= 0);
}

#pragma mark - Forwarder

static MLTouchForwarder *makeForwarder(NSMutableArray<NSValue *> *log, CGSize view, CGSize video) {
    MLTouchForwarder *f = [[MLTouchForwarder alloc] init];
    f.viewSize = view; f.videoSize = video; f.stretch = NO;
    f.sink = ^(MLTouchWireEvent e, uint32_t pid, float x, float y) {
        Wire w = { e, pid, x, y };
        [log addObject:[NSValue valueWithBytes:&w objCType:@encode(Wire)]];
    };
    return f;
}

static Wire wireAt(NSArray<NSValue *> *log, NSUInteger i) {
    Wire w = {0};
    [log[i] getValue:&w];
    return w;
}

static void testForwarder(void) {
    NSMutableArray *log = [NSMutableArray array];
    // 1600x1000 view, 16:9 picture: 50 point bars above and below.
    MLTouchForwarder *f = makeForwarder(log, CGSizeMake(1600, 1000), CGSizeMake(1920, 1080));

    // Down, move, up of one finger: id 0, picture-relative coordinates, top-left origin.
    [f processSamples:@[S(@"A", MLTouchPhaseBegan, 800, 500, 0.0)]];
    [f processSamples:@[S(@"A", MLTouchPhaseMoved, 1200, 725, 0.1)]];
    [f processSamples:@[S(@"A", MLTouchPhaseEnded, 1200, 725, 0.2)]];
    CHECK(log.count == 3);
    Wire w = wireAt(log, 0);
    CHECK(w.event == LI_TOUCH_EVENT_DOWN && w.pid == 0); CHECK_NEAR(w.x, 0.5, 1e-6); CHECK_NEAR(w.y, 0.5, 1e-6);
    w = wireAt(log, 1);
    CHECK(w.event == LI_TOUCH_EVENT_MOVE && w.pid == 0); CHECK_NEAR(w.x, 0.75, 1e-6); CHECK_NEAR(w.y, 0.25, 1e-6);
    w = wireAt(log, 2);
    CHECK(w.event == LI_TOUCH_EVENT_UP && w.pid == 0);
    CHECK(f.activeCount == 0);

    // Two fingers at once keep separate ids, and each id is the same through its whole life.
    [log removeAllObjects];
    [f processSamples:@[S(@"B", MLTouchPhaseBegan, 400, 500, 1.0), S(@"C", MLTouchPhaseBegan, 1200, 500, 1.0)]];
    [f processSamples:@[S(@"C", MLTouchPhaseMoved, 1250, 520, 1.1), S(@"B", MLTouchPhaseMoved, 380, 500, 1.1)]];
    [f processSamples:@[S(@"B", MLTouchPhaseEnded, 380, 500, 1.2)]];
    [f processSamples:@[S(@"C", MLTouchPhaseEnded, 1250, 520, 1.3)]];
    CHECK(log.count == 6);
    uint32_t idB = wireAt(log, 0).pid, idC = wireAt(log, 1).pid;
    CHECK(idB != idC);
    CHECK(wireAt(log, 2).pid == idC && wireAt(log, 3).pid == idB);
    CHECK(wireAt(log, 4).event == LI_TOUCH_EVENT_UP && wireAt(log, 4).pid == idB);
    CHECK(wireAt(log, 5).event == LI_TOUCH_EVENT_UP && wireAt(log, 5).pid == idC);

    // A touch that lands in the black bars is never sent, not even when it slides onto the picture.
    [log removeAllObjects];
    [f processSamples:@[S(@"bar", MLTouchPhaseBegan, 800, 20, 2.0)]];
    [f processSamples:@[S(@"bar", MLTouchPhaseMoved, 800, 500, 2.1)]];
    [f processSamples:@[S(@"bar", MLTouchPhaseEnded, 800, 500, 2.2)]];
    CHECK(log.count == 0);
    CHECK(f.activeCount == 0);
    CHECK(![f isForwarding:@"bar"]);

    // A touch that starts on the picture and drifts into the bars is clamped, not dropped.
    [f processSamples:@[S(@"D", MLTouchPhaseBegan, 800, 60, 3.0)]];
    [f processSamples:@[S(@"D", MLTouchPhaseMoved, 800, 10, 3.1)]];
    [f processSamples:@[S(@"D", MLTouchPhaseEnded, 800, 10, 3.2)]];
    CHECK(log.count == 3);
    CHECK_NEAR(wireAt(log, 1).y, 1.0, 1e-6);
    CHECK(wireAt(log, 2).event == LI_TOUCH_EVENT_UP);

    // Stationary changes nothing on the wire.
    [log removeAllObjects];
    [f processSamples:@[S(@"E", MLTouchPhaseBegan, 800, 500, 4.0)]];
    [f processSamples:@[S(@"E", MLTouchPhaseStationary, 800, 500, 4.1)]];
    CHECK(log.count == 1);
    // A move of a touch first seen mid-life becomes its down.
    [f processSamples:@[S(@"late", MLTouchPhaseMoved, 400, 400, 4.2)]];
    CHECK(log.count == 2 && wireAt(log, 1).event == LI_TOUCH_EVENT_DOWN);
    // Cancel frees the slot and says CANCEL for that pointer only.
    uint32_t lateId = wireAt(log, 1).pid;
    [f processSamples:@[S(@"late", MLTouchPhaseCancelled, 400, 400, 4.3)]];
    CHECK(log.count == 3 && wireAt(log, 2).event == LI_TOUCH_EVENT_CANCEL && wireAt(log, 2).pid == lateId);
    CHECK(f.activeCount == 1);
    // An end for a touch we never knew is nothing.
    [f processSamples:@[S(@"ghost", MLTouchPhaseEnded, 400, 400, 4.4)]];
    CHECK(log.count == 3);
    // Cancel-all says so once and clears everything; a second call is silent.
    [f cancelAll];
    CHECK(log.count == 4 && wireAt(log, 3).event == LI_TOUCH_EVENT_CANCEL_ALL);
    CHECK(f.activeCount == 0);
    [f cancelAll];
    CHECK(log.count == 4);

    // Ten fingers, the host's limit; the eleventh is ignored for its whole life and does not disturb the others.
    [log removeAllObjects];
    for (int i = 0; i < 10; i++) {
        [f processSamples:@[S([NSString stringWithFormat:@"p%d", i], MLTouchPhaseBegan, 100 + i * 100, 500, 5.0)]];
    }
    CHECK(f.activeCount == 10);
    [f processSamples:@[S(@"p10", MLTouchPhaseBegan, 50, 500, 5.1)]];
    CHECK(log.count == 10 && f.activeCount == 10);
    [f processSamples:@[S(@"p10", MLTouchPhaseMoved, 60, 500, 5.2), S(@"p10", MLTouchPhaseEnded, 60, 500, 5.3)]];
    CHECK(log.count == 10);
    NSMutableSet *ids = [NSMutableSet set];
    for (NSUInteger i = 0; i < 10; i++) [ids addObject:@(wireAt(log, i).pid)];
    CHECK(ids.count == 10);
    // Lifting one makes room for a new finger, which gets the free id.
    [f processSamples:@[S(@"p3", MLTouchPhaseEnded, 400, 500, 5.4)]];
    [f processSamples:@[S(@"q", MLTouchPhaseBegan, 450, 500, 5.5)]];
    CHECK(wireAt(log, log.count - 1).event == LI_TOUCH_EVENT_DOWN);
    CHECK(wireAt(log, log.count - 1).pid == wireAt(log, 3).pid);   // the lowest free id is the one just released
    CHECK([f pointerIdForIdentity:@"q"] == (NSInteger)wireAt(log, 3).pid);
}

#pragma mark - Fallback emulator

typedef struct { MLTouchEmuEvent e; } Emu;

static MLTouchPointerEmulator *makeEmu(NSMutableArray<NSValue *> *log, MLTouchInputMode mode) {
    MLTouchPointerEmulator *em = [[MLTouchPointerEmulator alloc] init];
    em.mode = mode;
    em.viewSize = CGSizeMake(1600, 1000);
    em.videoSize = CGSizeMake(1920, 1080);
    em.sink = ^(MLTouchEmuEvent e) {
        [log addObject:[NSValue valueWithBytes:&e objCType:@encode(MLTouchEmuEvent)]];
    };
    return em;
}

static MLTouchEmuEvent emuAt(NSArray<NSValue *> *log, NSUInteger i) {
    MLTouchEmuEvent e = {0};
    [log[i] getValue:&e];
    return e;
}

static NSUInteger countKind(NSArray<NSValue *> *log, MLTouchEmuKind k) {
    NSUInteger n = 0;
    for (NSUInteger i = 0; i < log.count; i++) if (emuAt(log, i).kind == k) n++;
    return n;
}

