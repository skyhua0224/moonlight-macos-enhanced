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

static void testTrackpadEmulator(void) {
    NSMutableArray *log = [NSMutableArray array];
    MLTouchPointerEmulator *em = makeEmu(log, MLTouchInputModeTrackpad);

    // A short still tap is a left click: press then release.
    [em processSamples:@[S(@"a", MLTouchPhaseBegan, 500, 500, 0.0)]];
    [em processSamples:@[S(@"a", MLTouchPhaseEnded, 501, 500, 0.1)]];
    CHECK(log.count == 2);
    CHECK(emuAt(log, 0).kind == MLTouchEmuKindButton && emuAt(log, 0).button == MLTouchEmuButtonLeft && emuAt(log, 0).pressed);
    CHECK(emuAt(log, 1).kind == MLTouchEmuKindButton && emuAt(log, 1).button == MLTouchEmuButtonLeft && !emuAt(log, 1).pressed);

    // A slow touch is not a click.
    [log removeAllObjects];
    [em processSamples:@[S(@"b", MLTouchPhaseBegan, 500, 500, 1.0)]];
    [em processSamples:@[S(@"b", MLTouchPhaseEnded, 500, 500, 1.3)]];
    CHECK(countKind(log, MLTouchEmuKindButton) == 0);

    // Dragging moves the pointer by deltas and does not click.
    [log removeAllObjects];
    [em processSamples:@[S(@"c", MLTouchPhaseBegan, 500, 500, 2.0)]];
    [em processSamples:@[S(@"c", MLTouchPhaseMoved, 520, 490, 2.02)]];
    [em processSamples:@[S(@"c", MLTouchPhaseMoved, 540, 480, 2.04)]];
    [em processSamples:@[S(@"c", MLTouchPhaseEnded, 540, 480, 2.1)]];
    CHECK(countKind(log, MLTouchEmuKindMoveRelative) == 2);
    CHECK_NEAR(emuAt(log, 0).a, 20, 1e-6); CHECK_NEAR(emuAt(log, 0).b, -10, 1e-6);
    CHECK(countKind(log, MLTouchEmuKindButton) == 0);

    // Two-finger tap is a right click.
    [log removeAllObjects];
    [em processSamples:@[S(@"d1", MLTouchPhaseBegan, 400, 500, 3.0), S(@"d2", MLTouchPhaseBegan, 480, 500, 3.01)]];
    [em processSamples:@[S(@"d1", MLTouchPhaseEnded, 400, 500, 3.1), S(@"d2", MLTouchPhaseEnded, 480, 500, 3.11)]];
    CHECK(log.count == 2);
    CHECK(emuAt(log, 0).button == MLTouchEmuButtonRight && emuAt(log, 0).pressed);
    CHECK(emuAt(log, 1).button == MLTouchEmuButtonRight && !emuAt(log, 1).pressed);

    // Two-finger drag scrolls (fingers up = positive) and clicks nothing, also when one lifts first.
    [log removeAllObjects];
    [em processSamples:@[S(@"e1", MLTouchPhaseBegan, 400, 500, 4.0), S(@"e2", MLTouchPhaseBegan, 480, 500, 4.0)]];
    for (int i = 1; i <= 5; i++) {
        [em processSamples:@[S(@"e1", MLTouchPhaseMoved, 400, 500 + i * 10, 4.0 + i * 0.02),
                             S(@"e2", MLTouchPhaseMoved, 480, 500 + i * 10, 4.0 + i * 0.02)]];
    }
    [em processSamples:@[S(@"e1", MLTouchPhaseEnded, 400, 550, 4.2)]];
    [em processSamples:@[S(@"e2", MLTouchPhaseMoved, 480, 570, 4.25)]]; // the lone finger left must not move the pointer
    [em processSamples:@[S(@"e2", MLTouchPhaseEnded, 480, 570, 4.3)]];
    CHECK(countKind(log, MLTouchEmuKindButton) == 0);
    CHECK(countKind(log, MLTouchEmuKindMoveRelative) == 0);
    CHECK(countKind(log, MLTouchEmuKindScroll) >= 3);
    for (NSUInteger i = 0; i < log.count; i++) {
        if (emuAt(log, i).kind == MLTouchEmuKindScroll) CHECK(emuAt(log, i).a > 0);
    }

    // A single finger after a two-finger gesture starts a fresh session.
    [log removeAllObjects];
    [em processSamples:@[S(@"f", MLTouchPhaseBegan, 300, 300, 5.0)]];
    [em processSamples:@[S(@"f", MLTouchPhaseEnded, 300, 300, 5.1)]];
    CHECK(countKind(log, MLTouchEmuKindButton) == 2);

    // Long press: the poll presses the left button, moving then drags, lifting releases. No click on release.
    [log removeAllObjects];
    [em processSamples:@[S(@"g", MLTouchPhaseBegan, 300, 300, 6.0)]];
    [em pollAtTime:6.2];
    CHECK(countKind(log, MLTouchEmuKindButton) == 0 && !em.leftButtonDown);
    [em pollAtTime:6.5];
    CHECK(countKind(log, MLTouchEmuKindButton) == 1 && em.leftButtonDown);
    [em pollAtTime:6.6];
    CHECK(countKind(log, MLTouchEmuKindButton) == 1);                  // once only
    [em processSamples:@[S(@"g", MLTouchPhaseMoved, 330, 300, 6.7)]];
    CHECK(countKind(log, MLTouchEmuKindMoveRelative) == 1);
    [em processSamples:@[S(@"g", MLTouchPhaseEnded, 330, 300, 6.8)]];
    CHECK(countKind(log, MLTouchEmuKindButton) == 2 && !em.leftButtonDown);
    CHECK(!emuAt(log, log.count - 1).pressed);

    // A finger that moved is never a long press.
    [log removeAllObjects];
    [em processSamples:@[S(@"h", MLTouchPhaseBegan, 300, 300, 7.0)]];
    [em processSamples:@[S(@"h", MLTouchPhaseMoved, 340, 300, 7.1)]];
    [em pollAtTime:8.0];
    CHECK(countKind(log, MLTouchEmuKindButton) == 0);
    [em processSamples:@[S(@"h", MLTouchPhaseEnded, 340, 300, 8.1)]];

    // Cancelling the touch while the button is held lets go of it.
    [log removeAllObjects];
    [em processSamples:@[S(@"i", MLTouchPhaseBegan, 300, 300, 9.0)]];
    [em pollAtTime:9.6];
    CHECK(em.leftButtonDown);
    [em cancelAll];
    CHECK(!em.leftButtonDown && !emuAt(log, log.count - 1).pressed);
}

static void testDirectEmulator(void) {
    NSMutableArray *log = [NSMutableArray array];
    MLTouchPointerEmulator *em = makeEmu(log, MLTouchInputModeDirect);

    // Down: the pointer jumps under the finger (centre of the picture = 0.5, 0.5) and presses.
    [em processSamples:@[S(@"a", MLTouchPhaseBegan, 800, 500, 0.0)]];
    CHECK(log.count == 2);
    CHECK(emuAt(log, 0).kind == MLTouchEmuKindMoveAbsolute);
    CHECK_NEAR(emuAt(log, 0).a, 0.5, 1e-6); CHECK_NEAR(emuAt(log, 0).b, 0.5, 1e-6);
    CHECK(emuAt(log, 1).kind == MLTouchEmuKindButton && emuAt(log, 1).pressed && em.leftButtonDown);
    // Move follows the finger in absolute terms; up releases at the last position.
    [em processSamples:@[S(@"a", MLTouchPhaseMoved, 1200, 725, 0.1)]];
    CHECK(emuAt(log, log.count - 1).kind == MLTouchEmuKindMoveAbsolute);
    CHECK_NEAR(emuAt(log, log.count - 1).a, 0.75, 1e-6);
    [em processSamples:@[S(@"a", MLTouchPhaseEnded, 1200, 725, 0.2)]];
    CHECK(emuAt(log, log.count - 1).kind == MLTouchEmuKindButton && !emuAt(log, log.count - 1).pressed);
    CHECK(!em.leftButtonDown);

    // A second finger on a still first finger lets go of the left button and makes a scroll / right click session.
    [log removeAllObjects];
    [em processSamples:@[S(@"b1", MLTouchPhaseBegan, 800, 500, 1.0)]];
    [em processSamples:@[S(@"b2", MLTouchPhaseBegan, 900, 500, 1.02)]];
    CHECK(!em.leftButtonDown);
    CHECK(countKind(log, MLTouchEmuKindButton) == 2);     // press, release
    [log removeAllObjects];
    [em processSamples:@[S(@"b1", MLTouchPhaseEnded, 800, 500, 1.1), S(@"b2", MLTouchPhaseEnded, 900, 500, 1.11)]];
    CHECK(countKind(log, MLTouchEmuKindButton) == 2);     // the right click
    CHECK(emuAt(log, log.count - 2).button == MLTouchEmuButtonRight && emuAt(log, log.count - 2).pressed);

    // A second finger on a dragging first finger does not interrupt the drag.
    [log removeAllObjects];
    [em processSamples:@[S(@"c1", MLTouchPhaseBegan, 800, 500, 2.0)]];
    [em processSamples:@[S(@"c1", MLTouchPhaseMoved, 900, 500, 2.1)]];
    [em processSamples:@[S(@"c2", MLTouchPhaseBegan, 400, 500, 2.2)]];
    CHECK(em.leftButtonDown);
    [em processSamples:@[S(@"c2", MLTouchPhaseEnded, 400, 500, 2.3)]];
    [em processSamples:@[S(@"c1", MLTouchPhaseEnded, 900, 500, 2.4)]];
    CHECK(!em.leftButtonDown);

    // Two-finger drag scrolls.
    [log removeAllObjects];
    [em processSamples:@[S(@"d1", MLTouchPhaseBegan, 400, 500, 3.0)]];
    [em processSamples:@[S(@"d2", MLTouchPhaseBegan, 480, 500, 3.01)]];
    [log removeAllObjects];
    for (int i = 1; i <= 4; i++) {
        [em processSamples:@[S(@"d1", MLTouchPhaseMoved, 400, 500 - i * 12, 3.0 + i * 0.02),
                             S(@"d2", MLTouchPhaseMoved, 480, 500 - i * 12, 3.0 + i * 0.02)]];
    }
    CHECK(countKind(log, MLTouchEmuKindScroll) >= 2);
    for (NSUInteger i = 0; i < log.count; i++) {
        if (emuAt(log, i).kind == MLTouchEmuKindScroll) CHECK(emuAt(log, i).a < 0);
    }
    [em processSamples:@[S(@"d1", MLTouchPhaseEnded, 400, 452, 3.2), S(@"d2", MLTouchPhaseEnded, 480, 452, 3.2)]];
    CHECK(countKind(log, MLTouchEmuKindButton) == 0);
}

#pragma mark - Five-finger hold

static MLTouchFiveFingerHold *makeHold(NSMutableArray<NSNumber *> *states, int *triggers) {
    MLTouchFiveFingerHold *h = [[MLTouchFiveFingerHold alloc] init];
    h.onStateChange = ^(MLTouchHoldState st) { [states addObject:@(st)]; };
    h.onTrigger = ^{ (*triggers)++; };
    return h;
}

static NSArray *landFingers(int n, NSTimeInterval t0, NSTimeInterval step) {
    NSMutableArray *a = [NSMutableArray array];
    for (int i = 0; i < n; i++) [a addObject:S([NSString stringWithFormat:@"h%d", i], MLTouchPhaseBegan, 100 + i * 120, 300 + i * 10, t0 + i * step)];
    return a;
}

static void testFiveFingerHold(void) {
    NSMutableArray *states = [NSMutableArray array];
    int triggers = 0;
    MLTouchFiveFingerHold *h = makeHold(states, &triggers);
    CHECK(h.requiredTouches == 5 && h.holdDuration == 0.8 && h.maxMovement == 20.0);

    // Five fingers land together and stay: nothing before 0.8 s, one trigger at 0.8 s, none after.
    [h processSamples:landFingers(5, 10.0, 0.0)];
    CHECK(h.state == MLTouchHoldStateArming && h.downCount == 5);
    CHECK_NEAR([h progressAtTime:10.0], 0.0, 1e-9);
    CHECK_NEAR([h progressAtTime:10.4], 0.5, 1e-9);
    [h pollAtTime:10.79];
    CHECK(triggers == 0 && h.state == MLTouchHoldStateArming);
    [h pollAtTime:10.8];
    CHECK(triggers == 1 && h.state == MLTouchHoldStateFired);
    CHECK_NEAR([h progressAtTime:10.9], 0.0, 1e-9);
    [h pollAtTime:12.0];
    CHECK(triggers == 1);
    // Lifting after the trigger does nothing more; with every finger up it is armed again.
    NSMutableArray *ups = [NSMutableArray array];
    for (int i = 0; i < 5; i++) [ups addObject:S([NSString stringWithFormat:@"h%d", i], MLTouchPhaseEnded, 100 + i * 120, 300 + i * 10, 13.0)];
    [h processSamples:ups];
    CHECK(h.state == MLTouchHoldStateIdle && h.downCount == 0 && triggers == 1);
    NSArray *expected = @[@(MLTouchHoldStateArming), @(MLTouchHoldStateFired), @(MLTouchHoldStateIdle)];
    CHECK([states isEqualToArray:expected]);

    // It can be done again.
    [h processSamples:landFingers(5, 20.0, 0.0)];
    [h pollAtTime:20.85];
    CHECK(triggers == 2);
    [h reset];

    // Lifted early: no trigger, and the same fingers coming back do not re-arm until all were up.
    [states removeAllObjects]; triggers = 0;
    h = makeHold(states, &triggers);
    [h processSamples:landFingers(5, 30.0, 0.0)];
    [h processSamples:@[S(@"h2", MLTouchPhaseEnded, 340, 320, 30.5)]];
    CHECK(h.state == MLTouchHoldStateFailed);
    [h pollAtTime:31.5];
    CHECK(triggers == 0);
    [h processSamples:@[S(@"h2b", MLTouchPhaseBegan, 340, 320, 31.6)]];   // five down again, but not from empty
    [h pollAtTime:33.0];
    CHECK(triggers == 0 && h.state == MLTouchHoldStateFailed);
    NSMutableArray *rest = [NSMutableArray array];
    for (NSString *n in @[@"h0", @"h1", @"h2b", @"h3", @"h4"]) [rest addObject:S(n, MLTouchPhaseEnded, 100, 300, 34.0)];
    [h processSamples:rest];
    CHECK(h.state == MLTouchHoldStateIdle);

    // Movement: 19 points is a hold, 21 points is not (measured from where each touch began).
    h = makeHold(states, &triggers); triggers = 0;
    [h processSamples:landFingers(5, 40.0, 0.0)];
    [h processSamples:@[S(@"h0", MLTouchPhaseMoved, 100 + 19, 300, 40.2)]];
    [h pollAtTime:40.8];
    CHECK(triggers == 1);
    h = makeHold(states, &triggers); triggers = 0;
    [h processSamples:landFingers(5, 50.0, 0.0)];
    [h processSamples:@[S(@"h4", MLTouchPhaseMoved, 100 + 4 * 120 + 12, 350 + 17, 50.2)]];   // sqrt(12^2+17^2) = 20.8
    CHECK(h.state == MLTouchHoldStateFailed);
    [h pollAtTime:51.0];
    CHECK(triggers == 0);
    // small jitter in many events still counts from the start, not step by step
    h = makeHold(states, &triggers); triggers = 0;
    [h processSamples:landFingers(5, 60.0, 0.0)];
    for (int i = 1; i <= 6; i++) [h processSamples:@[S(@"h1", MLTouchPhaseMoved, 220 + i * 4, 310, 60.0 + i * 0.05)]];   // 24 points in total
    CHECK(h.state == MLTouchHoldStateFailed);

    // Four fingers never arm; a sixth makes it fail; five staggered landings count the hold from the fifth.
    h = makeHold(states, &triggers); triggers = 0;
    [h processSamples:landFingers(4, 70.0, 0.0)];
    [h pollAtTime:75.0];
    CHECK(triggers == 0 && h.state == MLTouchHoldStateIdle);
    [h reset];
    h = makeHold(states, &triggers); triggers = 0;
    [h processSamples:landFingers(5, 80.0, 0.0)];
    [h processSamples:@[S(@"h5", MLTouchPhaseBegan, 800, 300, 80.3)]];
    CHECK(h.state == MLTouchHoldStateFailed);
    [h pollAtTime:82.0];
    CHECK(triggers == 0);
    h = makeHold(states, &triggers); triggers = 0;
    [h processSamples:landFingers(5, 90.0, 0.5)];           // landings at 90.0, 90.5, ... 92.0
    [h pollAtTime:92.7];
    CHECK(triggers == 0);
    [h pollAtTime:92.8];
    CHECK(triggers == 1);

    // Six touches landing one after another never trigger on the way up (the sixth arrives before the fifth's hold ends).
    h = makeHold(states, &triggers); triggers = 0;
    [h processSamples:landFingers(6, 100.0, 0.1)];
    [h pollAtTime:105.0];
    CHECK(triggers == 0);

    // The centroid is the middle of the touches that are down.
    h = makeHold(states, &triggers);
    [h processSamples:landFingers(5, 110.0, 0.0)];
    CGPoint c = h.centroid;
    CHECK_NEAR(c.x, 100 + 2 * 120, 1e-6); CHECK_NEAR(c.y, 300 + 2 * 10, 1e-6);
}

static void testHoldCancelsHostTouches(void) {
    // The runtime's wiring: the five touches are being sent from the first contact; when the hold fires the host gets
    // CANCEL_ALL, and nothing of those five is sent afterwards, while a touch that begins later is.
    NSMutableArray *log = [NSMutableArray array];
    MLTouchForwarder *f = makeForwarder(log, CGSizeMake(1600, 1000), CGSizeMake(1920, 1080));
    MLTouchFiveFingerHold *h = [[MLTouchFiveFingerHold alloc] init];
    h.onTrigger = ^{ [f cancelAllAndIgnoreCurrentTouches]; };

    NSArray *down = landFingers(5, 10.0, 0.0);
    [h processSamples:down]; [f processSamples:down];
    CHECK(log.count == 5);                                      // for 0.8 s the host does see five touches
    for (NSUInteger i = 0; i < 5; i++) CHECK(wireAt(log, i).event == LI_TOUCH_EVENT_DOWN);
    [h pollAtTime:10.8];
    CHECK(log.count == 6 && wireAt(log, 5).event == LI_TOUCH_EVENT_CANCEL_ALL);
    CHECK(f.activeCount == 0);

    // The fingers are still down and moving: nothing reaches the host, and they do not "begin" again.
    NSArray *move = @[S(@"h0", MLTouchPhaseMoved, 105, 300, 11.0), S(@"h3", MLTouchPhaseMoved, 470, 335, 11.0)];
    [h processSamples:move]; [f processSamples:move];
    CHECK(log.count == 6);
    // A finger that lands after the gesture works as usual.
    NSArray *late = @[S(@"late", MLTouchPhaseBegan, 800, 500, 11.5)];
    [h processSamples:late]; [f processSamples:late];
    CHECK(log.count == 7 && wireAt(log, 6).event == LI_TOUCH_EVENT_DOWN);
    // Lifting the five sends nothing; the late finger's end does.
    NSMutableArray *ups = [NSMutableArray array];
    for (int i = 0; i < 5; i++) [ups addObject:S([NSString stringWithFormat:@"h%d", i], MLTouchPhaseEnded, 100, 300, 12.0)];
    [h processSamples:ups]; [f processSamples:ups];
    CHECK(log.count == 7);
    [f processSamples:@[S(@"late", MLTouchPhaseEnded, 800, 500, 12.5)]];
    CHECK(log.count == 8 && wireAt(log, 7).event == LI_TOUCH_EVENT_UP);
    // A new set of five afterwards is a fresh touch sequence for the host and a new hold.
    NSArray *again = landFingers(5, 20.0, 0.0);
    [h processSamples:again]; [f processSamples:again];
    CHECK(log.count == 13 && wireAt(log, 8).event == LI_TOUCH_EVENT_DOWN);

    // No hold: fingers that lift early are forwarded as always.
    log = [NSMutableArray array];
    f = makeForwarder(log, CGSizeMake(1600, 1000), CGSizeMake(1920, 1080));
    h = [[MLTouchFiveFingerHold alloc] init];
    h.onTrigger = ^{ [f cancelAllAndIgnoreCurrentTouches]; };
    down = landFingers(5, 30.0, 0.0);
    [h processSamples:down]; [f processSamples:down];
    NSArray *up1 = @[S(@"h0", MLTouchPhaseEnded, 100, 300, 30.3)];
    [h processSamples:up1]; [f processSamples:up1];
    [h pollAtTime:31.5];
    CHECK(log.count == 6 && wireAt(log, 5).event == LI_TOUCH_EVENT_UP);
}

#pragma mark - Gate

static void testMouseGate(void) {
    MLTouchMouseGate *g = [[MLTouchMouseGate alloc] init];
    NSTimeInterval age = 0;
    // Disabled: everything passes.
    CHECK([g verdictForMouseKind:MLTouchGateMouseDown button:0 point:CGPointMake(10, 10) time:1 touchSubtype:YES ageSinceTouch:&age] == MLTouchGateVerdictPass);

    g.enabled = YES;
    // A real mouse with no touch around passes.
    CHECK([g verdictForMouseKind:MLTouchGateMouseDown button:0 point:CGPointMake(10, 10) time:1 touchSubtype:NO ageSinceTouch:&age] == MLTouchGateVerdictPass);
    CHECK([g verdictForMouseKind:MLTouchGateMouseUp button:0 point:CGPointMake(10, 10) time:1.1 touchSubtype:NO ageSinceTouch:&age] == MLTouchGateVerdictPass);
    // The runtime believes the subtype always: a touch-made click from a touch the recognizer never saw.
    g.subtypeAlwaysDrops = YES;
    CHECK([g verdictForMouseKind:MLTouchGateMouseDown button:0 point:CGPointMake(10, 10) time:0.5 touchSubtype:YES ageSinceTouch:&age] == MLTouchGateVerdictDropSubtype);
    CHECK([g verdictForMouseKind:MLTouchGateMouseUp button:0 point:CGPointMake(10, 10) time:0.6 touchSubtype:YES ageSinceTouch:&age] == MLTouchGateVerdictDropSequence);
    CHECK([g verdictForMouseKind:MLTouchGateMouseDown button:0 point:CGPointMake(10, 10) time:0.7 touchSubtype:NO ageSinceTouch:&age] == MLTouchGateVerdictPass);
    [g verdictForMouseKind:MLTouchGateMouseUp button:0 point:CGPointMake(10, 10) time:0.8 touchSubtype:NO ageSinceTouch:&age];
    g.subtypeAlwaysDrops = NO;
    // A subtype that says touch, on a Mac where no touch has happened (trackpad, mouse): passes.
    CHECK([g verdictForMouseKind:MLTouchGateMouseDown button:0 point:CGPointMake(10, 10) time:1.5 touchSubtype:YES ageSinceTouch:&age] == MLTouchGateVerdictPass);
    [g verdictForMouseKind:MLTouchGateMouseUp button:0 point:CGPointMake(10, 10) time:1.6 touchSubtype:YES ageSinceTouch:&age];
    // With a touch in play, an event that says it came from touch is dropped, with its up.
    [g noteTouchPoint:CGPointMake(900, 900) active:NO time:1.9];
    CHECK([g verdictForMouseKind:MLTouchGateMouseDown button:0 point:CGPointMake(10, 10) time:2 touchSubtype:YES ageSinceTouch:&age] == MLTouchGateVerdictDropSubtype);
    CHECK([g verdictForMouseKind:MLTouchGateMouseMove button:0 point:CGPointMake(400, 10) time:2.05 touchSubtype:NO ageSinceTouch:&age] == MLTouchGateVerdictDropSequence);
    CHECK([g verdictForMouseKind:MLTouchGateMouseUp button:0 point:CGPointMake(400, 10) time:2.1 touchSubtype:NO ageSinceTouch:&age] == MLTouchGateVerdictDropSequence);
    CHECK([g verdictForMouseKind:MLTouchGateMouseDown button:0 point:CGPointMake(10, 10) time:5 touchSubtype:NO ageSinceTouch:&age] == MLTouchGateVerdictPass);
    [g verdictForMouseKind:MLTouchGateMouseUp button:0 point:CGPointMake(10, 10) time:5.1 touchSubtype:NO ageSinceTouch:&age];

    // While a finger is down every mouse event is the emulation's.
    [g noteTouchPoint:CGPointMake(500, 500) active:YES time:10.0];
    CHECK([g verdictForMouseKind:MLTouchGateMouseDown button:0 point:CGPointMake(500, 500) time:10.01 touchSubtype:NO ageSinceTouch:&age] == MLTouchGateVerdictDropCorrelated);
    CHECK(age >= 0 && age < 0.05);
    [g noteAllTouchesUpAtTime:10.2];
    // The up of that click arrives after the finger lifted: still dropped, so the host never sees half a click.
    CHECK([g verdictForMouseKind:MLTouchGateMouseUp button:0 point:CGPointMake(500, 500) time:10.21 touchSubtype:NO ageSinceTouch:&age] == MLTouchGateVerdictDropSequence);

    // Soon after the lift, near the finger: dropped. Far away, or late: passes (a real mouse).
    CHECK([g verdictForMouseKind:MLTouchGateMouseDown button:0 point:CGPointMake(510, 505) time:10.3 touchSubtype:NO ageSinceTouch:&age] == MLTouchGateVerdictDropCorrelated);
    [g verdictForMouseKind:MLTouchGateMouseUp button:0 point:CGPointMake(510, 505) time:10.31 touchSubtype:NO ageSinceTouch:&age];
    CHECK([g verdictForMouseKind:MLTouchGateMouseDown button:0 point:CGPointMake(900, 505) time:10.3 touchSubtype:NO ageSinceTouch:&age] == MLTouchGateVerdictPass);
    [g verdictForMouseKind:MLTouchGateMouseUp button:0 point:CGPointMake(900, 505) time:10.31 touchSubtype:NO ageSinceTouch:&age];
    CHECK([g verdictForMouseKind:MLTouchGateMouseDown button:0 point:CGPointMake(500, 500) time:11.0 touchSubtype:NO ageSinceTouch:&age] == MLTouchGateVerdictPass);
    CHECK(age > 0.5 && age < 1.0);
    CHECK(g.passedNearTouchCount >= 1);
    [g verdictForMouseKind:MLTouchGateMouseUp button:0 point:CGPointMake(500, 500) time:11.1 touchSubtype:NO ageSinceTouch:&age];

    // A touch note nothing closed does not hold the mouse forever.
    [g reset];
    [g noteTouchPoint:CGPointMake(500, 500) active:YES time:30.0];
    CHECK([g verdictForMouseKind:MLTouchGateMouseDown button:0 point:CGPointMake(900, 900) time:30.5 touchSubtype:NO ageSinceTouch:&age] == MLTouchGateVerdictDropCorrelated);
    [g verdictForMouseKind:MLTouchGateMouseUp button:0 point:CGPointMake(900, 900) time:30.6 touchSubtype:NO ageSinceTouch:&age];
    CHECK([g verdictForMouseKind:MLTouchGateMouseDown button:0 point:CGPointMake(900, 900) time:33.0 touchSubtype:NO ageSinceTouch:&age] == MLTouchGateVerdictPass);
    [g verdictForMouseKind:MLTouchGateMouseUp button:0 point:CGPointMake(900, 900) time:33.1 touchSubtype:NO ageSinceTouch:&age];

    // Right button tracked on its own.
    [g reset];
    [g noteTouchPoint:CGPointMake(1, 1) active:NO time:19.9];
    CHECK([g verdictForMouseKind:MLTouchGateMouseDown button:1 point:CGPointMake(1, 1) time:20 touchSubtype:YES ageSinceTouch:&age] == MLTouchGateVerdictDropSubtype);
    CHECK([g verdictForMouseKind:MLTouchGateMouseDown button:0 point:CGPointMake(900, 900) time:20.1 touchSubtype:NO ageSinceTouch:&age] == MLTouchGateVerdictPass);
    CHECK([g verdictForMouseKind:MLTouchGateMouseUp button:1 point:CGPointMake(1, 1) time:20.2 touchSubtype:NO ageSinceTouch:&age] == MLTouchGateVerdictDropSequence);
    CHECK(g.droppedCount > 0);

    // GCMouse is gated only after direct-touch evidence arrives first and only inside one display frame.
    [g reset];
    CHECK(![g shouldDropGCMouseButton:0 pressed:YES time:50.0]);
    [g noteDirectTouchBeganAtTime:60.0];
    CHECK(![g shouldDropGCMouseButton:0 pressed:YES time:59.999]);  // evidence cannot arrive after the event
    CHECK([g shouldDropGCMouseButton:0 pressed:YES time:60.010]);
    CHECK([g shouldDropGCMouseButton:0 pressed:NO time:60.020]);
    CHECK(![g shouldDropGCMouseButton:0 pressed:NO time:60.030]);
    CHECK(![g shouldDropGCMouseButton:0 pressed:YES time:60.100]);  // outside the frame window: physical mouse passes
    CHECK(![g shouldDropGCMouseButton:0 pressed:NO time:60.110]);
}

#pragma mark - Click routing

// A recorded session on a MacBook trackpad, replayed: every press had subtype-touch=1, no touch screen, no touch ever in
// play (age-since-touch=-1, down=0). All of them were dropped because the runtime believed the subtype always.
static void testTrackpadClicksReachHost(void) {
    CHECK(!MLTouchSubtypeBelievedWithoutTouch(NO, YES));   // a MacBook without a touch screen, window key
    CHECK(!MLTouchSubtypeBelievedWithoutTouch(NO, NO));    // ... even when the window is not key
    CHECK(!MLTouchSubtypeBelievedWithoutTouch(YES, YES));  // touch screen, window key: the recognizer sees every touch
    CHECK(MLTouchSubtypeBelievedWithoutTouch(YES, NO));    // touch screen, window not key: the activating touch is unseen

    MLTouchMouseGate *g = [[MLTouchMouseGate alloc] init];
    g.enabled = YES;
    g.subtypeAlwaysDrops = MLTouchSubtypeBelievedWithoutTouch(NO, YES);
    NSTimeInterval age = 0, t = 100.0;
    for (int i = 0; i < 50; i++) {
        NSInteger button = i % 5 == 4 ? 1 : 0;   // mostly left clicks, a two-finger right click now and then
        CHECK([g verdictForMouseKind:MLTouchGateMouseDown button:button point:CGPointMake(500, 400) time:t touchSubtype:YES ageSinceTouch:&age] == MLTouchGateVerdictPass);
        CHECK([g verdictForMouseKind:MLTouchGateMouseMove button:button point:CGPointMake(510, 400) time:t + 0.02 touchSubtype:YES ageSinceTouch:&age] == MLTouchGateVerdictPass);
        CHECK([g verdictForMouseKind:MLTouchGateMouseUp button:button point:CGPointMake(510, 400) time:t + 0.05 touchSubtype:YES ageSinceTouch:&age] == MLTouchGateVerdictPass);
        t += 0.4;
    }
    CHECK(g.passedClickCount == 50 && g.droppedCount == 0);

    // A real screen touch, then a trackpad press 3 s later: the press is the user's.
    [g noteTouchPoint:CGPointMake(300, 300) active:YES time:200.0];
    [g noteAllTouchesUpAtTime:200.2];
    CHECK([g verdictForMouseKind:MLTouchGateMouseDown button:0 point:CGPointMake(700, 500) time:203.2 touchSubtype:YES ageSinceTouch:&age] == MLTouchGateVerdictPass);
    [g verdictForMouseKind:MLTouchGateMouseUp button:0 point:CGPointMake(700, 500) time:203.25 touchSubtype:YES ageSinceTouch:&age];
    // The click the system made from that touch (0.1 s after it ended) is still dropped, and counted by kind.
    [g reset];
    [g noteTouchPoint:CGPointMake(300, 300) active:YES time:300.0];
    [g noteAllTouchesUpAtTime:300.2];
    CHECK([g verdictForMouseKind:MLTouchGateMouseDown button:0 point:CGPointMake(300, 300) time:300.3 touchSubtype:YES ageSinceTouch:&age] == MLTouchGateVerdictDropSubtype);
    CHECK([g verdictForMouseKind:MLTouchGateMouseUp button:0 point:CGPointMake(300, 300) time:300.35 touchSubtype:YES ageSinceTouch:&age] == MLTouchGateVerdictDropSequence);
    CHECK(g.droppedSubtypeCount == 1 && g.droppedSequenceCount == 1);

    // Touch Mac, stream window not key: the activating touch's click is the system's, the recognizer never saw it.
    [g reset];
    g.subtypeAlwaysDrops = MLTouchSubtypeBelievedWithoutTouch(YES, NO);
    CHECK([g verdictForMouseKind:MLTouchGateMouseDown button:0 point:CGPointMake(10, 10) time:400 touchSubtype:YES ageSinceTouch:&age] == MLTouchGateVerdictDropSubtype);
    [g verdictForMouseKind:MLTouchGateMouseUp button:0 point:CGPointMake(10, 10) time:400.1 touchSubtype:YES ageSinceTouch:&age];
    // A mouse event without the subtype is a real mouse whatever the flag says.
    CHECK([g verdictForMouseKind:MLTouchGateMouseDown button:0 point:CGPointMake(10, 10) time:401 touchSubtype:NO ageSinceTouch:&age] == MLTouchGateVerdictPass);
}

int main(void) {
    @autoreleasepool {
        testModeSelection();
        testVideoRectAndNormalize();
        testPointerTable();
        testForwarder();
        testTrackpadEmulator();
        testDirectEmulator();
        testMouseGate();
        testTrackpadClicksReachHost();
        testFiveFingerHold();
        testHoldCancelsHostTouches();
    }
    printf("%d checks, %d failed\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
