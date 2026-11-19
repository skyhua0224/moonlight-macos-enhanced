// A/B of the free-mouse virtual cursor: what the host sees, frame by frame.
//  stale  : reconcile against the location stored in the AppKit event (rc.7)
//  live   : reconcile against the pointer as it is when the main thread runs (master)
//  glide  : live pointer, the correction is paid out over the next raw events instead of being a step
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "FreeMouseVirtualCursor.h"
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#define N 20000   // ms
static MLFreeMousePoint truth[N], rawm[N];
static unsigned long long rs = 88172645463325252ULL;
static double rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return (rs >> 11) * (1.0 / 9007199254740992.0); }
static double gainAt(double speed) { // pointer view points per raw view point, macOS-like: grows with speed
    double s = speed / 1000.0; return 0.75 * (1.0 + 0.9 * (1.0 - exp(-s * 0.9)) * 1.0 + 0.5 * fmin(s, 4.0) * 0.2);
}
static void genPath(void) {
    double t = 0, x = 500, y = 400; int i = 0;
    while (i < N - 1) {
        double tx = 80 + rnd() * 840, ty = 60 + rnd() * 680;
        int dur = 90 + (int)(rnd() * 360), pause = (int)(rnd() * 250);
        if (rnd() < 0.25) { tx = x + (rnd() - 0.5) * 60; ty = y + (rnd() - 0.5) * 60; dur = 300 + (int)(rnd() * 500); } // slow small move
        for (int k = 0; k < dur && i < N - 1; k++, i++) {
            double u = (double)k / dur, s = u * u * u * (10 - 15 * u + 6 * u * u);
            truth[i] = (MLFreeMousePoint){x + (tx - x) * s, y + (ty - y) * s};
        }
        x = tx; y = ty;
        for (int k = 0; k < pause && i < N - 1; k++, i++) truth[i] = (MLFreeMousePoint){x, y};
    }
    truth[N - 1] = truth[N - 2];
    rawm[0] = (MLFreeMousePoint){0, 0};
    for (int i = 1; i < N; i++) {
        double dx = truth[i].x - truth[i - 1].x, dy = truth[i].y - truth[i - 1].y, sp = hypot(dx, dy) / 0.001;
        double g = gainAt(sp);
        rawm[i] = (MLFreeMousePoint){dx / g, dy / g};
    }
}
typedef struct { double jerkRms, jerkTruth, p95Lag, reversals, spikes; int corrections; } Out;
static MLFreeMousePoint at(const MLFreeMousePoint *a, int i) { if (i < 0) i = 0; if (i >= N) i = N - 1; return a[i]; }
// mode 0 stale, 1 live, 2 glide
static Out run(int mode, double evHz, int ageMs, int ptrLagMs, int frameHz) {
    MLFreeMouseVirtualCursor c; MLFreeMouseVirtualCursorReset(&c);
    MLFreeMouseVirtualCursorAnchor(&c, truth[0], 1000, 800, true);
    static MLFreeMousePoint sentAt[N]; MLFreeMousePoint sent = truth[0];
    double debtX = 0, debtY = 0; int corr = 0;
    int evPeriod = (int)(1000.0 / evHz + 0.5); if (evPeriod < 1) evPeriod = 1;
    int created[N / 4], deliver[N / 4], head = 0, tail = 0;
    for (int i = 1; i < N; i++) {
        MLFreeMousePoint p = MLFreeMouseVirtualCursorAdvance(&c, rawm[i].x * 0.75, rawm[i].y * 0.75, 1000, 800);
        if (mode == 2) { double k = 1.0 - exp(-1.0 / 22.0); double tx = debtX * k, ty = debtY * k; debtX -= tx; debtY -= ty; c.point.x += tx; c.point.y += ty; p = c.point; }
        sent = p;
        if (i % evPeriod == 0) { created[tail] = i; deliver[tail] = i + ageMs; tail++; }
        while (head < tail && deliver[head] <= i) {
            int src = (mode == 0) ? created[head] : i; head++;
            MLFreeMousePoint ptr = at(truth, src - ptrLagMs);
            if (mode == 2) {
                // the cursor's believed position is where it will end up once the debt is paid
                MLFreeMousePoint est = {c.point.x + debtX, c.point.y + debtY};
                MLFreeMousePoint hold = c.point; c.point = est;
                double drift; bool corrected = MLFreeMouseVirtualCursorReconcile(&c, ptr, 1000, 800, true, 1.5, &drift);
                if (corrected && drift < 120.0) { debtX = c.point.x - hold.x; debtY = c.point.y - hold.y; c.point = hold; corr++; }
                else if (corrected) { debtX = debtY = 0; sent = c.point; corr++; }
                else { debtX = c.point.x - hold.x; debtY = c.point.y - hold.y; c.point = hold; }
            } else {
                if (MLFreeMouseVirtualCursorReconcile(&c, ptr, 1000, 800, true, 1.5, NULL)) { sent = c.point; corr++; }
            }
        }
        sentAt[i] = sent;
    }
    sentAt[0] = truth[0];
    // frames
    int step = 1000 / frameHz; int nf = N / step; double sj = 0, tj = 0; int n2 = 0, rev = 0, spikes = 0; static double lag[N]; int nl = 0;
    for (int f = 2; f < nf - 2; f++) {
        MLFreeMousePoint a = sentAt[(f - 2) * step], b = sentAt[(f - 1) * step], d = sentAt[f * step];
        MLFreeMousePoint ta = truth[(f - 2) * step], tb = truth[(f - 1) * step], td = truth[f * step];
        double jx = d.x - 2 * b.x + a.x, jy = d.y - 2 * b.y + a.y, tjx = td.x - 2 * tb.x + ta.x, tjy = td.y - 2 * tb.y + ta.y;
        double jr = hypot(jx, jy), tjr = hypot(tjx, tjy);
        if (hypot(td.x - tb.x, td.y - tb.y) < 0.5 && hypot(tb.x - ta.x, tb.y - ta.y) < 0.5) { /* truth at rest */ }
        sj += jr * jr; tj += tjr * tjr; n2++;
        double ex = hypot(jx - tjx, jy - tjy); if (ex > 8.0) spikes++;
        double s1x = d.x - b.x, s1y = d.y - b.y, s0x = b.x - a.x, s0y = b.y - a.y;
        double ts = hypot(td.x - tb.x, td.y - tb.y);
        if (ts > 3.0 && (s1x * s0x + s1y * s0y) < 0 && hypot(s1x, s1y) > 1.0 && hypot(s0x, s0y) > 1.0) rev++;
        lag[nl++] = hypot(d.x - td.x, d.y - td.y);
    }
    // p95
    for (int i = 0; i < nl; i++) for (int j = i + 1; j < nl; j++) if (0) {}
    int cmp(const void *x, const void *y) { double u = *(const double *)x, v = *(const double *)y; return u < v ? -1 : u > v; }
    qsort(lag, nl, sizeof(double), cmp);
    Out o = {sqrt(sj / n2), sqrt(tj / n2), lag[(int)(nl * 0.95)], rev, spikes, corr};
    return o;
}
int main(int argc, char **argv) {
    genPath();
    int frameHz = 60;
    printf("frame %d Hz. jerk = RMS of the host cursor's second difference per frame (view points; the pointer itself: see 'truth').\n", frameHz);
    printf("%-26s %-7s %8s %8s %8s %8s %6s\n", "case(evHz/age/ptrLag)", "alg", "jerk", "truth", "reverse", "spikes>8", "p95lag");
    double cases[][3] = {{125,0,0},{125,16,0},{60,16,0},{60,16,4},{60,16,8},{40,17,4},{60,33,4},{125,16,8}};
    const char *nm[] = {"rc.7 stale", "master live", "glide"};
    for (int k = 0; k < 8; k++) for (int m = 0; m < 3; m++) {
        Out o = run(m, cases[k][0], (int)cases[k][1], (int)cases[k][2], frameHz);
        char buf[64]; snprintf(buf, sizeof buf, "%.0f/%.0f/%.0f", cases[k][0], cases[k][1], cases[k][2]);
        printf("%-26s %-12s %8.2f %8.2f %8.0f %8.0f %6.1f  corr=%d\n", buf, nm[m], o.jerkRms, o.jerkTruth, o.reversals, o.spikes, o.p95Lag, o.corrections);
    }
    return 0;
}
