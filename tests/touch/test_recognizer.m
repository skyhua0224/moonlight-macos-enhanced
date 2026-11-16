// Recognizer tests: the production MLDirectTouchRecognizer driven by fake direct touches.
//
// Real direct touches cannot be produced without touch hardware: AppKit builds NSTouch/NSEvent touch sets
// from digitizer data through private SPI. What is exercised here is everything this code does with a touch
// set: the state machine it drives (claim on the first accepted touch, Changed, Ended, Cancelled, Failed for an
// overlay), the filtering of touches that land on a control, the samples it emits, and its refusal to
// take part in mouse sequences or be prevented. The fakes are NSTouch subclasses and an event that answers
// touchesMatchingPhase:inView:, which is all the recognizer asks of an event.

#import <Cocoa/Cocoa.h>
#import "MLDirectTouchRecognizer.h"

static int g_failures = 0, g_checks = 0;
#define CHECK(...) do { g_checks++; if (!(__VA_ARGS__)) { g_failures++; \
    fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, #__VA_ARGS__); } } while (0)

@interface FakeTouch : NSTouch
@property (nonatomic, strong) id<NSObject, NSCopying> fakeIdentity;
@property (nonatomic) NSTouchPhase fakePhase;
@property (nonatomic) NSPoint fakePoint;
@property (nonatomic) NSTouchType fakeType;
@end
@implementation FakeTouch
- (id<NSObject, NSCopying>)identity { return self.fakeIdentity; }
- (NSTouchPhase)phase { return self.fakePhase; }
- (NSTouchType)type { return self.fakeType; }
- (NSPoint)locationInView:(NSView *)view { return self.fakePoint; }
@end

@interface FakeEvent : NSObject
@property (nonatomic, copy) NSSet<NSTouch *> *touches;
@property (nonatomic) NSTimeInterval fakeTimestamp;
@end
@implementation FakeEvent
- (NSSet<NSTouch *> *)touchesMatchingPhase:(NSTouchPhase)phase inView:(NSView *)view { return self.touches; }
- (NSTimeInterval)timestamp { return self.fakeTimestamp; }
@end

static FakeTouch *T(NSString *ident, NSTouchPhase phase, CGFloat x, CGFloat y) {
    FakeTouch *t = [[FakeTouch alloc] init];
    t.fakeIdentity = ident; t.fakePhase = phase; t.fakePoint = NSMakePoint(x, y); t.fakeType = NSTouchTypeDirect;
    return t;
}
static FakeEvent *E(NSTimeInterval ts, NSArray<NSTouch *> *touches) {
    FakeEvent *e = [[FakeEvent alloc] init];
    e.touches = [NSSet setWithArray:touches];
    e.fakeTimestamp = ts;
    return e;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
        MLDirectTouchRecognizer *r = [[MLDirectTouchRecognizer alloc] initWithTarget:nil action:nil];
        [view addGestureRecognizer:r];

        // Direct touches only, and nothing may stop it.
        CHECK(r.allowedTouchTypes == NSTouchTypeMaskDirect);
        CHECK(r.buttonMask == 0);
        CHECK(![r canBePreventedByGestureRecognizer:[[NSPressGestureRecognizer alloc] init]]);
        CHECK([r canPreventGestureRecognizer:[[NSPressGestureRecognizer alloc] init]]);

        NSMutableArray<MLTouchSample *> *got = [NSMutableArray array];
        NSMutableArray<NSNumber *> *downCounts = [NSMutableArray array];
        NSMutableArray<MLTouchSample *> *all = [NSMutableArray array];
        r.samplesHandler = ^(NSArray<MLTouchSample *> *s) { [got addObjectsFromArray:s]; };
        r.allSamplesHandler = ^(NSArray<MLTouchSample *> *s, NSUInteger down) { [all addObjectsFromArray:s]; [downCounts addObject:@(down)]; };
        __block NSPoint rejectBelow = NSMakePoint(-1, -1);   // y below this belongs to a control
        r.acceptsTouchAtPoint = ^BOOL(NSPoint p) { return p.y >= rejectBelow.y; };

        // Two fingers land: both reported, the recognizer claims them.
        CHECK(r.lastRequestedState == NSGestureRecognizerStatePossible);
        [r touchesBeganWithEvent:(NSEvent *)E(1.0, @[T(@"a", NSTouchPhaseBegan, 100, 100), T(@"b", NSTouchPhaseBegan, 300, 120)])];
        CHECK(r.lastRequestedState == NSGestureRecognizerStateBegan);
        CHECK(got.count == 2 && got[0].phase == MLTouchPhaseBegan && got[1].phase == MLTouchPhaseBegan);
        CHECK(r.activeTouchCount == 2);
        CHECK(all.count == 2 && [downCounts.lastObject unsignedIntegerValue] == 2);

        // Moves keep it going; the position comes through in the view's coordinates.
        [got removeAllObjects];
        [r touchesMovedWithEvent:(NSEvent *)E(1.1, @[T(@"a", NSTouchPhaseMoved, 110, 105), T(@"b", NSTouchPhaseStationary, 300, 120)])];
        CHECK(r.lastRequestedState == NSGestureRecognizerStateChanged);
        CHECK(got.count == 2);
        for (MLTouchSample *s in got) {
            if ([s.identity isEqual:@"a"]) { CHECK(s.phase == MLTouchPhaseMoved && s.point.x == 110 && s.point.y == 105); }
            else { CHECK(s.phase == MLTouchPhaseStationary); }
        }

        // One finger up: still claimed.
        [got removeAllObjects];
        [r touchesEndedWithEvent:(NSEvent *)E(1.2, @[T(@"a", NSTouchPhaseEnded, 110, 105)])];
        CHECK(r.lastRequestedState == NSGestureRecognizerStateChanged);
        CHECK(got.count == 1 && got[0].phase == MLTouchPhaseEnded);
        CHECK(r.activeTouchCount == 1);

        // The last one up ends the gesture.
        [r touchesEndedWithEvent:(NSEvent *)E(1.3, @[T(@"b", NSTouchPhaseEnded, 300, 120)])];
        CHECK(r.lastRequestedState == NSGestureRecognizerStateEnded);
        CHECK(r.activeTouchCount == 0);
        CHECK([downCounts.lastObject unsignedIntegerValue] == 0);
        [r reset];
        CHECK(r.activeTouchCount == 0);

        // A cancelled touch set cancels the gesture.
        [got removeAllObjects];
        [r touchesBeganWithEvent:(NSEvent *)E(2.0, @[T(@"c", NSTouchPhaseBegan, 200, 200)])];
        CHECK(r.lastRequestedState == NSGestureRecognizerStateBegan);
        [r touchesCancelledWithEvent:(NSEvent *)E(2.1, @[T(@"c", NSTouchPhaseCancelled, 200, 200)])];
        CHECK(r.lastRequestedState == NSGestureRecognizerStateCancelled);
        CHECK(got.count == 2 && got[1].phase == MLTouchPhaseCancelled);
        [r reset];

        // A touch that lands on a control (the filter says no) is not reported and not claimed: the recognizer steps aside.
        [got removeAllObjects];
        rejectBelow = NSMakePoint(0, 50);
        [r touchesBeganWithEvent:(NSEvent *)E(3.0, @[T(@"ui", NSTouchPhaseBegan, 40, 10)])];
        CHECK(r.lastRequestedState == NSGestureRecognizerStateFailed);
        CHECK(got.count == 0 && r.activeTouchCount == 0);
        CHECK(all.count > 0);   // the observers (debug overlay, mouse gate) still hear of it
        [r reset];

        // A second finger on the picture while the first is on a control: the first stays rejected for its whole life.
        [r touchesBeganWithEvent:(NSEvent *)E(4.0, @[T(@"ui2", NSTouchPhaseBegan, 40, 10), T(@"pic", NSTouchPhaseBegan, 400, 300)])];
        CHECK(r.lastRequestedState == NSGestureRecognizerStateBegan);
        CHECK(got.count == 1 && [got[0].identity isEqual:@"pic"]);
        [got removeAllObjects];
        [r touchesMovedWithEvent:(NSEvent *)E(4.1, @[T(@"ui2", NSTouchPhaseMoved, 400, 300), T(@"pic", NSTouchPhaseMoved, 410, 300)])];
        CHECK(got.count == 1 && [got[0].identity isEqual:@"pic"]);   // sliding off the control does not turn it into a stream touch
        [r touchesEndedWithEvent:(NSEvent *)E(4.2, @[T(@"ui2", NSTouchPhaseEnded, 400, 300), T(@"pic", NSTouchPhaseEnded, 410, 300)])];
        CHECK(r.lastRequestedState == NSGestureRecognizerStateEnded);
        [r reset];

        // A touch first seen mid-life is treated as a start; an end for something never seen is nothing.
        [got removeAllObjects];
        rejectBelow = NSMakePoint(-1, -1);
        [r touchesMovedWithEvent:(NSEvent *)E(5.0, @[T(@"late", NSTouchPhaseMoved, 50, 50)])];
        CHECK(got.count == 1 && got[0].phase == MLTouchPhaseBegan);
        [r touchesEndedWithEvent:(NSEvent *)E(5.1, @[T(@"late", NSTouchPhaseEnded, 50, 50), T(@"ghost", NSTouchPhaseEnded, 1, 1)])];
        CHECK(got.count == 2 && got[1].phase == MLTouchPhaseEnded);
        [r reset];

        // Indirect (trackpad) touches are not this recognizer's.
        [got removeAllObjects];
        FakeTouch *indirect = T(@"pad", NSTouchPhaseBegan, 10, 10);
        indirect.fakeType = NSTouchTypeIndirect;
        [r touchesBeganWithEvent:(NSEvent *)E(6.0, @[indirect])];
        CHECK(got.count == 0 && r.lastRequestedState == NSGestureRecognizerStatePossible);

        // A mouse sequence on the view is not its business.
        NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(5, 5) modifierFlags:0
                                          timestamp:7.0 windowNumber:0 context:nil eventNumber:1 clickCount:1 pressure:1];
        [r mouseDown:down];
        CHECK(r.lastRequestedState == NSGestureRecognizerStateFailed);
        [r reset];

        // Forgetting drops tracking without reporting.
        [got removeAllObjects];
        [r touchesBeganWithEvent:(NSEvent *)E(8.0, @[T(@"z", NSTouchPhaseBegan, 5, 5)])];
        [r forgetAllTouches];
        CHECK(r.activeTouchCount == 0);
    }
    printf("%d checks, %d failed\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
