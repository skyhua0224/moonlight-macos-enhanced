#ifdef MLC_CONCEPT_HARNESS
//
//  ConceptHarness.m
//
#import "ConceptHarness.h"
#import "TemporaryHost.h"
#import "TemporaryApp.h"
#import "DataManager.h"
#import "ConnectionEndpointStore.h"
#import "AppAssetManager.h"
#import "Helpers.h"
#import "HttpManager.h"
#import "HttpRequest.h"
#import "HttpResponse.h"
#import "StreamOverlayLegacy.h"
#import "StreamViewController_Internal.h"
#import "MoonlightEnhanced-Swift.h"
#import "ControllerNavigation.h"
#import "DS5UIButtons.h"
#import <objc/runtime.h>
#import <dlfcn.h>

static NSString *const kSandbox = @"/tmp/apps-concept/";
static NSWindow *sOverlayWindow;
static NSWindowController *sSettingsWindowController;

// A stand-in stream view: a frame (aspect fill) and, when simulating a notched display, the camera housing.
@interface MLCFrameView : NSView
@property (nonatomic, strong) NSImage *frameImage;
@property (nonatomic) CGFloat notchWidth;
@property (nonatomic) CGFloat notchHeight;
@end
@implementation MLCFrameView
- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds;
    if (self.frameImage != nil) {
        NSSize s = self.frameImage.size;
        CGFloat scale = MAX(b.size.width / s.width, b.size.height / s.height);
        NSRect r = NSMakeRect(0, 0, s.width * scale, s.height * scale);
        r.origin.x = (b.size.width - r.size.width) / 2; r.origin.y = (b.size.height - r.size.height) / 2;
        [self.frameImage drawInRect:r];
    }
    if (self.notchWidth > 0) {
        // Simulated camera housing: black, square top, rounded bottom corners.
        NSRect n = NSMakeRect((b.size.width - self.notchWidth) / 2, b.size.height - self.notchHeight, self.notchWidth, self.notchHeight);
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(n, 0, -12) xRadius:12 yRadius:12];
        [[NSColor blackColor] setFill];
        [path fill];
    }
}
@end

typedef CGImageRef (*MLCWindowListCreateImage)(CGRect, uint32_t, uint32_t, uint32_t);
typedef CGImageRef (*MLCWindowListCreateImageFromArray)(CGRect, CFArrayRef, uint32_t);

// A mock host: everything the design needs that the client can know or will be able to record.
static NSArray<NSDictionary *> *MockHosts(void) {
    static NSArray *hosts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *win = @[@"desktop", @"steam", @"genshin", @"hsr", @"zzz", @"cyberpunk", @"eldenring", @"forza", @"hades", @"bg3", @"resolve", @"blender"];
        NSArray *mac = @[@"desktop", @"resolve", @"blender", @"hollow", @"stardew"];
        NSArray *lin = @[@"desktop", @"steam", @"hollow", @"stardew", @"hades"];
        int now = 0; (void)now;
        hosts = @[
            @{@"uuid": @"0A11-GAMINGPC-LIVE", @"name": @"Gaming PC", @"local": @"10.100.0.133", @"mac": @"00:00:5e:00:53:01",
              @"paired": @YES, @"state": @(StateOnline), @"rtt": @1, @"codec": @(0x1|0x100|0x200|0x10000|0x20000),
              @"platform": @"windows", @"apps": [win arrayByAddingObject:@"bigscreen"], @"current": @"3", @"lastApp": @"genshin", @"recents": @[@"genshin", @"hsr", @"steam", @"zzz"],
              @"lastConnected": @(-3600*3), @"lastSeen": @0},
            @{@"uuid": @"0B22-MACMINI", @"name": @"Mac mini", @"local": @"10.100.0.220", @"mac": @"00:00:5e:00:53:02",
              @"paired": @YES, @"state": @(StateOnline), @"rtt": @2, @"codec": @(0x1|0x100|0x200),
              @"platform": @"macos", @"apps": mac, @"current": @"0", @"lastApp": @"resolve", @"recents": @[@"resolve", @"blender"],
              @"lastConnected": @(-86400*2), @"lastSeen": @0},
            @{@"uuid": @"0C33-LINUXPC", @"name": @"Linux PC", @"local": @"10.100.0.210", @"mac": @"00:00:5e:00:53:03",
              @"paired": @NO, @"state": @(StateOnline), @"rtt": @1, @"codec": @(0x1|0x100|0x10000),
              @"platform": @"linux", @"apps": lin, @"current": @"0", @"recents": @[],
              @"lastConnected": @0, @"lastSeen": @0},
            @{@"uuid": @"0D44-ALIENWARE", @"name": @"Alienware", @"external": @"203.0.113.40", @"mac": @"00:00:5e:00:53:04",
              @"paired": @YES, @"state": @(StateOnline), @"rtt": @38, @"codec": @(0x1|0x100|0x200|0x10000),
              @"platform": @"windows", @"apps": @[@"desktop", @"steam", @"eldenring", @"forza", @"bg3"], @"current": @"7", @"lastApp": @"eldenring",
              @"recents": @[@"eldenring", @"bg3"], @"lastConnected": @(-86400*6), @"lastSeen": @0},
            @{@"uuid": @"0E56-GARAGE", @"name": @"Garage PC", @"local": @"10.100.0.91",
              @"paired": @YES, @"state": @(StateOffline), @"rtt": @(-1), @"codec": @(0x1|0x100|0x200),
              @"platform": @"windows", @"apps": @[@"desktop", @"steam", @"forza", @"hades", @"bigscreen"], @"current": @"0", @"lastApp": @"forza",
              @"recents": @[@"forza", @"hades"], @"lastConnected": @(-86400*5), @"lastSeen": @(-86400*2)},
            @{@"uuid": @"0E55-LIVINGROOM", @"name": @"Living Room PC", @"local": @"10.100.0.88", @"mac": @"00:00:5e:00:53:05",
              @"paired": @YES, @"state": @(StateOffline), @"rtt": @(-1), @"codec": @(0x1|0x100|0x200),
              @"platform": @"windows", @"apps": @[@"desktop", @"steam", @"forza", @"stardew"], @"current": @"0", @"lastApp": @"forza",
              @"recents": @[@"forza", @"stardew"], @"lastConnected": @(-86400*9), @"lastSeen": @(-86400)},
            // A desktop-only host (a work PC) and a plain Sunshine Mac with Desktop and Steam.
            @{@"uuid": @"0F66-OFFICEPC", @"name": @"Office PC", @"local": @"10.100.0.60", @"mac": @"00:00:5e:00:53:06",
              @"paired": @YES, @"state": @(StateOnline), @"rtt": @1, @"codec": @(0x1|0x100|0x200),
              @"platform": @"windows", @"apps": @[@"desktop", @"steam", @"bigscreen"], @"current": @"0", @"lastApp": @"desktop", @"recents": @[@"desktop"],
              @"lastConnected": @(-86400), @"lastSeen": @0},
            @{@"uuid": @"1077-STUDIO", @"name": @"Studio Mac", @"local": @"10.100.0.71", @"mac": @"00:00:5e:00:53:07",
              @"paired": @YES, @"state": @(StateOnline), @"rtt": @2, @"codec": @(0x1|0x100),
              @"platform": @"macos", @"apps": @[@"desktop", @"steam"], @"current": @"0", @"lastApp": @"desktop", @"recents": @[@"desktop", @"steam"],
              @"lastConnected": @(-86400*4), @"lastSeen": @0},
            // Two older records of the first host: same name and MAC, a different uuid (a reinstall).
            @{@"uuid": @"0A11-GAMINGPC-OLD1", @"name": @"Gaming PC", @"local": @"10.100.0.133", @"mac": @"00:00:5e:00:53:01",
              @"paired": @YES, @"state": @(StateOffline), @"rtt": @(-1), @"codec": @(0x1|0x100),
              @"platform": @"windows", @"apps": @[@"desktop", @"steam"], @"current": @"0", @"recents": @[],
              @"lastConnected": @(-86400*40), @"lastSeen": @(-86400*30)},
            @{@"uuid": @"0A11-GAMINGPC-OLD2", @"name": @"Gaming PC", @"local": @"10.100.0.140",
              @"paired": @NO, @"state": @(StateOffline), @"rtt": @(-1), @"codec": @(0x1),
              @"platform": @"windows", @"apps": @[], @"current": @"0", @"recents": @[],
              @"lastConnected": @0, @"lastSeen": @(-86400*75)},
        ];
    });
    return hosts;
}

// What a Foundation Sunshine host adds to /serverinfo and /applist. Hosts without an entry here
// behave as plain Sunshine: nothing of this is sent and the client falls back.
static NSDictionary *MockProfile(NSString *uuid) {
    static NSDictionary *profiles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *full = @[@"genshin", @"hsr", @"zzz", @"cyberpunk", @"eldenring", @"forza", @"hades", @"bg3"];
        profiles = @{
            @"0A11-GAMINGPC-LIVE": @{@"fs": @1, @"os": @"Windows 11 24H2", @"gpu": @"GeForce RTX 4080",
                                      @"modes": @"3840x2160@120,2560x1440@165,1920x1080@240",
                                      @"art": full, @"thumb": @"desk_win"},
            @"0B22-MACMINI": @{@"fs": @1, @"os": @"macOS 26.6", @"gpu": @"Apple M4 Max", @"modes": @"3456x2234@120",
                                 @"hostIcon": @"film.fill:indigo", @"artIconOnly": @[@"resolve", @"blender"], @"thumb": @"desk_mac"},
            @"0C33-LINUXPC": @{@"fs": @1, @"os": @"Ubuntu 24.04", @"gpu": @"Radeon RX 7900 XT", @"modes": @"3840x2160@144"},
            @"0F66-OFFICEPC": @{@"fs": @1, @"os": @"Windows 11 Pro", @"gpu": @"Intel Iris Xe", @"modes": @"1920x1080@60",
                                @"hostIcon": @"briefcase.fill:blue", @"thumb": @"desk_win2"},
            @"0E56-GARAGE": @{@"fs": @1, @"os": @"Windows 10", @"gpu": @"GeForce GTX 1660", @"modes": @"1920x1080@144", @"thumb": @"desk_win2"},
        };
    });
    return profiles[uuid];
}

static NSDictionary *MockAppExtras(NSString *hostUUID, NSString *slug, BOOL running) {
    NSDictionary *profile = MockProfile(hostUUID);
    if (profile == nil) return @{};
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSDictionary *table = @{
        @"genshin":   @[@"sparxie", @"touch", @(-10800),  @(3600*186)],
        @"hsr":       @[@"sparxie", @"touch", @(-86400),  @(3600*92)],
        @"zzz":       @[@"sparxie", @"touch", @(-172800), @(3600*41)],
        @"cyberpunk": @[@"steam",   @"kbm",   @(-777600), @(3600*64)],
        @"eldenring": @[@"steam",   @"kbm",   @(-345600), @(3600*211)],
        @"forza":     @[@"steam",   @"kbm",   @(-1296000),@(3600*18)],
        @"hades":     @[@"steam",   @"kbm",   @(-1728000),@(3600*33)],
        @"bg3":       @[@"steam",   @"kbm",   @(-518400), @(3600*129)],
        @"resolve":   @[@"custom",  @"kbm",   @(-172800), @(3600*57)],
        @"blender":   @[@"custom",  @"kbm",   @(-432000), @(3600*23)],
        @"steam":     @[@"custom",  @"kbm",   @(-86400*3),@(3600*400)],
        @"desktop":   @[@"custom",  @"kbm",   @(-7200),   @(3600*900)],
    };
    NSDictionary *kinds = @{@"desktop": @"desktop", @"steam": @"tool", @"bigscreen": @"bigscreen", @"resolve": @"tool", @"blender": @"tool"};
    NSString *kind = kinds[slug] ?: @"game";
    if ([slug isEqualToString:@"bigscreen"]) {
        return @{@"FsKind": @"bigscreen", @"FsArt": @"poster", @"FsArtVersion": @"3"};
    }
    NSArray *row = table[slug];
    if (row == nil) return @{};
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"FsKind"] = kind;
    d[@"FsSource"] = row[0];
    d[@"FsLaunchMode"] = row[1];
    d[@"FsLastPlayed"] = [NSString stringWithFormat:@"%.0f", now + [row[2] doubleValue]];
    d[@"FsPlaySeconds"] = [NSString stringWithFormat:@"%d", [row[3] intValue]];
    if (running) d[@"FsSession"] = [NSString stringWithFormat:@"%.0f", now - 4320];
    NSArray *full = profile[@"art"];
    if ([full containsObject:slug]) {
        d[@"FsArt"] = @"poster,hero,logo,icon";
    } else if ([profile[@"artIconOnly"] containsObject:slug]) {
        d[@"FsArt"] = @"poster,icon";
    } else {
        d[@"FsArt"] = @"poster";
    }
    d[@"FsArtVersion"] = @"3";
    return d;
}

static NSDictionary *MockHostForUUID(NSString *uuid) {
    for (NSDictionary *h in MockHosts()) {
        if ([h[@"uuid"] isEqualToString:uuid]) return h;
    }
    return nil;
}

static NSArray<NSDictionary *> *MockAppCatalog(void) {
    static NSArray *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[
            @{@"slug": @"desktop", @"name": @"Desktop", @"id": @"1", @"hdr": @NO},
            @{@"slug": @"steam", @"name": @"Steam Big Picture", @"id": @"2", @"hdr": @NO},
            @{@"slug": @"genshin", @"name": @"原神", @"id": @"3", @"hdr": @YES},
            @{@"slug": @"hsr", @"name": @"崩坏：星穹铁道", @"id": @"4", @"hdr": @YES},
            @{@"slug": @"zzz", @"name": @"绝区零", @"id": @"5", @"hdr": @YES},
            @{@"slug": @"cyberpunk", @"name": @"Cyberpunk 2077", @"id": @"6", @"hdr": @YES},
            @{@"slug": @"eldenring", @"name": @"ELDEN RING", @"id": @"7", @"hdr": @YES},
            @{@"slug": @"forza", @"name": @"Forza Horizon 5", @"id": @"8", @"hdr": @YES},
            @{@"slug": @"hades", @"name": @"Hades II", @"id": @"9", @"hdr": @NO},
            @{@"slug": @"bg3", @"name": @"Baldur's Gate 3", @"id": @"10", @"hdr": @NO},
            @{@"slug": @"resolve", @"name": @"DaVinci Resolve", @"id": @"11", @"hdr": @YES},
            @{@"slug": @"blender", @"name": @"Blender", @"id": @"12", @"hdr": @NO},
            @{@"slug": @"hollow", @"name": @"Hollow Knight", @"id": @"13", @"hdr": @NO},
            @{@"slug": @"stardew", @"name": @"Stardew Valley", @"id": @"14", @"hdr": @NO},
            @{@"slug": @"bigscreen", @"name": @"大屏", @"id": @"15", @"hdr": @NO},
        ];
    });
    return a;
}

static NSDictionary *CatalogEntry(NSString *slug) {
    for (NSDictionary *e in MockAppCatalog()) {
        if ([e[@"slug"] isEqualToString:slug]) return e;
    }
    return nil;
}

@implementation ConceptHarness

+ (void)load {
    if (getenv("MLC_FRAMEWATCH")) {
        // alone it watches a normal launch (real database, no fixtures)
        [self startFrameWatch];
    }
    if (getenv("MLC_HARNESS") == NULL) {
        return;
    }
    // The store, the client certificate and the box art all live under the home directory.
    // Refuse to run anywhere that is not the private sandbox, so nothing of the installed app is touched.
    NSString *home = NSHomeDirectory();
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (![home hasPrefix:kSandbox] || ![support hasPrefix:kSandbox] || ![docs hasPrefix:kSandbox] || ![caches hasPrefix:kSandbox]) {
        fprintf(stderr, "ConceptHarness: refusing to run outside %s (home=%s)\n", kSandbox.UTF8String, home.UTF8String);
        _exit(3);
    }
    // Let windows be larger than the screen so a 1728x1117 window can be captured on a 1080p display.
    Method m = class_getInstanceMethod([NSWindow class], @selector(constrainFrameRect:toScreen:));
    method_setImplementation(m, imp_implementationWithBlock(^NSRect(id selfObj, NSRect r, NSScreen *s) { return r; }));
    // The Mac that runs the shots sits at the login window, so no app can become active and
    // every window would be drawn in its dimmed inactive state. Report the window as key and
    // the app as active so the shots show the window the way it looks in use.
    BOOL (^yes)(id) = ^BOOL(id selfObj) { return YES; };
    // MLC_INACTIVE=1: the unfocused shot: the window is reported as neither key nor main and the app as inactive
    BOOL (^answer)(id) = getenv("MLC_INACTIVE") == NULL ? yes : ^BOOL(id selfObj) { return NO; };
    method_setImplementation(class_getInstanceMethod([NSWindow class], @selector(isKeyWindow)), imp_implementationWithBlock(answer));
    method_setImplementation(class_getInstanceMethod([NSWindow class], @selector(isMainWindow)), imp_implementationWithBlock(answer));
    method_setImplementation(class_getInstanceMethod([NSApplication class], @selector(isActive)), imp_implementationWithBlock(answer));
}

#pragma mark - Launch frame watch

static BOOL FrameWatchHasOldPage(NSView *v) {
    NSString *cls = NSStringFromClass([v class]);
    // the old page is the collection view whose data source is HostsViewController (the apps page has a
    // CollectionView of its own, with AppsViewController as its data source)
    if (!v.hidden && [v isKindOfClass:[NSCollectionView class]]) {
        NSString *source = NSStringFromClass([[(NSCollectionView *)v dataSource] class]);
        if ([source isEqualToString:@"HostsViewController"]) return YES;
    }
    if (!v.hidden && ([cls isEqualToString:@"HostCellView"] || [cls isEqualToString:@"HostCell"])) return YES;
    for (NSView *sub in v.subviews) {
        if (FrameWatchHasOldPage(sub)) return YES;
    }
    return NO;
}

/// From the first moment the process runs: every 100 ms, is the main window up, does its view tree hold the
/// old host-list page (the collection view of host cells), and the composited image of the window while it
/// is on screen (first two seconds), written as numbered PNGs to MLC_FRAMEDIR. Harness builds only.
+ (void)startFrameWatch {
    NSString *dir = getenv("MLC_FRAMEDIR") ? [NSString stringWithUTF8String:getenv("MLC_FRAMEDIR")] : @"/tmp/apps-concept/out/frames";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    __block CFAbsoluteTime firstVisible = 0;
    __block int shot = 0;
    MLCWindowListCreateImage create = (MLCWindowListCreateImage)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    // MLC_FRAMESPAN: seconds of frames kept after the window is first visible (default 2); MLC_FRAMESTEP: seconds between frames (default 0.1)
    double span = getenv("MLC_FRAMESPAN") ? atof(getenv("MLC_FRAMESPAN")) : 2.0;
    double step = getenv("MLC_FRAMESTEP") ? atof(getenv("MLC_FRAMESTEP")) : 0.1;
    NSTimer *timer = [NSTimer timerWithTimeInterval:step repeats:YES block:^(NSTimer *t) {
        NSWindow *w = nil;
        for (NSWindow *candidate in NSApp.windows) {
            if ([candidate.contentViewController isKindOfClass:NSClassFromString(@"ContainerViewController")]) w = candidate;
        }
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        BOOL visible = w != nil && w.isVisible;
        BOOL old = w != nil && FrameWatchHasOldPage(w.contentView);
        NSMutableArray *kids = [NSMutableArray array];
        for (NSView *k in w.contentView.subviews) [kids addObject:NSStringFromClass([k class])];
        fprintf(stderr, "FRAMEWATCH t=%.2f window=%d visible=%d old=%d kids=%s\n", now - t0, w != nil, visible, old, [kids componentsJoinedByString:@","].UTF8String);
        if (visible && firstVisible == 0) firstVisible = now;
        if (visible && now - firstVisible <= span && create != NULL) {
            CGImageRef img = create(CGRectNull, kCGWindowListOptionIncludingWindow, (uint32_t)w.windowNumber, kCGWindowImageBoundsIgnoreFraming);
            if (img != NULL) {
                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
                [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"f-%03d-t%.2f.png", shot++, now - t0]] atomically:NO];
                CGImageRelease(img);
            }
        }
        if (now - t0 > span + 10.0) [t invalidate];
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

+ (BOOL)enabled {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ on = getenv("MLC_HARNESS") != NULL; });
    return on;
}

+ (BOOL)networkMocked {
    return [self enabled] && getenv("MLC_REAL_NET") == NULL;
}

+ (NSString *)variant {
    const char *v = getenv("MLC_VARIANT");
    return v ? [NSString stringWithUTF8String:v] : @"";
}

#pragma mark - Mock data

+ (void)applyMockRuntimeStateToHost:(TemporaryHost *)host {
    if (![self networkMocked]) return;
    NSDictionary *m = MockHostForUUID(host.uuid);
    if (m == nil) return;
    host.state = (State)[m[@"state"] intValue];
    NSString *addr = m[@"local"] ?: m[@"external"];
    host.activeAddress = addr;
    host.appVersion = @"7.1.431.-1";
    host.gfeVersion = @"3.23.0.74";
    int rtt = [m[@"rtt"] intValue];
    if (addr != nil) {
        host.addressLatencies = @{addr: @(rtt)};
        host.addressStates = @{addr: @(host.state == StateOnline ? 1 : 0)};
    }
    host.currentGame = m[@"current"] ?: @"0";
    if (getenv("MLC_RUNNING_OFF")) {
        host.currentGame = @"0";
    }
}

+ (void)applyMockExtrasToApp:(TemporaryApp *)app {
    if (![self enabled] || app.host.uuid == nil) return;
    NSString *slug = nil;
    for (NSDictionary *e in MockAppCatalog()) {
        if ([e[@"id"] isEqualToString:app.id]) { slug = e[@"slug"]; break; }
    }
    if (slug == nil) return;
    NSDictionary *m = MockHostForUUID(app.host.uuid);
    BOOL running = [m[@"current"] isEqualToString:app.id] && !getenv("MLC_RUNNING_OFF");
    app.fsExtras = MockAppExtras(app.host.uuid, slug, running);
}

/// The shape of real user data that crashed a launch: hosts without a certificate at a REAL reachable address
/// (Gaming PC 10.100.0.133 answers on 47984), a stale certificate, duplicates by name, offline hosts.
+ (void)seedRepro {
    DataManager *dm = [[DataManager alloc] init];
    NSData *junk = [NSData dataWithBytes:"not-a-real-certificate-just-bytes-0123456789" length:44];
    // MLC_REPRO_ADDR: where the "real reachable" hosts point (a TLS endpoint that answers the handshake).
    NSString *reach = getenv("MLC_REPRO_ADDR") ? [NSString stringWithUTF8String:getenv("MLC_REPRO_ADDR")] : @"10.100.0.133";
    NSArray *rows = @[
        // name, uuid, address, hasJunkCert, apps
        @[@"Aaa Gaming PC", @"REPRO-NOCERT-1", reach, @NO, @[]],
        @[@"Gaming PC", @"REPRO-DUP-2", reach, @NO, @[@"desktop", @"steam"]],
        @[@"Gaming PC", @"REPRO-OLD-3", reach, @YES, @[@"desktop", @"steam", @"genshin"]],
        @[@"Linux PC", @"REPRO-UNP-4", @"10.100.0.210", @NO, @[]],
        @[@"Offline PC", @"REPRO-OFF-5", @"10.100.0.250", @YES, @[@"desktop", @"steam"]],
        @[@"Mac mini", @"REPRO-SRV-6", @"10.100.0.220", @NO, @[]],
    ];
    int macIndex = 0;
    NSString *posters = [NSString stringWithUTF8String:getenv("MLC_POSTERS") ?: ""];
    for (NSArray *row in rows) {
        TemporaryHost *h = [[TemporaryHost alloc] init];
        h.name = row[0]; h.uuid = row[1];
        h.localAddress = row[2]; h.address = row[2];
        h.pairState = [row[3] boolValue] ? PairStatePaired : PairStateUnpaired;
        if ([row[3] boolValue]) h.serverCert = junk;
        h.mac = [NSString stringWithFormat:@"02:00:00:aa:bb:%02x", ++macIndex];
        NSMutableSet *apps = [NSMutableSet set];
        for (NSString *slug in row[4]) {
            NSDictionary *e = CatalogEntry(slug);
            TemporaryApp *a = [[TemporaryApp alloc] init];
            a.id = e[@"id"]; a.name = e[@"name"]; a.hdrSupported = NO; a.superCommands = @[]; a.host = h;
            [apps addObject:a];
            NSString *dst = [AppAssetManager boxArtPathForApp:a];
            [[NSFileManager defaultManager] createDirectoryAtPath:dst.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            [[NSFileManager defaultManager] copyItemAtPath:[posters stringByAppendingPathComponent:[slug stringByAppendingString:@".png"]] toPath:dst error:nil];
        }
        h.appList = apps;
        [dm updateHost:h];
        [dm updateAppsForExistingHost:h];
    }
}

/// MLC_SEED=tls: MLC_TLS_N paired computers whose pinned certificate is the one MLC_TLS_CERT (DER) holds, each
/// at 127.0.0.1:<port> (the HTTPS port is the http port minus 5), uuid TLS-<i>. A local HTTPS server that asks for
/// a client certificate answers them: discovery then runs the client-certificate handshake of every host in parallel.
+ (void)seedTLS {
    DataManager *dm = [[DataManager alloc] init];
    NSData *der = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:getenv("MLC_TLS_CERT") ?: ""]];
    int count = getenv("MLC_TLS_N") ? atoi(getenv("MLC_TLS_N")) : 8;
    int base = getenv("MLC_TLS_BASE") ? atoi(getenv("MLC_TLS_BASE")) : 50005;
    for (int i = 0; i < count; i++) {
        TemporaryHost *h = [[TemporaryHost alloc] init];
        h.name = [NSString stringWithFormat:@"Stress %d", i];
        h.uuid = [NSString stringWithFormat:@"TLS-%d", i];
        NSString *addr = [NSString stringWithFormat:@"127.0.0.1:%d", base + i * 10];
        h.localAddress = addr; h.address = addr;
        // MLC_TLS_EXT=<http port>: the second address is 127.0.0.1:<that port> (a mock that may only answer plain HTTP)
        h.externalAddress = getenv("MLC_TLS_EXT") ? [NSString stringWithFormat:@"127.0.0.1:%d", atoi(getenv("MLC_TLS_EXT")) + i * 10]
                                                  : [NSString stringWithFormat:@"localhost:%d", base + i * 10];
        h.pairState = PairStatePaired;
        h.serverCert = der;
        h.mac = [NSString stringWithFormat:@"02:00:00:cc:dd:%02x", i + 1];
        h.appList = [NSSet set];
        [dm updateHost:h];
    }
}

/// Switches through every host in the sidebar, round and round, until the process is stopped.
+ (void)runSoak {
    NSArray *hosts = [[[DataManager alloc] init] getHosts];
    NSArray *sorted = [hosts sortedArrayUsingSelector:@selector(compareName:)];
    __block NSUInteger index = 0;
    [NSTimer scheduledTimerWithTimeInterval:4.0 repeats:YES block:^(NSTimer *timer) {
        TemporaryHost *h = sorted[index % sorted.count];
        index++;
        fprintf(stderr, "ConceptHarness: soak select %s\n", h.name.UTF8String);
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckSelectHost" object:nil userInfo:@{@"uuid": h.uuid}];
    }];
}

+ (void)seedIfNeeded {
    if (![self enabled]) return;
    if (getenv("MLC_SEED") && strcmp(getenv("MLC_SEED"), "none") == 0) {
        // an empty database: the first-run state
        [[NSUserDefaults standardUserDefaults] setObject:@"简体中文" forKey:@"appLanguage"];
        return;
    }
    if (getenv("MLC_SEED") && strcmp(getenv("MLC_SEED"), "tls") == 0) {
        // English unless MLC_LANG=zh (the distribution shots are read in Chinese)
        BOOL chinese = getenv("MLC_LANG") && strcmp(getenv("MLC_LANG"), "zh") == 0;
        [[NSUserDefaults standardUserDefaults] setObject:chinese ? @"简体中文" : @"English" forKey:@"appLanguage"];
        if ([[[DataManager alloc] init] getHosts].count == 0) [self seedTLS];
        return;
    }
    if (getenv("MLC_SEED") && strcmp(getenv("MLC_SEED"), "repro") == 0) {
        [[NSUserDefaults standardUserDefaults] setObject:@"English" forKey:@"appLanguage"];
        if ([[[DataManager alloc] init] getHosts].count == 0) [self seedRepro];
        return;
    }
    // The shots are in Chinese unless MLC_LANG=en.
    BOOL english = getenv("MLC_LANG") && strcmp(getenv("MLC_LANG"), "en") == 0;
    [[NSUserDefaults standardUserDefaults] setObject:english ? @"English" : @"简体中文" forKey:@"appLanguage"];
    DataManager *dm = [[DataManager alloc] init];
    NSMutableDictionary *facts = [NSMutableDictionary dictionary];
    NSString *posters = [NSString stringWithUTF8String:getenv("MLC_POSTERS") ?: ""];
    BOOL seeded = [dm getHosts].count > 0;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;

    for (NSDictionary *m in MockHosts()) {
        NSMutableDictionary *f = [NSMutableDictionary dictionary];
        NSDictionary *profile = MockProfile(m[@"uuid"]);
        f[@"platform"] = profile != nil ? m[@"platform"] : @"";
        f[@"vendor"] = @"foundation";
        if (profile != nil) {
            f[@"fsVersion"] = profile[@"fs"];
            f[@"osVersion"] = profile[@"os"];
            f[@"gpu"] = profile[@"gpu"];
            f[@"displayModes"] = profile[@"modes"];
            if (profile[@"hostIcon"]) f[@"hostIcon"] = profile[@"hostIcon"];
        } else {
            f[@"vendor"] = @"";
        }
        if ([m[@"uuid"] isEqualToString:@"0D44-ALIENWARE"]) {
            f[@"icon"] = @{@"symbol": @"gamecontroller.fill", @"color": @"green"};   // chosen by the user
        }
        if ([m[@"lastConnected"] doubleValue] != 0) f[@"lastConnected"] = @(now + [m[@"lastConnected"] doubleValue]);
        if ([m[@"lastSeen"] doubleValue] != 0) f[@"lastSeen"] = @(now + [m[@"lastSeen"] doubleValue]);
        if (m[@"lastApp"]) f[@"lastApp"] = CatalogEntry(m[@"lastApp"])[@"id"];
        if ([m[@"uuid"] isEqualToString:@"0F66-OFFICEPC"]) {
            f[@"sessions"] = @[
                @{@"app": @"1", @"start": @(now - 3600*26), @"seconds": @(3600*3 + 300)},
                @{@"app": @"1", @"start": @(now - 86400*3), @"seconds": @(3600*1 + 1200)},
                @{@"app": @"1", @"start": @(now - 86400*4), @"seconds": @(3600*2 + 2700)},
                @{@"app": @"1", @"start": @(now - 86400*6), @"seconds": @(3300)},
                @{@"app": @"1", @"start": @(now - 86400*8), @"seconds": @(3600*4 + 600)},
            ];
        }
        if ([m[@"uuid"] isEqualToString:@"0A11-GAMINGPC-LIVE"]) {
            f[@"sessions"] = @[
                @{@"app": @"3", @"start": @(now - 4320), @"seconds": @0},
                @{@"app": @"1", @"start": @(now - 7200 - 3600), @"seconds": @(3600*2 + 600)},
                @{@"app": @"4", @"start": @(now - 86400 - 7000), @"seconds": @(3600*1 + 1800)},
                @{@"app": @"5", @"start": @(now - 172800), @"seconds": @(3600*3)},
                @{@"app": @"2", @"start": @(now - 259200), @"seconds": @(1800)},
            ];
        }
        NSMutableArray *rec = [NSMutableArray array];
        for (NSString *s in m[@"recents"]) [rec addObject:CatalogEntry(s)[@"id"]];
        f[@"recents"] = rec;
        facts[m[@"uuid"]] = f;
    }
    [[NSUserDefaults standardUserDefaults] setObject:facts forKey:@"MLHostFacts"];
    if (seeded) return;

    for (NSDictionary *m in MockHosts()) {
        TemporaryHost *h = [[TemporaryHost alloc] init];
        h.uuid = m[@"uuid"];
        h.name = m[@"name"];
        h.localAddress = m[@"local"];
        h.address = m[@"local"] ?: m[@"external"];
        h.externalAddress = m[@"external"];
        if ([m[@"uuid"] isEqualToString:@"0E56-GARAGE"] || [m[@"uuid"] isEqualToString:@"0A11-GAMINGPC-LIVE"]) {
            // several ways to reach the same computer, for the address rows
            if (h.externalAddress.length == 0) h.externalAddress = @"203.0.113.77";
            h.ipv6Address = @"2001:db8:1234::133";
            if ([m[@"uuid"] isEqualToString:@"0E56-GARAGE"]) h.address = @"garage-pc.local";
        }
        h.mac = m[@"mac"];
        h.serverCodecModeSupport = [m[@"codec"] intValue];
        h.pairState = [m[@"paired"] boolValue] ? PairStatePaired : PairStateUnpaired;
        if ([m[@"paired"] boolValue]) {
            h.serverCert = [@"concept-mock-server-certificate-not-real" dataUsingEncoding:NSUTF8StringEncoding];
        }
        NSMutableSet *apps = [NSMutableSet set];
        int order = 0;
        // MLC_APPCOUNT=N: exactly N apps on the LIVE host (the catalog repeated with new ids), for the tile-size checks
        NSArray *slugList = m[@"apps"];
        if (getenv("MLC_APPCOUNT") && [m[@"uuid"] isEqualToString:@"0A11-GAMINGPC-LIVE"]) {
            NSMutableArray *list = [NSMutableArray array];
            NSArray *pool = @[@"genshin", @"hsr", @"zzz", @"cyberpunk", @"eldenring", @"forza", @"hades", @"bg3", @"steam", @"resolve", @"blender"];
            for (int i = 0; i < atoi(getenv("MLC_APPCOUNT")); i++) [list addObject:pool[i % pool.count]];
            slugList = list;
        }
        // MLC_APPSET=slug,slug: the apps of the plain Sunshine host Alienware, in this order (the 连接 fallback shots)
        if (getenv("MLC_APPSET") && [m[@"uuid"] isEqualToString:@"0D44-ALIENWARE"]) {
            slugList = [[NSString stringWithUTF8String:getenv("MLC_APPSET")] componentsSeparatedByString:@","];
        }
        int serial = 0;
        for (NSString *slug in slugList) {
            NSDictionary *e = CatalogEntry(slug);
            if (e == nil) continue;   // MLC_APPSET=none: no apps at all
            TemporaryApp *a = [[TemporaryApp alloc] init];
            a.id = getenv("MLC_APPCOUNT") ? [NSString stringWithFormat:@"%@-%d", e[@"id"], serial++] : e[@"id"];
            a.name = e[@"name"];
            a.hdrSupported = [e[@"hdr"] boolValue];
            a.pinned = (order < 2 && [m[@"apps"] count] > 6);
            a.superCommands = @[];
            a.host = h;
            [apps addObject:a];
            order++;
            // Box art goes where the real asset manager looks for it.
            NSString *dst = [AppAssetManager boxArtPathForApp:a];
            [[NSFileManager defaultManager] createDirectoryAtPath:dst.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *src = [posters stringByAppendingPathComponent:[slug stringByAppendingString:@".png"]];
            [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
            [[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:nil];
            // Foundation Sunshine hosts also send landscape art, a logo and a square icon.
            NSString *base = [dst stringByDeletingPathExtension];
            NSDictionary *extras = MockAppExtras(m[@"uuid"], slug, NO);
            NSString *art = extras[@"FsArt"] ?: @"";
            NSDictionary *kinds = @{@"hero": @"_hero.jpg", @"logo": @"_logo.png", @"icon": @"_icon.png"};
            for (NSString *kind in kinds) {
                NSString *file = [posters stringByAppendingPathComponent:[slug stringByAppendingString:kinds[kind]]];
                if ([art containsString:kind] && [[NSFileManager defaultManager] fileExistsAtPath:file]) {
                    [[NSFileManager defaultManager] copyItemAtPath:file toPath:[base stringByAppendingString:kinds[kind]] error:nil];
                }
            }
        }
        h.appList = apps;
        NSString *thumb = MockProfile(m[@"uuid"])[@"thumb"];
        TemporaryApp *anyApp = apps.anyObject;
        NSString *lastFrameHosts = @"0A11-GAMINGPC-LIVE 0F66-OFFICEPC 0E56-GARAGE";
        if (thumb != nil && [lastFrameHosts containsString:m[@"uuid"]]) {
            // the client's own last frame of the desktop (app id 1), where StreamBackdropStore keeps it
            NSString *dir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
                             stringByAppendingPathComponent:@"Moonlight/LastFrames"];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            NSMutableString *safeHost = [NSMutableString string];
            for (NSUInteger i = 0; i < [m[@"uuid"] length]; i++) {
                unichar ch = [m[@"uuid"] characterAtIndex:i];
                if ([[NSCharacterSet alphanumericCharacterSet] characterIsMember:ch] || ch == '-') [safeHost appendFormat:@"%C", ch];
            }
            NSString *dst = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-1.jpg", safeHost]];
            [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
            [[NSFileManager defaultManager] copyItemAtPath:[posters stringByAppendingPathComponent:[thumb stringByAppendingString:@".jpg"]] toPath:dst error:nil];
            thumb = nil;   // no host-provided thumbnail for these: the last frame is what they have
        }
        if (thumb != nil && anyApp != nil) {
            NSString *dir = [AppAssetManager boxArtPathForApp:anyApp].stringByDeletingLastPathComponent;
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *src = [posters stringByAppendingPathComponent:[thumb stringByAppendingString:@".jpg"]];
            [[NSFileManager defaultManager] removeItemAtPath:[dir stringByAppendingPathComponent:@"_desktop.jpg"] error:nil];
            [[NSFileManager defaultManager] copyItemAtPath:src toPath:[dir stringByAppendingPathComponent:@"_desktop.jpg"] error:nil];
        }
        [dm updateHost:h];
        [dm updateAppsForExistingHost:h];
    }
}

#pragma mark - Scripted scene

