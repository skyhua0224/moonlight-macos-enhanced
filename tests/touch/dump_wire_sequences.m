// Writes the wire events the production forwarder (MLTouchForwarder) produces for 1..10 finger gestures, one event
// per line, for the host-side replay (host-replay/replay.cpp, which feeds them to Sunshine's own touch_update).
//
//   scenario <name>
//   E <type> <pointerId> <x> <y>      type is the LI_TOUCH_EVENT_* value
//   end
//
// usage: dump_wire_sequences <out.txt>

#import <Foundation/Foundation.h>
#import "MLTouchCore.h"

static FILE *g_out;
static MLTouchForwarder *g_fwd;
static NSTimeInterval g_t;

static void begin(NSString *name) {
    fprintf(g_out, "scenario %s\n", name.UTF8String);
    g_fwd = [[MLTouchForwarder alloc] init];
    g_fwd.viewSize = CGSizeMake(1600, 900);
    g_fwd.videoSize = CGSizeMake(1920, 1080);
    g_fwd.sink = ^(MLTouchWireEvent e, uint32_t pid, float x, float y) {
        fprintf(g_out, "E %u %u %.6f %.6f\n", (unsigned)e, pid, x, y);
    };
    g_t = 0;
}
static void finish(void) { fprintf(g_out, "end\n"); }

static NSString *F(int i) { return [NSString stringWithFormat:@"f%d", i]; }
static MLTouchSample *S(NSString *id_, MLTouchPhase ph, CGFloat x, CGFloat y) {
    g_t += 0.008;
    return [MLTouchSample sampleWithIdentity:id_ phase:ph point:CGPointMake(x, y) timestamp:g_t];
}
static CGPoint at(int i, int step) { return CGPointMake(100 + i * 140 + step * 3, 200 + i * 40 + step * 2); }

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    @autoreleasepool {
        g_out = fopen(argv[1], "w");
        if (!g_out) return 2;
        for (int n = 1; n <= 10; n++) {
            // A: fingers land one after the other (separate events), all move, lift in the order they landed.
            begin([NSString stringWithFormat:@"%dfinger-staggered-up-in-order", n]);
            for (int i = 0; i < n; i++) { CGPoint p = at(i, 0); [g_fwd processSamples:@[S(F(i), MLTouchPhaseBegan, p.x, p.y)]]; }
            for (int step = 1; step <= 5; step++) {
                NSMutableArray *batch = [NSMutableArray array];
                for (int i = 0; i < n; i++) { CGPoint p = at(i, step); [batch addObject:S(F(i), MLTouchPhaseMoved, p.x, p.y)]; }
                [g_fwd processSamples:batch];
            }
            for (int i = 0; i < n; i++) { CGPoint p = at(i, 5); [g_fwd processSamples:@[S(F(i), MLTouchPhaseEnded, p.x, p.y)]]; }
            finish();

            // B: all land in one event, lift in reverse order, each in its own event.
            begin([NSString stringWithFormat:@"%dfinger-simultaneous-up-reversed", n]);
            NSMutableArray *down = [NSMutableArray array];
            for (int i = 0; i < n; i++) { CGPoint p = at(i, 0); [down addObject:S(F(i), MLTouchPhaseBegan, p.x, p.y)]; }
            [g_fwd processSamples:down];
            for (int step = 1; step <= 3; step++) {
                NSMutableArray *batch = [NSMutableArray array];
                for (int i = n - 1; i >= 0; i--) { CGPoint p = at(i, step); [batch addObject:S(F(i), MLTouchPhaseMoved, p.x, p.y)]; }
                [g_fwd processSamples:batch];
            }
            for (int i = n - 1; i >= 0; i--) { CGPoint p = at(i, 3); [g_fwd processSamples:@[S(F(i), MLTouchPhaseEnded, p.x, p.y)]]; }
            finish();

            // C: all land and all lift inside single events (a quick multi-finger tap).
            begin([NSString stringWithFormat:@"%dfinger-tap-single-events", n]);
            [g_fwd processSamples:down];
            NSMutableArray *up = [NSMutableArray array];
            for (int i = 0; i < n; i++) { CGPoint p = at(i, 0); [up addObject:S(F(i), MLTouchPhaseEnded, p.x, p.y)]; }
            [g_fwd processSamples:up];
            finish();

            // D: the same gesture twice in a row: every id is reused the moment it is released.
            begin([NSString stringWithFormat:@"%dfinger-twice-id-reuse", n]);
            for (int round = 0; round < 2; round++) {
                NSMutableArray *d = [NSMutableArray array], *u = [NSMutableArray array];
                for (int i = 0; i < n; i++) { CGPoint p = at(i, 0); [d addObject:S([NSString stringWithFormat:@"r%d-%d", round, i], MLTouchPhaseBegan, p.x, p.y)]; }
                for (int i = 0; i < n; i++) { CGPoint p = at(i, 0); [u addObject:S([NSString stringWithFormat:@"r%d-%d", round, i], MLTouchPhaseEnded, p.x, p.y)]; }
                [g_fwd processSamples:d];
                [g_fwd processSamples:u];
            }
            finish();
        }

        // E: churn with ten fingers: random lands, moves and lifts (a fixed sequence), then everything cancelled.
        begin(@"churn-10-fingers-with-reuse-and-cancel-all");
        uint32_t seed = 12345;
        BOOL live[64] = {0};
        int count = 0, next = 0;
        for (int step = 0; step < 600; step++) {
            seed = seed * 1664525u + 1013904223u;
            int roll = (seed >> 16) % 10;
            if ((roll < 4 || count == 0) && count < 12) {
                CGPoint p = at(next % 10, step % 7);
                [g_fwd processSamples:@[S(F(next), MLTouchPhaseBegan, p.x, p.y)]];
                live[next % 64] = YES; next++; count++;
            } else if (roll < 8) {
                for (int i = next - 1; i >= 0 && i > next - 14; i--) if (live[i % 64]) {
                    CGPoint p = at(i % 10, step % 9);
                    [g_fwd processSamples:@[S(F(i), MLTouchPhaseMoved, p.x, p.y)]];
                    break;
                }
            } else {
                for (int i = 0; i < next; i++) if (live[i % 64]) {
                    CGPoint p = at(i % 10, step % 9);
                    [g_fwd processSamples:@[S(F(i), (seed & 1) ? MLTouchPhaseEnded : MLTouchPhaseCancelled, p.x, p.y)]];
                    live[i % 64] = NO; count--;
                    break;
                }
            }
        }
        [g_fwd cancelAll];
        finish();

        // F: the focus is lost with fingers down.
        begin(@"5-fingers-then-cancel-all");
        for (int i = 0; i < 5; i++) { CGPoint p = at(i, 0); [g_fwd processSamples:@[S(F(i), MLTouchPhaseBegan, p.x, p.y)]]; }
        [g_fwd cancelAll];
        finish();
        fclose(g_out);
    }
    return 0;
}
