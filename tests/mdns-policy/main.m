// tests/mdns-policy: when MDNSManager asks Bonjour. Compiles the real MDNSManager.m with a fake browser; the app's
// Swift/Core Data neighbours are stubbed in stubs/.
#import <AppKit/AppKit.h>
#import "MDNSManager.h"
#import "MoonlightEnhanced-Swift.h"

static int failures = 0;
static void check(NSString *name, BOOL ok) {
    printf("%s %s\n", ok ? "ok  " : "FAIL", name.UTF8String);
    if (!ok) failures++;
}
static void pump(NSTimeInterval seconds) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

// Counts what would have gone to the network.
static NSUInteger gBrowsersMade, gSearches, gStops;

@interface FakeBrowser : NSNetServiceBrowser
@end
@implementation FakeBrowser
- (void)searchForServicesOfType:(NSString *)type inDomain:(NSString *)domainString { gSearches++; }
- (void)stop { gStops++; }
@end

// Restarts every 50 ms instead of every 5 s, so the schedule can be watched.
@interface TestManager : MDNSManager
@end
@implementation TestManager
- (NSNetServiceBrowser *)makeBrowser { gBrowsersMade++; return [[FakeBrowser alloc] init]; }
- (NSTimeInterval)restartIntervalForRound:(NSUInteger)round { return 0.05; }
@end

// The real schedule, only the browser is fake.
@interface RealScheduleManager : MDNSManager
@end
@implementation RealScheduleManager
- (NSNetServiceBrowser *)makeBrowser { gBrowsersMade++; return [[FakeBrowser alloc] init]; }
@end

static BOOL gForeground;

static NSUserDefaults *freshDefaults(BOOL autoDiscover, BOOL stored) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"mdns-policy-test"];
    [d removePersistentDomainForName:@"mdns-policy-test"];
    if (stored) [d setBool:autoDiscover forKey:@"autoDiscoverNewHosts"];
    return d;
}

static TestManager *makeManager(NSUserDefaults *defaults, Class cls) {
    gBrowsersMade = gSearches = gStops = 0;
    TestManager *m = [[cls alloc] initWithCallback:nil];
    m.defaults = defaults;
    m.foregroundProvider = ^BOOL { return gForeground; };
    return m;
}

int main(void) {
    @autoreleasepool {
        // --- the schedule (RFC 6762 5.2: back off by doubling)
        NSMutableArray *iv = [NSMutableArray array];
        for (NSUInteger r = 0; r < 12; r++) [iv addObject:@([MDNSManager restartIntervalForRound:r])];
        check(@"schedule: 5 s for six rounds, then 10 20 40 60 60 ...",
              [iv isEqualToArray:@[@5, @5, @5, @5, @5, @5, @10, @20, @40, @60, @60, @60]]);
        check(@"schedule: never above 60 s, also for a huge round", [MDNSManager restartIntervalForRound:NSUIntegerMax] == 60.0);

        // --- switch off: Bonjour is not even created
        gForeground = YES;
        MLNetworkQuiet.isQuiet = NO;
        {
            TestManager *m = makeManager(freshDefaults(NO, YES), [TestManager class]);
            [m searchForHosts];
            pump(0.4);
            check(@"off: no browser is made", gBrowsersMade == 0);
            check(@"off: no query is sent in 0.4 s (8 rounds of the test schedule)", gSearches == 0);
            check(@"off: searchRunning is NO", !m.searchRunning);
            [m stopSearching];
            check(@"off: stop on a manager that never ran does not touch Bonjour", gStops == 0);
        }

        // --- switch on, host list in front: it searches and restarts on the schedule
        {
            NSUserDefaults *d = freshDefaults(YES, NO);   // no stored value means on
            TestManager *m = makeManager(d, [TestManager class]);
            [m searchForHosts];
            check(@"on: first query at once", gSearches == 1 && m.searchRunning);
            pump(0.4);
            check(@"on: restarts follow the schedule", gSearches >= 5);

            // --- the switch is turned off while it runs: stops now, no restart of the app
            [d setBool:NO forKey:@"autoDiscoverNewHosts"];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"MoonlightDiscoveryPreferencesChanged" object:nil];
            pump(0.05);
            NSUInteger after = gSearches;
            check(@"switch off: searchRunning drops", !m.searchRunning);
            check(@"switch off: the browser is stopped", gStops >= 1);
            pump(0.4);
            check(@"switch off: no query afterwards", gSearches == after);

            // --- and on again
            [d setBool:YES forKey:@"autoDiscoverNewHosts"];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"MoonlightDiscoveryPreferencesChanged" object:nil];
            pump(0.05);
            check(@"switch on again: searches again without a restart", m.searchRunning && gSearches > after);

            // --- the window goes away: no restart every 5 s any more
            gForeground = NO;
            [m refreshSearchPolicy];
            NSUInteger hidden = gSearches;
            check(@"window hidden: searchRunning drops", !m.searchRunning);
            pump(0.4);
            check(@"window hidden: no restarts", gSearches == hidden);
            gForeground = YES;
            [[NSNotificationCenter defaultCenter] postNotificationName:NSApplicationDidBecomeActiveNotification object:nil];
            pump(0.05);
            check(@"window back: searches at once and restarts", m.searchRunning && gSearches > hidden);

            // --- a stream or launch owns the network: the quiet hook stops the browser at once, not at the next round
            NSUInteger stopsBeforeQuiet = gStops;
            MLNetworkQuiet.isQuiet = YES;
            [MLNetworkQuiet fireQuiet];
            pump(0.01);
            check(@"stream: the quiet hook stops the browser at once", gStops > stopsBeforeQuiet);
            pump(0.11);
            NSUInteger quietAt = gSearches;
            pump(0.4);
            check(@"stream: no query while the app is quiet", gSearches == quietAt);
            MLNetworkQuiet.isQuiet = NO;
            pump(0.2);
            check(@"stream over: queries resume", gSearches > quietAt);

            // --- discovery stopped (hosts page gone, pairing)
            [m stopSearching];
            NSUInteger stopped = gSearches;
            pump(0.4);
            check(@"stopSearching: no restarts", gSearches == stopped && !m.searchRunning);
        }

        // --- the real schedule: one query, then nothing for seconds (the old code restarted every 5 s; the first
        //     restart now is at 5 s, never sooner)
        {
            TestManager *m = makeManager(freshDefaults(YES, NO), [RealScheduleManager class]);
            [m searchForHosts];
            pump(1.5);
            check(@"real schedule: one query in the first 1.5 s", gSearches == 1);
            [m stopSearching];
        }
    }
    printf(failures ? "%d FAILED\n" : "all passed\n", failures);
    return failures ? 1 : 0;
}
