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
#import <ImageIO/ImageIO.h>

static NSString *const kSandbox = @"/tmp/apps-concept/";
static NSWindow *sOverlayWindow;
static NSWindowController *sSettingsWindowController;
static NSWindow *sLogViewerWindow;

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
    if (getenv("MLC_REC60")) {
        [self startRecording60];
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

/// A 60 Hz capture of the main window (MLC_REC60, with MLC_FRAMEDIR and MLC_FRAMESPAN seconds): a timer on its own queue takes the window's composited image
/// at nominal resolution and hands it to a pool of writers; the file name carries the capture time, so the real rate and any dropped frame can be read back.
+ (void)startRecording60 {
    NSString *dir = getenv("MLC_FRAMEDIR") ? [NSString stringWithUTF8String:getenv("MLC_FRAMEDIR")] : @"/tmp/apps-concept/out/rec60";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    double span = getenv("MLC_FRAMESPAN") ? atof(getenv("MLC_FRAMESPAN")) : 6.0;
    MLCWindowListCreateImage create = (MLCWindowListCreateImage)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    if (create == NULL) return;
    static volatile uint32_t windowNumber = 0;
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    // the window number is read on the main thread; the capture itself does not wait for it
    NSTimer *finder = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *t) {
        NSWindow *w = nil;
        for (NSWindow *candidate in NSApp.windows) {
            if ([candidate.contentViewController isKindOfClass:NSClassFromString(@"ContainerViewController")]) w = candidate;
        }
        if (w != nil && w.isVisible) windowNumber = (uint32_t)w.windowNumber;
        if (CFAbsoluteTimeGetCurrent() - t0 > span + 30) [t invalidate];
    }];
    [[NSRunLoop mainRunLoop] addTimer:finder forMode:NSRunLoopCommonModes];
    dispatch_queue_attr_t interactive = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    dispatch_queue_t captureQueue = dispatch_queue_create("mlc.rec60.capture", interactive);
    dispatch_queue_t writeQueue = dispatch_queue_create("mlc.rec60.write", DISPATCH_QUEUE_CONCURRENT);
    __block CFAbsoluteTime first = 0;
    __block int count = 0;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, captureQueue);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 60, NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        // never run on: no window within 30 s, or the span used up (also when every capture fails)
        if ((first == 0 && now - t0 > 30) || (first != 0 && now - first > span)) { dispatch_source_cancel(timer); return; }
        uint32_t number = windowNumber;
        if (number == 0) return;
        CGImageRef image = create(CGRectNull, kCGWindowListOptionIncludingWindow, number, kCGWindowImageBoundsIgnoreFraming | kCGWindowImageNominalResolution);
        if (image == NULL) return;
        if (first == 0) first = now;
        NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"f-%04d-t%.4f.png", count++, now - t0]];
        dispatch_async(writeQueue, ^{
            CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
            if (destination != NULL) {
                CGImageDestinationAddImage(destination, image, NULL);
                CGImageDestinationFinalize(destination);
                CFRelease(destination);
            }
            CGImageRelease(image);
        });
    });
    dispatch_resume(timer);
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
    // MLC_CURRENT=<app id>: the app this host runs now (1 = Desktop, 15 = 大屏, 3 = 原神 ...), for shots of 退出
    if (getenv("MLC_CURRENT")) host.currentGame = [NSString stringWithUTF8String:getenv("MLC_CURRENT")];
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
    NSString *current = getenv("MLC_CURRENT") ? [NSString stringWithUTF8String:getenv("MLC_CURRENT")] : m[@"current"];
    BOOL running = [current isEqualToString:app.id] && !getenv("MLC_RUNNING_OFF");
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

+ (void)startScripted {
    if (![self enabled]) return;
    [NSApp activateIgnoringOtherApps:YES];
    if (getenv("MLC_TLS_PROBE")) {
        // The request that used to crash: an HTTPS request to a TLS endpoint through an HttpManager with no pinned certificate.
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            HttpManager *m = [[HttpManager alloc] initWithHost:@"127.0.0.1" uniqueId:@"0123456789ABCDEF" serverCert:nil];
            HttpResponse *r = [[HttpResponse alloc] init];
            [m executeRequestSynchronously:[HttpRequest requestForResponse:r withUrlRequest:[m newAppListRequest]]];
            fprintf(stderr, "ConceptHarness: tls probe with nil cert finished, status=%d message=%s\n", (int)r.statusCode, r.statusMessage.UTF8String ?: "");
        });
    }
    if (getenv("MLC_ENDPOINTS")) {
        // MLC_ENDPOINTS="uuid|address|kind;..." : addresses added the way 添加连接方式 does (kind: host, forward, relay, overlay or empty)
        for (NSString *entry in [[NSString stringWithUTF8String:getenv("MLC_ENDPOINTS")] componentsSeparatedByString:@";"]) {
            NSArray *p = [entry componentsSeparatedByString:@"|"];
            if (p.count < 2) continue;
            [ConnectionEndpointStore addManualEndpoint:p[1] forHost:p[0]];
            if (p.count > 2 && [p[2] length] > 0) [ConnectionEndpointStore setDeclaredPath:p[2] forEndpoint:p[1] forHost:p[0]];
        }
    }
    if (getenv("MLC_PAIRWATCH")) {
        // MLC_PAIRWATCH=<host uuid>: logs every change of the persisted pairState of that host (what the next launch would load)
        NSString *watched = [NSString stringWithUTF8String:getenv("MLC_PAIRWATCH")];
        __block int last = -99;
        NSDate *t0 = [NSDate date];
        [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
            for (TemporaryHost *h in [[[DataManager alloc] init] getHosts]) {
                if (![h.uuid isEqualToString:watched]) continue;
                if ((int)h.pairState != last) {
                    fprintf(stderr, "PAIRWATCH %s pairState %d -> %d at +%.1fs\n", watched.UTF8String, last, (int)h.pairState, -[t0 timeIntervalSinceNow]);
                    last = (int)h.pairState;
                }
            }
        }];
    }
    if (getenv("MLC_INPUTALERT")) {
        // MLC_INPUTALERT=1: the Input Monitoring launch alert as a sheet on the main window (take the picture with MLC_SHEETCOMP=1)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[InputMonitoringPermissionManager sharedManager] presentLaunchAlertForHarness];
        });
    }
    if (getenv("MLC_LOGVIEWER")) {
        // MLC_LOGVIEWER=1: the live log window (Export Log… button) on its own
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            sLogViewerWindow = [MLCLogViewerHarness makeWindow];
            [sLogViewerWindow setFrameOrigin:NSMakePoint(20, 200)];
            [sLogViewerWindow makeKeyAndOrderFront:nil];
        });
    }
    if (getenv("MLC_APPLIST_EVERY")) {
        // MLC_APPLIST_EVERY=<seconds>: asks the apps page to read the host's app list again, the way a refresh does
        NSTimeInterval every = atof(getenv("MLC_APPLIST_EVERY"));
        [NSTimer scheduledTimerWithTimeInterval:every repeats:YES block:^(NSTimer *timer) {
            __block NSViewController *found = nil;
            __block void (^walk)(NSViewController *) = ^(NSViewController *vc) {
                if ([NSStringFromClass([vc class]) isEqualToString:@"AppsViewController"]) found = vc;
                for (NSViewController *child in vc.childViewControllers) walk(child);
            };
            walk([self mainWindow].contentViewController);
            if (found == nil) return;
            TemporaryHost *h = [found valueForKey:@"host"];
            if (h == nil) return;
            fprintf(stderr, "APPLIST refresh %s\n", h.name.UTF8String);
            [found performSelector:NSSelectorFromString(@"discoverAppsForHost:") withObject:h];
        }];
    }
    if (getenv("MLC_SOAK")) {
        // no scene and no capture: the real app keeps running while the hosts are switched
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self runSoak]; });
        return;
    }
    if (getenv("MLC_FACTSSTRESS")) {
        // regression test of the DeckFactsStore lock deadlock: discovery-style ingests against main-thread writes, watchdog on the main queue
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [MLDeckSelfTest stressWithSpec:[NSString stringWithUTF8String:getenv("MLC_FACTSSTRESS")]];
        });
    }
    if (getenv("MLC_SELFTEST")) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [MLDeckSelfTest runWithXmlPath:[NSString stringWithUTF8String:getenv("MLC_SELFTEST")]];
        });
    }
    if (getenv("MLC_SELFTEST_CAP")) {
        // host capability 2 / capability 1 fixtures through the real parsers: "cap2.xml,cap1.xml,cap2-applist.xml"
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [MLDeckSelfTest runCapabilityWithSpec:[NSString stringWithUTF8String:getenv("MLC_SELFTEST_CAP")]];
        });
    }
    if (getenv("MLC_ADDADDR")) {
        // The add-by-address flow after OK in the sheet, then (MLC_PAIRUUID) the 配对 button of that host.
        NSString *address = [NSString stringWithUTF8String:getenv("MLC_ADDADDR")];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckHostCommand" object:nil userInfo:@{@"command": @"addAddress", @"address": address}];
        });
    }
    if (getenv("MLC_ADDR_DEFAULT")) {
        // "uuid|address": pin that address as the host's default
        NSArray *parts = [[NSString stringWithUTF8String:getenv("MLC_ADDR_DEFAULT")] componentsSeparatedByString:@"|"];
        if (parts.count == 2) [SettingsClass setConnectionMethod:parts[1] for:parts[0]];
    }
    if (getenv("MLC_POPOVER_STRESS")) {
        // open and close the 自定义主页 popover N times; the page's content frame must be identical after every cycle
        int cycles = atoi(getenv("MLC_POPOVER_STRESS"));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __block int index = 0, bad = 0;
            NSString *baseline = [MLDeckLayoutProbe frameString];
            fprintf(stderr, "POPSTRESS baseline=%s\n", baseline.UTF8String);
            __block void (^cycle)(void) = nil;
            cycle = ^{
                if (index >= cycles) {
                    fprintf(stderr, "POPSTRESS done cycles=%d mismatches=%d\n", cycles, bad);
                    return;
                }
                if (@available(macOS 14.0, *)) { [[MLDeckHomeCustomizer shared] show]; }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    NSString *open = [MLDeckLayoutProbe frameString];
                    if (@available(macOS 14.0, *)) { [[MLDeckHomeCustomizer shared] toggle:nil]; }
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        NSString *closed = [MLDeckLayoutProbe frameString];
                        BOOL same = [open isEqualToString:baseline] && [closed isEqualToString:baseline];
                        if (!same) { bad++; fprintf(stderr, "POPSTRESS cycle %d MISMATCH open=%s closed=%s\n", index, open.UTF8String, closed.UTF8String); }
                        index++;
                        cycle();
                    });
                });
            };
            cycle();
        });
    }
    if (getenv("MLC_STREAMRETURN")) {
        // a stream ending: the main window leaves and comes back; frames of it for 1.5 s from the return
        NSString *dir = getenv("MLC_FRAMEDIR") ? [NSString stringWithUTF8String:getenv("MLC_FRAMEDIR")] : @"/tmp/apps-concept/out/ret";
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        MLCWindowListCreateImage create = (MLCWindowListCreateImage)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSWindow *w = [self mainWindow];
            fprintf(stderr, "STREAMRETURN before titleVisibility=%ld toolbarVisible=%d\n", (long)w.titleVisibility, w.toolbar.isVisible);
            [w orderOut:nil];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [w makeKeyAndOrderFront:nil];
                for (int i = 0; i < 30; i++) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        if (create == NULL) return;
                        CGImageRef img = create(CGRectNull, kCGWindowListOptionIncludingWindow, (uint32_t)w.windowNumber, kCGWindowImageBoundsIgnoreFraming);
                        if (img != NULL) {
                            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
                            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"r-%02d.png", i]] atomically:NO];
                            CGImageRelease(img);
                        }
                    });
                }
                fprintf(stderr, "STREAMRETURN after titleVisibility=%ld toolbarVisible=%d\n", (long)w.titleVisibility, w.toolbar.isVisible);
            });
        });
    }
    if (getenv("MLC_SWEEP")) {
        // MLC_SWEEP="from,to,step[,pingpong]": the window's width is driven from..to in `step` pt on a 60 Hz timer
        // (MLC_SWEEPSHOT=dir: instead one step per 120 ms with a capture of the window after each, MLC_SWEEPHOLD ms).
        int from = 1000, to = 2560, step = 10, pingpong = 0;
        sscanf(getenv("MLC_SWEEP"), "%d,%d,%d,%d", &from, &to, &step, &pingpong);
        const char *shotDir = getenv("MLC_SWEEPSHOT");
        double hold = getenv("MLC_SWEEPHOLD") ? atof(getenv("MLC_SWEEPHOLD")) / 1000.0 : 0.12;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSWindow *w = [self mainWindow];
            NSMutableArray<NSNumber *> *widths = [NSMutableArray array];
            for (int x = from; x <= to; x += step) [widths addObject:@(x)];
            if (pingpong) for (int x = to - step; x >= from; x -= step) [widths addObject:@(x)];
            MLCWindowListCreateImage create = (MLCWindowListCreateImage)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
            if (shotDir) [[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithUTF8String:shotDir] withIntermediateDirectories:YES attributes:nil error:nil];
            __block NSUInteger index = 0;
            __block CFTimeInterval last = CACurrentMediaTime();
            __block double worst = 0, sum = 0;
            NSMutableArray<NSNumber *> *dts = [NSMutableArray array];
            NSTimeInterval interval = shotDir ? hold : 1.0 / 60.0;
            [NSTimer scheduledTimerWithTimeInterval:interval repeats:YES block:^(NSTimer *timer) {
                if (index >= widths.count) {
                    [timer invalidate];
                    if (!shotDir) {
                        NSArray *sorted = [dts sortedArrayUsingSelector:@selector(compare:)];
                        double p95 = sorted.count ? [sorted[(NSUInteger)(sorted.count * 0.95)] doubleValue] : 0;
                        fprintf(stderr, "SWEEPDONE frames=%lu mean_ms=%.2f p95_ms=%.2f max_ms=%.2f over_20ms=%d\n", (unsigned long)dts.count,
                                dts.count ? sum / dts.count * 1000 : 0, p95 * 1000, worst * 1000, (int)[[dts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self > 0.020"]] count]);
                    } else fprintf(stderr, "SWEEPDONE shots=%lu\n", (unsigned long)widths.count);
                    return;
                }
                CFTimeInterval now = CACurrentMediaTime();
                if (index > 0 && !shotDir) { double dt = now - last; [dts addObject:@(dt)]; sum += dt; if (dt > worst) worst = dt; }
                last = now;
                CGFloat width = widths[index].doubleValue;
                NSRect frame = w.frame;
                NSRect content = [w contentRectForFrameRect:frame];
                content.size.width = width;
                CFTimeInterval callStart = CACurrentMediaTime();
                [w setFrame:[w frameRectForContentRect:content] display:YES];
                CFTimeInterval callCost = CACurrentMediaTime() - callStart;
                static double callSum = 0, callMax = 0; static int callN = 0;
                callSum += callCost; callN++; if (callCost > callMax) callMax = callCost;
                if (callN % 100 == 0) fprintf(stderr, "SWEEPCALL n=%d mean_ms=%.2f max_ms=%.2f\n", callN, callSum / callN * 1000, callMax * 1000);
                if (shotDir && create) {
                    CGImageRef img = create(CGRectNull, kCGWindowListOptionIncludingWindow, (uint32_t)w.windowNumber, kCGWindowImageBoundsIgnoreFraming);
                    if (img) {
                        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
                        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[NSString stringWithFormat:@"%s/s-%04d.png", shotDir, (int)width] atomically:NO];
                        CGImageRelease(img);
                    }
                }
                index++;
            }];
        });
    }
    if (getenv("MLC_EDITSHEET")) {
        // MLC_EDITSHEET=info|menu|right : opens 编辑连接 the way the three entries do (the button in 主机信息, ⋯ > 编辑连接, the host's
        // right-click menu) and says in the log whether a sheet came up. With MLC_SHEETONLY the shot is the sheet itself.
        NSString *how = [NSString stringWithUTF8String:getenv("MLC_EDITSHEET")];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __block NSViewController *apps = nil, *hosts = nil;
            __block void (^walk)(NSViewController *) = ^(NSViewController *vc) {
                NSString *cls = NSStringFromClass([vc class]);
                if ([cls isEqualToString:@"AppsViewController"]) apps = vc;
                if ([cls isEqualToString:@"HostsViewController"]) hosts = vc;
                for (NSViewController *child in vc.childViewControllers) walk(child);
            };
            walk([self mainWindow].contentViewController);
            TemporaryHost *host = apps ? [apps valueForKey:@"host"] : nil;
            fprintf(stderr, "EDITSHEET how=%s apps=%d hosts=%d host=%s\n", how.UTF8String, apps != nil, hosts != nil, host.name.UTF8String ?: "(nil)");
            if ([how isEqualToString:@"info"] && apps) {
                [apps performSelector:NSSelectorFromString(@"deckAddConnection")];
            } else if ([how isEqualToString:@"menu"] && apps) {
                NSMenu *menu = [apps performSelector:NSSelectorFromString(@"deckHostMenuForApp:") withObject:nil];
                for (NSMenuItem *item in menu.itemArray) {
                    if ([item.representedObject isEqual:@"editor"]) {
                        [apps performSelector:NSSelectorFromString(@"deckHostMenuAction:") withObject:item];
                    }
                }
            } else if ([how isEqualToString:@"right"] && hosts && host) {
                NSMenuItem *item = [[NSMenuItem alloc] init];
                item.representedObject = host;
                [hosts performSelector:NSSelectorFromString(@"showConnectionEditor:") withObject:item];
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                fprintf(stderr, "EDITSHEET sheet=%d\n", [self mainWindow].attachedSheet != nil);
            });
        });
    }
    if (getenv("MLC_DETAILS")) {
        // The button that shows the Foundation Sunshine version (DeckFsLabel) posts exactly this: the 连接详情 sheet of the host.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __block NSViewController *apps = nil;
            __block void (^walk)(NSViewController *) = ^(NSViewController *vc) {
                if ([NSStringFromClass([vc class]) isEqualToString:@"AppsViewController"]) apps = vc;
                for (NSViewController *child in vc.childViewControllers) walk(child);
            };
            walk([self mainWindow].contentViewController);
            TemporaryHost *host = apps ? [apps valueForKey:@"host"] : nil;
            fprintf(stderr, "DETAILS apps=%d host=%s\n", apps != nil, host.name.UTF8String ?: "(nil)");
            [[self mainWindow] makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];   // a harness app launched in the background has no key window
            if (host) [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckHostCommand" object:nil
                userInfo:@{@"command": @"menu", @"host": host, @"action": @"details"}];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                fprintf(stderr, "DETAILS sheet=%d\n", [self mainWindow].attachedSheet != nil);
            });
        });
    }
    if (getenv("MLC_QUIET_AT")) {
        // holds the "a stream is open" state (MLNetworkQuiet) from MLC_QUIET_AT seconds for MLC_QUIET_FOR seconds (default 8)
        double at = atof(getenv("MLC_QUIET_AT")), length = getenv("MLC_QUIET_FOR") ? atof(getenv("MLC_QUIET_FOR")) : 8.0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            Log(LOG_I, @"[harness] simulated stream begins");
            [MLNetworkQuiet beginStream:@"harness-stream"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(length * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                Log(LOG_I, @"[harness] simulated stream ends");
                [MLNetworkQuiet end:@"harness-stream"];
            });
        });
    }
    if (getenv("MLC_TRYOPEN")) {
        // asks the apps page to start the host's first app, the way a click, a key or a menu item would (openApp:)
        // MLC_TRYOPEN=<n> asks n times, MLC_TRYOPEN_EVERY seconds apart (default 1.4), the first at MLC_TRYOPEN_AT (default 4)
        int tries = MAX(1, atoi(getenv("MLC_TRYOPEN")));
        double every = getenv("MLC_TRYOPEN_EVERY") ? atof(getenv("MLC_TRYOPEN_EVERY")) : 1.4;
        double first = getenv("MLC_TRYOPEN_AT") ? atof(getenv("MLC_TRYOPEN_AT")) : 4.0;
        for (int attempt = 0; attempt < tries; attempt++)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((first + attempt * every) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __block NSViewController *found = nil;
            __block void (^walk)(NSViewController *) = ^(NSViewController *vc) {
                if ([NSStringFromClass([vc class]) isEqualToString:@"AppsViewController"]) found = vc;
                for (NSViewController *child in vc.childViewControllers) walk(child);
            };
            walk([self mainWindow].contentViewController);
            if (found == nil) { fprintf(stderr, "TRYOPEN no apps page\n"); return; }
            TemporaryHost *h = [found valueForKey:@"host"];
            TemporaryApp *app = [[h.appList allObjects] firstObject];
            fprintf(stderr, "TRYOPEN host=%s state=%d pair=%d app=%s\n", h.displayName.UTF8String, (int)h.state, (int)h.pairState, app.name.UTF8String);
            [found performSelector:NSSelectorFromString(@"openApp:") withObject:app];
            fprintf(stderr, "TRYOPEN %d returned\n", attempt);
        });
    }
    if (getenv("MLC_ADDSHEET")) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // exactly what the toolbar ＋ does: the action goes to the first responder chain
            NSToolbarItem *plus = nil;
            for (NSToolbarItem *item in [self mainWindow].toolbar.items) {
                if (item.action == NSSelectorFromString(@"addHostButtonClicked:")) plus = item;
            }
            NSButton *button = [plus.view isKindOfClass:[NSButton class]] ? (NSButton *)plus.view : nil;
            fprintf(stderr, "ConceptHarness: toolbar add item found=%d enabled=%d target=%s\n", plus != nil, plus.enabled,
                    NSStringFromClass([button.target class]).UTF8String ?: "(nil)");
            [button performClick:nil];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSWindow *w = [self mainWindow];
            fprintf(stderr, "ConceptHarness: add-host sheet shown=%d\n", w.attachedSheet != nil);
            if (w.attachedSheet != nil && !getenv("MLC_SHEETONLY")) [w endSheet:w.attachedSheet];
        });
    }
    if (getenv("MLC_PAIRUUID")) {
        NSString *pairUUID = [NSString stringWithUTF8String:getenv("MLC_PAIRUUID")];
        double pairDelay = getenv("MLC_PAIR_DELAY") ? atof(getenv("MLC_PAIR_DELAY")) : 7.0;   // seconds; the 配对 button is pressed this long after the window
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(pairDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"pair", @"command", pairUUID, @"uuid", nil];
            for (TemporaryHost *h in [[[DataManager alloc] init] getHosts]) {
                if ([h.uuid isEqualToString:pairUUID]) info[@"host"] = h;
            }
            // a computer found by discovery is not necessarily stored yet: the command can name it by uuid
            [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckHostCommand" object:nil userInfo:info];
        });
    }
    if (getenv("MLC_PAIR_AFTER_ARRIVAL")) {
        // MLC_PAIR_AFTER_ARRIVAL=<seconds>: press 配对 that long after a computer has arrived from the no-host page (the nudge on the button has played)
        double after = atof(getenv("MLC_PAIR_AFTER_ARRIVAL"));
        __block id arrivedObserver = nil;
        arrivedObserver = [[NSNotificationCenter defaultCenter] addObserverForName:@"MLDeckHostArrived" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            [[NSNotificationCenter defaultCenter] removeObserver:arrivedObserver];
            NSString *uuid = note.userInfo[@"uuid"] ?: @"";
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckHostCommand" object:nil userInfo:@{@"command": @"pair", @"uuid": uuid}];
            });
        }];
    }
    double settle = getenv("MLC_SETTLE") ? atof(getenv("MLC_SETTLE")) : 2.5;
    if (getenv("MLC_REC60")) {
        // the scene must not end the process before the recording has its span (and its files are written)
        double span = getenv("MLC_FRAMESPAN") ? atof(getenv("MLC_FRAMESPAN")) : 6.0;
        settle = MAX(settle, span + 3.0);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self prepareWindow];
        [self openScene];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(settle * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (getenv("MLC_PAD") != NULL) {
                [self runPadScript];
            } else {
                [self captureAndQuit];
            }
        });
    });
}

// MARK: - Scripted pad (Deck gamepad walk)

/// MLC_PAD="tok,tok,...": every token is a pad button pressed through ControllerNavigation's own polling
/// (u d l r a b x y menu view lb rb), the same button through the raw DualSense mapping (R + button, e.g. Ra),
/// or wait=<ms>, shot=<name>, log=<text>, expect=<focus key>, expectwin=<main|sheet|other>. After every press the
/// focus state is logged as "PAD <n> <token> <state>"; MLC_PAD_OUT is the directory of the shots, MLC_PAD_STEP the
/// pause after a press in ms (default 450).
+ (uint32_t)padMaskForToken:(NSString *)token {
    static NSDictionary<NSString *, NSNumber *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{@"u": @(DS5UI_UP), @"d": @(DS5UI_DOWN), @"l": @(DS5UI_LEFT), @"r": @(DS5UI_RIGHT), @"a": @(DS5UI_A), @"b": @(DS5UI_B),
                @"x": @(DS5UI_X), @"y": @(DS5UI_Y), @"menu": @(DS5UI_MENU), @"view": @(DS5UI_VIEW), @"lb": @(DS5UI_LB), @"rb": @(DS5UI_RB),
                @"lt": @(DS5UI_LT), @"rt": @(DS5UI_RT)};
    });
    return map[token].unsignedIntValue;
}

/// The DualSense report a button press is in the raw path: core buttons, hat, left stick.
+ (NSDictionary *)padRawForToken:(NSString *)token {
    NSDictionary *buttons = @{@"a": @(1 << DS5UI_CORE_CROSS), @"b": @(1 << DS5UI_CORE_CIRCLE), @"x": @(1 << DS5UI_CORE_SQUARE),
                              @"y": @(1 << DS5UI_CORE_TRIANGLE), @"menu": @(1 << DS5UI_CORE_OPTIONS), @"view": @(1 << DS5UI_CORE_CREATE),
                              @"lb": @(1 << DS5UI_CORE_L1), @"rb": @(1 << DS5UI_CORE_R1)};
    NSDictionary *hats = @{@"u": @0, @"r": @2, @"d": @4, @"l": @6};
    // the triggers are analog in this path: a full pull
    return @{@"buttons": buttons[token] ?: @0, @"hat": hats[token] ?: @8, @"lx": @128, @"ly": @128,
             @"lt": @([token isEqualToString:@"lt"] ? 255 : 0), @"rt": @([token isEqualToString:@"rt"] ? 255 : 0)};
}

+ (void)padShot:(NSString *)path {
    NSWindow *w = [self mainWindow];
    MLCWindowListCreateImage create = (MLCWindowListCreateImage)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    if (create == NULL || w == nil) return;
    // the window with everything above it (sheet, popover, focus ring, hint legend), as the window server composes it
    CGFloat screenHeight = NSScreen.screens.firstObject.frame.size.height;
    CGRect cgRect = CGRectMake(w.frame.origin.x, screenHeight - NSMaxY(w.frame), w.frame.size.width, w.frame.size.height);
    CGImageRef img = create(cgRect, kCGWindowListOptionOnScreenAboveWindow | kCGWindowListOptionIncludingWindow,
                            (uint32_t)w.windowNumber, kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution);
    if (img == NULL) return;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
    CGImageRelease(img);
    fprintf(stderr, "PAD shot %s\n", path.UTF8String);
}

static NSString *sPadMark = @"";

// kind, key and place of the focused control (a line to compare, not to read)
+ (NSString *)padFocusSignature {
    NSString *state = [ControllerNavigation harnessState];
    NSRange from = [state rangeOfString:@"kind="];
    NSRange to = [state rangeOfString:@" ring="];
    if (from.location == NSNotFound || to.location == NSNotFound || to.location < from.location) return @"none";
    return [state substringWithRange:NSMakeRange(from.location, to.location - from.location)];
}

+ (void)runPadScript {
    NSArray<NSString *> *tokens = [[NSString stringWithUTF8String:getenv("MLC_PAD")] componentsSeparatedByString:@","];
    NSString *dir = getenv("MLC_PAD_OUT") ? [NSString stringWithUTF8String:getenv("MLC_PAD_OUT")] : @"/tmp/apps-concept/out/pad";
    double step = getenv("MLC_PAD_STEP") ? atof(getenv("MLC_PAD_STEP")) / 1000.0 : 0.45;
    __block NSUInteger index = 0;
    __block int pressCount = 0;
    __block void (^next)(void) = nil;
    next = ^{
        if (index >= tokens.count) {
            fprintf(stderr, "PAD done presses=%d\n", pressCount);
            [NSApp terminate:nil];
            return;
        }
        NSString *token = tokens[index++];
        double delay = step;
        if ([token hasPrefix:@"wait="]) {
            delay = atof([token substringFromIndex:5].UTF8String) / 1000.0;
        } else if ([token hasPrefix:@"shot="]) {
            [self padShot:[dir stringByAppendingPathComponent:[[token substringFromIndex:5] stringByAppendingString:@".png"]]];
            delay = 0.05;
        } else if ([token hasPrefix:@"log="]) {
            fprintf(stderr, "PAD log %s | %s\n", [token substringFromIndex:4].UTF8String, [ControllerNavigation harnessState].UTF8String);
            delay = 0.05;
        } else if ([token hasPrefix:@"alert="]) {
            // an alert sheet the way the host menu's 移除 and the pairing flows show one
            NSAlert *alert = [[NSAlert alloc] init];
            alert.alertStyle = NSAlertStyleWarning;
            alert.messageText = [token substringFromIndex:6];
            alert.informativeText = @"This is a scripted alert sheet.";
            [alert addButtonWithTitle:@"Remove"];
            [alert addButtonWithTitle:@"Cancel"];
            [alert beginSheetModalForWindow:[self mainWindow] completionHandler:^(NSModalResponse code) {
                fprintf(stderr, "PAD alert returned %ld\n", (long)code);
            }];
            delay = 0.9;
        } else if ([token isEqualToString:@"streamreturn"]) {
            // a stream ending: the main window leaves and comes back
            NSWindow *w = [self mainWindow];
            [w orderOut:nil];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [w makeKeyAndOrderFront:nil]; });
            delay = 1.6;
        } else if ([token isEqualToString:@"rebuild"]) {
            // the host list and the pages are rebuilt (discovery, an app list update)
            [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckHostsChanged" object:nil];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckAppListTick" object:nil];
            delay = 1.0;
        } else if ([token isEqualToString:@"mouse"]) {
            // the pointer moves: the pad's ring goes away (the local event monitor sees every event sent to the app)
            [[NSNotificationCenter defaultCenter] postNotificationName:@"MLControllerPointerArmed" object:nil];
            NSEvent *move = [NSEvent mouseEventWithType:NSEventTypeMouseMoved location:NSMakePoint(400, 300) modifierFlags:0
                                              timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:[self mainWindow].windowNumber
                                                context:nil eventNumber:0 clickCount:0 pressure:0];
            [NSApp sendEvent:move];
            delay = 0.4;
        } else if ([token isEqualToString:@"mark"]) {
            // remembers where the focus is, for expectmoved
            sPadMark = [self padFocusSignature];
            delay = 0.02;
        } else if ([token hasPrefix:@"expectmoved="]) {
            BOOL wanted = [token substringFromIndex:12].intValue != 0;
            NSString *now = [self padFocusSignature];
            BOOL moved = ![now isEqualToString:sPadMark];
            fprintf(stderr, "PAD expectmoved %d %s | %s\n", wanted, moved == wanted ? "OK" : "FAIL", now.UTF8String);
            sPadMark = now;
            delay = 0.02;
        } else if ([token hasPrefix:@"expectno="]) {
            // no reachable control matches (the targets line is "kind key x,y,WxH ; ..."): the computer sidebar is out of the graph
            NSString *unwanted = [token substringFromIndex:9];
            NSString *targets = [ControllerNavigation harnessTargets];
            fprintf(stderr, "PAD expectno %s %s\n", unwanted.UTF8String, [targets containsString:unwanted] ? "FAIL" : "OK");
            delay = 0.02;
        } else if ([token hasPrefix:@"expectsettings="]) {
            // whether the settings window is on screen (1) or closed (0)
            BOOL open = NO;
            for (NSWindow *candidate in NSApp.windows) {
                if (candidate.isVisible && [candidate.identifier isEqualToString:@"ClientSettingsWindow"]) open = YES;
            }
            BOOL wanted = [token substringFromIndex:15].intValue != 0;
            fprintf(stderr, "PAD expectsettings %d %s | %s\n", wanted, open == wanted ? "OK" : "FAIL", [ControllerNavigation harnessState].UTF8String);
            delay = 0.02;
        } else if ([token isEqualToString:@"targets"]) {
            fprintf(stderr, "PAD targets %s\n", [ControllerNavigation harnessTargets].UTF8String);
            delay = 0.05;
        } else if ([token hasPrefix:@"expect="]) {
            NSString *wanted = [token substringFromIndex:7];
            NSString *actual = [ControllerNavigation harnessFocusedKey];
            BOOL ok = [wanted hasSuffix:@"*"] ? [actual hasPrefix:[wanted substringToIndex:wanted.length - 1]] : [actual isEqualToString:wanted];
            fprintf(stderr, "PAD expect %s actual=%s %s\n", wanted.UTF8String, actual.UTF8String, ok ? "OK" : "FAIL");
            delay = 0.02;
        } else if ([token hasPrefix:@"expectstate="]) {
            NSString *wanted = [token substringFromIndex:12];
            NSString *state = [ControllerNavigation harnessState];
            fprintf(stderr, "PAD expectstate %s %s | %s\n", wanted.UTF8String, [state containsString:wanted] ? "OK" : "FAIL", state.UTF8String);
            delay = 0.02;
        } else {
            BOOL raw = [token hasPrefix:@"R"] && token.length > 1;
            NSString *name = raw ? [token substringFromIndex:1] : token;
            pressCount++;
            if (raw) {
                [[NSNotificationCenter defaultCenter] postNotificationName:@"MLControllerInjectRaw" object:nil userInfo:[self padRawForToken:name]];
            } else {
                uint32_t mask = [self padMaskForToken:name];
                if (mask == 0) {
                    fprintf(stderr, "PAD unknown token %s\n", token.UTF8String);
                } else {
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"MLControllerInject" object:nil userInfo:@{@"mask": @(mask)}];
                }
            }
            int number = pressCount;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(step * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                fprintf(stderr, "PAD %d %s t=%.2f %s\n", number, token.UTF8String, NSProcessInfo.processInfo.systemUptime, [ControllerNavigation harnessState].UTF8String);
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((delay + 0.03) * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
    };
    fprintf(stderr, "PAD start tokens=%lu\n", (unsigned long)tokens.count);
    next();
}

+ (NSWindow *)mainWindow {
    if (sOverlayWindow != nil) return sOverlayWindow;
    if (sLogViewerWindow != nil) return sLogViewerWindow;
    if (sSettingsWindowController.window != nil) return sSettingsWindowController.window;
    NSWindow *w = [Helpers getMainWindow];
    if (w == nil) w = NSApp.windows.firstObject;
    return w;
}

+ (void)prepareWindow {
    NSString *ap = getenv("MLC_APPEARANCE") ? [NSString stringWithUTF8String:getenv("MLC_APPEARANCE")] : @"light";
    // "system": the app's own theme setting at its default (follow the system), the usual configuration
    if ([ap isEqualToString:@"system"]) NSApp.appearance = nil;
    else NSApp.appearance = [NSAppearance appearanceNamed:[ap isEqualToString:@"dark"] ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    NSWindow *w = [self mainWindow];
    int width = 1280, height = 800;
    if (getenv("MLC_SIZE")) sscanf(getenv("MLC_SIZE"), "%dx%d", &width, &height);
    // MLC_WINX: the window's left edge (the default 20): a window pushed against the right edge of the screen puts the toolbar button,
    // and so the popover's anchor, there
    [w setFrame:NSMakeRect(getenv("MLC_WINX") ? atof(getenv("MLC_WINX")) : 20,
                           getenv("MLC_WINY") ? atof(getenv("MLC_WINY")) : ((getenv("MLC_ICONPICKER") || getenv("MLC_CUSTOMIZE")) ? 120 : -60),
                           width, height) display:YES];
    [w makeKeyAndOrderFront:nil];
}

+ (void)openOverlayScene {
    NSWindow *main = [Helpers getMainWindow] ?: NSApp.windows.firstObject;
    [main orderOut:nil];
    int width = 1280, height = 800;
    if (getenv("MLC_SIZE")) sscanf(getenv("MLC_SIZE"), "%dx%d", &width, &height);
    BOOL notchSim = getenv("MLC_OV_NOTCHSIM") != NULL;
    NSWindowStyleMask mask = notchSim ? NSWindowStyleMaskBorderless
        : (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(20, -60, width, height) styleMask:mask backing:NSBackingStoreBuffered defer:NO];
    window.titlebarAppearsTransparent = YES;
    window.titleVisibility = NSWindowTitleHidden;
    window.releasedWhenClosed = NO;
    NSString *frameName = getenv("MLC_OV_FRAME") ? [NSString stringWithUTF8String:getenv("MLC_OV_FRAME")] : @"bright";
    NSString *posters = [NSString stringWithUTF8String:getenv("MLC_POSTERS") ?: ""];
    MLCFrameView *view = [[MLCFrameView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    view.frameImage = [[NSImage alloc] initWithContentsOfFile:[posters stringByAppendingPathComponent:[NSString stringWithFormat:@"frame_%@.jpg", frameName]]];
    if (notchSim) {
        view.notchWidth = 200;
        view.notchHeight = 38;
        [MLOverlayFixture simulateNotchWithScreenWidth:width screenHeight:height band:38 notchWidth:200];
    }
    window.contentView = view;
    [window setFrame:NSMakeRect(20, -60, width, height) display:YES];
    [window makeKeyAndOrderFront:nil];
    sOverlayWindow = window;
    BOOL anomaly = getenv("MLC_OV_ANOMALY") != NULL;
    if (getenv("MLC_OV_STYLE") && strcmp(getenv("MLC_OV_STYLE"), "legacy") == 0) {
        NSTextField *label = nil;
        NSVisualEffectView *container = [MLLegacyOverlay makeContainerWithLabel:&label];
        [view addSubview:container];
        MLOverlayMetrics *m = [MLOverlayFixture mockMetricsWithTick:60 anomaly:anomaly];
        label.attributedStringValue = [MLLegacyOverlay attributedStringForMetrics:m];
        [MLLegacyOverlay layoutContainer:container label:label inParent:view];
    } else {
        NSObject *presenter = [MLOverlayFixture attachTo:view anomaly:anomaly];
        if (getenv("MLC_OV_STABILITY") != NULL && presenter != nil) {
            // values change for N seconds at the real tick rate; the panel's frame is measured (see OverlayFixture.runStability)
            NSString *report = getenv("MLC_OV_STABILITY_OUT") ? [NSString stringWithUTF8String:getenv("MLC_OV_STABILITY_OUT")] : @"/tmp/apps-concept/out/stability.txt";
            [MLOverlayFixture runStabilityOn:presenter seconds:atoi(getenv("MLC_OV_STABILITY")) warnings:getenv("MLC_OV_WARN") != NULL path:report];
            if (getenv("MLC_OV_FRAMES") != NULL) {
                NSString *dir = [NSString stringWithUTF8String:getenv("MLC_OV_FRAMES")];
                for (int t = 2; t <= atoi(getenv("MLC_OV_STABILITY")); t += 1) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [self captureWindowTo:[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"t%02d.png", t]]];
                    });
                }
            }
        }
        // Click-through check: a click in the middle of the overlay must reach the stream view, not the overlay.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            for (NSView *sub in view.subviews) {
                if (![NSStringFromClass([sub class]) containsString:@"OverlayHostView"]) continue;
                NSPoint center = NSMakePoint(NSMidX(sub.frame), NSMidY(sub.frame));
                NSView *hit = [view hitTest:center];
                fprintf(stderr, "ConceptHarness: click-through hitTest at overlay centre -> %s (overlay frame %.0f,%.0f %.0fx%.0f)\n",
                        NSStringFromClass([hit class]).UTF8String, sub.frame.origin.x, sub.frame.origin.y, sub.frame.size.width, sub.frame.size.height);
            }
        });
    }
}

// The control ball in a stand-in stream window: the real MLEdgeMenuHandleView at the frame the real
// MLEdgeMenuComputeFrame gives. MLC_ORB_MODE = borderless | fullscreen (notch band simulated) | windowed;
// MLC_ORB_STATE = idle (tucked) | shown (docked); MLC_ORB_DOCK = right | left | top | bottom; MLC_ORB_RATIO.
+ (void)openOrbScene {
    NSWindow *main = [Helpers getMainWindow] ?: NSApp.windows.firstObject;
    [main orderOut:nil];
    const char *modeEnv = getenv("MLC_ORB_MODE");
    NSString *mode = modeEnv ? [NSString stringWithUTF8String:modeEnv] : @"borderless";
    BOOL tucked = !(getenv("MLC_ORB_STATE") && strcmp(getenv("MLC_ORB_STATE"), "shown") == 0);
    NSString *dockName = getenv("MLC_ORB_DOCK") ? [NSString stringWithUTF8String:getenv("MLC_ORB_DOCK")] : @"right";
    CGFloat ratio = getenv("MLC_ORB_RATIO") ? atof(getenv("MLC_ORB_RATIO")) : 0.5;
    int width = 1920, height = 1080;
    if (getenv("MLC_SIZE")) sscanf(getenv("MLC_SIZE"), "%dx%d", &width, &height);
    BOOL windowed = [mode isEqualToString:@"windowed"];
    BOOL notch = [mode isEqualToString:@"fullscreen"];
    NSWindowStyleMask mask = windowed
        ? (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
        : NSWindowStyleMaskBorderless;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, height) styleMask:mask backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    NSString *posters = [NSString stringWithUTF8String:getenv("MLC_POSTERS") ?: ""];
    NSString *frameName = getenv("MLC_OV_FRAME") ? [NSString stringWithUTF8String:getenv("MLC_OV_FRAME")] : @"bright";
    MLCFrameView *view = [[MLCFrameView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    view.frameImage = [[NSImage alloc] initWithContentsOfFile:[posters stringByAppendingPathComponent:[NSString stringWithFormat:@"frame_%@.jpg", frameName]]];
    MLEdgeMenuInsets safe = {0, 0, 0, 0};
    if (notch) { view.notchWidth = 200; view.notchHeight = 38; safe.top = 38; }
    window.contentView = view;
    [window setFrameOrigin:NSMakePoint(0, 0)];
    [window makeKeyAndOrderFront:nil];
    sOverlayWindow = window;

    MLEdgeMenuMetrics m = { .size = MLEdgeMenuButtonWidth, .plateRatio = MLEdgeMenuPlateRatio, .plateEdgeGap = MLEdgeMenuPlateEdgeGap,
                            .collapsedFraction = MLEdgeMenuCollapsedPlateFraction, .crossInset = MLEdgeMenuButtonInsetY };
    MLEdgeMenuDock dock = MLEdgeMenuDockRight;
    if ([dockName isEqualToString:@"left"]) dock = MLEdgeMenuDockLeft;
    else if ([dockName isEqualToString:@"top"]) dock = MLEdgeMenuDockTop;
    else if ([dockName isEqualToString:@"bottom"]) dock = MLEdgeMenuDockBottom;
    NSRect bounds = view.bounds;
    CGRect frame = MLEdgeMenuComputeFrame(NSRectToCGRect(bounds), safe, dock, ratio, tucked, m);
    MLEdgeMenuHandleView *ball = [[MLEdgeMenuHandleView alloc] initWithFrame:NSRectFromCGRect(frame)];
    NSImage *image = [NSImage imageWithSystemSymbolName:@"slider.horizontal.3" accessibilityDescription:nil];
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:18 weight:NSFontWeightSemibold scale:NSImageSymbolScaleLarge];
    ball.iconView.image = [image imageWithSymbolConfiguration:config];
    MLFreeMouseExitEdge edge = dock == MLEdgeMenuDockLeft ? MLFreeMouseExitEdgeLeft : dock == MLEdgeMenuDockTop ? MLFreeMouseExitEdgeTop
        : dock == MLEdgeMenuDockBottom ? MLFreeMouseExitEdgeBottom : MLFreeMouseExitEdgeRight;
    ball.dockEdge = edge;
    ball.compactAppearance = tucked;
    ball.activeAppearance = !tucked;
    [view addSubview:ball];
    CGRect visible = MLEdgeMenuVisiblePlate(frame, NSRectToCGRect(bounds), m);
    double plate = m.size * m.plateRatio;
    fprintf(stderr, "ConceptHarness: orb mode=%s state=%s dock=%s window=%dx%d frame={%.1f,%.1f,%.0f,%.0f} plateVisible=%.0f%% (%.1f of %.1f pt across the edge) safeTop=%.0f\n",
            mode.UTF8String, tucked ? "idle" : "shown", dockName.UTF8String, width, height, frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
            visible.size.width * visible.size.height / (plate * plate) * 100.0, (dock == MLEdgeMenuDockLeft || dock == MLEdgeMenuDockRight) ? visible.size.width : visible.size.height, plate, safe.top);
}

+ (void)openSettingsScene {
    NSWindow *main = [Helpers getMainWindow] ?: NSApp.windows.firstObject;
    [main orderOut:nil];
    // the App pane of the real settings window ("selected-settings-pane" = 3)
    NSInteger pane = getenv("MLC_PANE") ? atoi(getenv("MLC_PANE")) : 3;
    [[NSUserDefaults standardUserDefaults] setInteger:pane forKey:@"selected-settings-pane"];
    sSettingsWindowController = [SettingsWindowObjCBridge makeSettingsWindowWithHostId:nil];
    int width = 980, height = 1500;
    if (getenv("MLC_SIZE")) sscanf(getenv("MLC_SIZE"), "%dx%d", &width, &height);
    [sSettingsWindowController showWindow:nil];
    int winY = getenv("MLC_WINY") ? atoi(getenv("MLC_WINY")) : -300;
    [sSettingsWindowController.window setFrame:NSMakeRect(20, winY, width, height) display:YES];
    if (getenv("MLC_LINECHECK")) {
        // the size the settings window really opens at, content area: SettingsHostingController
        [sSettingsWindowController.window setContentSize:NSMakeSize(960, 680)];
        [SettingsLineCheckDriver run];
    }
    [sSettingsWindowController.window makeKeyAndOrderFront:nil];
    if (getenv("MLC_SCROLL")) {
        // MLC_SCROLL=bottom (or a number of points): the pane's largest scroll view scrolled to its end (the Advanced section of the Input pane)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSScrollView *best = nil;
            NSMutableArray<NSView *> *queue = [NSMutableArray arrayWithObject:sSettingsWindowController.window.contentView];
            while (queue.count > 0) {
                NSView *v = queue.firstObject; [queue removeObjectAtIndex:0];
                if ([v isKindOfClass:[NSScrollView class]] && (best == nil || v.frame.size.width > best.frame.size.width)) best = (NSScrollView *)v;
                [queue addObjectsFromArray:v.subviews];
            }
            NSView *doc = best.documentView;
            if (doc != nil) {
                CGFloat y = doc.isFlipped ? MAX(0, NSHeight(doc.frame) - NSHeight(best.contentView.bounds)) : 0;
                if (isdigit(getenv("MLC_SCROLL")[0])) y = MIN(y, atof(getenv("MLC_SCROLL")));   // a number: that many points down
                [best.contentView scrollToPoint:NSMakePoint(0, y)];
                [best reflectScrolledClipView:best.contentView];
            }
            fprintf(stderr, "ConceptHarness: scrolled %s\n", doc != nil ? "yes" : "no scroll view");
        });
    }
    if (getenv("MLC_BTWARN")) {
        // The Full Bluetooth Haptics warning over the settings window (pane 2 = Input); MLC_SETTLE decides how far
        // into its 5 s countdown the picture is taken, MLC_SHEETCOMP=1 puts the sheet in the picture.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // MLC_BTWARN=act: only the scripted steps below, the sheet comes from the real switch
            if (strcmp(getenv("MLC_BTWARN"), "act") != 0)
            [MLBluetoothFullHapticsWarning presentOn:sSettingsWindowController.window completion:^(BOOL confirmed) {
                fprintf(stderr, "ConceptHarness: btwarn answered %d\n", confirmed);
            }];
        });
        // MLC_BTWARN_ACT=<token>@<seconds>,...: esc = Esc key, click = the second button, log = every sheet button's state
        const char *act = getenv("MLC_BTWARN_ACT");
        if (act) {
            for (NSString *step in [[NSString stringWithUTF8String:act] componentsSeparatedByString:@","]) {
                NSArray<NSString *> *parts = [step componentsSeparatedByString:@"@"];
                if (parts.count != 2) continue;
                NSString *token = parts[0];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(parts[1].doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    NSWindow *sheet = sSettingsWindowController.window.attachedSheet;
                    NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
                    NSMutableArray<NSView *> *queue = [NSMutableArray arrayWithObject:sheet.contentView ?: [NSView new]];
                    while (queue.count > 0) {
                        NSView *v = queue.firstObject; [queue removeObjectAtIndex:0];
                        if ([v isKindOfClass:[NSButton class]]) [buttons addObject:(NSButton *)v];
                        [queue addObjectsFromArray:v.subviews];
                    }
                    if ([token isEqualToString:@"views"] || [token isEqualToString:@"vtoggle"] || [token isEqualToString:@"vvalue"]) {
                        // the last NSSwitch / switch-type NSButton in the settings window: print, press or read it
                        NSControl *found = nil;
                        NSMutableArray<NSView *> *q = [NSMutableArray arrayWithObject:sSettingsWindowController.window.contentView];
                        while (q.count > 0) {
                            NSView *v = q.firstObject; [q removeObjectAtIndex:0];
                            NSString *cn = NSStringFromClass([v class]);
                            BOOL isSwitch = [cn containsString:@"Switch"] || ([v isKindOfClass:[NSButton class]] && [(NSButton *)v bezelStyle] == 0 && [cn containsString:@"Toggle"]);
                            if (isSwitch && [v isKindOfClass:[NSControl class]]) {
                                found = (NSControl *)v;
                                if ([token isEqualToString:@"views"]) fprintf(stderr, "ConceptHarness: btwarn view %s y=%.0f value=%ld\n", cn.UTF8String, [v convertPoint:NSZeroPoint toView:nil].y, (long)[(NSControl *)v integerValue]);
                            }
                            [q addObjectsFromArray:v.subviews];
                        }
                        if ([token isEqualToString:@"vvalue"]) fprintf(stderr, "ConceptHarness: btwarn vvalue %ld\n", found ? (long)found.integerValue : -1L);
                        if ([token isEqualToString:@"vtoggle"] && found) { fprintf(stderr, "ConceptHarness: btwarn vtoggle press (value was %ld)\n", (long)found.integerValue); [found performClick:nil]; }
                    } else if ([token isEqualToString:@"axtoggle"] || [token isEqualToString:@"axvalue"]) {
                        // the last switch of the settings window (the Advanced "Full Bluetooth Haptics" row): press it / read its value
                        id found = nil;
                        NSMutableArray *q = [NSMutableArray arrayWithObject:sSettingsWindowController.window];
                        while (q.count > 0) {
                            id el = q.firstObject; [q removeObjectAtIndex:0];
                            NSString *role = [el respondsToSelector:@selector(accessibilityRole)] ? [el accessibilityRole] : nil;
                            if ([role isEqualToString:NSAccessibilityCheckBoxRole] || [role isEqualToString:@"AXSwitch"]) found = el;
                            NSArray *kids = [el respondsToSelector:@selector(accessibilityChildren)] ? [el accessibilityChildren] : nil;
                            if (kids) [q addObjectsFromArray:kids];
                        }
                        fprintf(stderr, "ConceptHarness: btwarn %s value=%s\n", token.UTF8String, found ? [[found accessibilityValue] description].UTF8String : "no switch");
                        if ([token isEqualToString:@"axtoggle"] && found) [found accessibilityPerformPress];
                    } else if ([token isEqualToString:@"log"]) {
                        for (NSButton *b in buttons) fprintf(stderr, "ConceptHarness: btwarn button \"%s\" enabled=%d default=%d\n", b.title.UTF8String, b.isEnabled, [b.keyEquivalent isEqualToString:@"\r"]);
                        if (sheet == nil) fprintf(stderr, "ConceptHarness: btwarn no sheet\n");
                    } else if ([token isEqualToString:@"click"]) {
                        for (NSButton *b in buttons) if (b.tag == NSAlertSecondButtonReturn || [b.title hasPrefix:@"Turn On"] || [b.title hasPrefix:@"仍要开启"]) { fprintf(stderr, "ConceptHarness: btwarn click \"%s\" enabled=%d\n", b.title.UTF8String, b.isEnabled); [b performClick:nil]; break; }
                    } else if ([token isEqualToString:@"esc"]) {
                        NSEvent *e = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:sheet.windowNumber
                                                       context:nil characters:@"\x1b" charactersIgnoringModifiers:@"\x1b" isARepeat:NO keyCode:53];
                        [NSApp sendEvent:e];
                    }
                });
            }
        }
    }
}

+ (void)openScene {
    NSString *scene = getenv("MLC_SCENE") ? [NSString stringWithUTF8String:getenv("MLC_SCENE")] : @"hosts";
    if ([scene isEqualToString:@"overlay"]) { [self openOverlayScene]; return; }
    if ([scene isEqualToString:@"orb"]) { [self openOrbScene]; return; }
    if ([scene isEqualToString:@"settings"]) { [self openSettingsScene]; return; }
    NSString *uuid = getenv("MLC_HOST") ? [NSString stringWithUTF8String:getenv("MLC_HOST")] : @"0A11-GAMINGPC-LIVE";
    if (getenv("MLC_PIN")) {
        // A pairing in progress: the PIN is shown inline on the host.
        NSString *pin = [NSString stringWithUTF8String:getenv("MLC_PIN")];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckPairingPIN" object:nil userInfo:@{@"uuid": uuid, @"pin": pin}];
        });
    }
    if (getenv("MLC_PAIRFAIL")) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckPairingFailed" object:nil
                                                              userInfo:@{@"uuid": uuid, @"message": @"PIN 不正确,或另一台电脑正在配对。"}];
        });
    }
    if (getenv("MLC_CUSTOMIZE")) {
        // The 自定义主页 popover open, with a row mid-drag when MLC_DRAG / MLC_DROP are set.
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        if (getenv("MLC_DRAG")) info[@"drag"] = [NSString stringWithUTF8String:getenv("MLC_DRAG")];
        if (getenv("MLC_DROP")) info[@"drop"] = [NSString stringWithUTF8String:getenv("MLC_DROP")];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckCustomize" object:nil userInfo:info];
        });
    }
    if (getenv("MLC_ICONPICKER")) {
        NSString *pickerHost = [NSString stringWithUTF8String:getenv("MLC_ICONPICKER")];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckIconPicker" object:nil userInfo:@{@"uuid": pickerHost}];
        });
    }
    if (getenv("MLC_EMPHASIZE") && getenv("MLC_INACTIVE") == NULL) {
        // The login-window Mac cannot give the app real focus; make the sidebar list the first responder of the (reported key)
        // window so its selection is drawn the way it is in use: the accent fill.
        void (^emphasize)(void) = ^{
            NSWindow *win = [self mainWindow];
            NSMutableArray<NSView *> *queue = [NSMutableArray arrayWithObject:win.contentView];
            while (queue.count > 0) {
                NSView *v = queue.firstObject; [queue removeObjectAtIndex:0];
                if ([v isKindOfClass:[NSTableView class]] && v.frame.size.width < 400) {
                    [win makeFirstResponder:v]; [v setNeedsDisplay:YES];
                    fprintf(stderr, "ConceptHarness: emphasized %s\n", NSStringFromClass([v class]).UTF8String);
                    return;
                }
                [queue addObjectsFromArray:v.subviews];
            }
        };
        for (double t = 2.0; t < 12.0; t += 2.0)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t * NSEC_PER_SEC)), dispatch_get_main_queue(), emphasize);
    }
    if (![scene isEqualToString:@"apps"]) return;
    if ([[self variant] hasPrefix:@"A"]) {
        // The window already shows the host list; pick the host in the sidebar.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckSelectHost" object:nil userInfo:@{@"uuid": uuid}];
        });
        return;
    }
    NSWindow *w = [self mainWindow];
    for (NSViewController *vc in w.contentViewController.childViewControllers) {
        if ([vc respondsToSelector:NSSelectorFromString(@"transitionToAppsVCWithHost:")]) {
            for (TemporaryHost *h in [vc valueForKey:@"hosts"]) {
                if ([h.uuid isEqualToString:uuid]) {
                    [vc performSelector:NSSelectorFromString(@"transitionToAppsVCWithHost:") withObject:h];
                    return;
                }
            }
        }
    }
}

// One picture of the main window to `path` (the stability run takes several while the values change).
+ (void)captureWindowTo:(NSString *)path {
    NSWindow *w = [self mainWindow];
    MLCWindowListCreateImage create = (MLCWindowListCreateImage)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    if (create == NULL || w == nil) return;
    CGImageRef img = create(CGRectNull, kCGWindowListOptionIncludingWindow, (uint32_t)w.windowNumber,
                            kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution);
    if (img == NULL) return;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
    CGImageRelease(img);
}

+ (void)captureAndQuit {
    NSWindow *w = [self mainWindow];
    MLCWindowListCreateImage create = (MLCWindowListCreateImage)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    NSString *out = getenv("MLC_OUT") ? [NSString stringWithUTF8String:getenv("MLC_OUT")] : @"/tmp/apps-concept/out/shot.png";
    if (getenv("MLC_ICONPICKER")) {
        for (NSWindow *other in NSApp.windows) {
            fprintf(stderr, "ConceptHarness: window %s visible=%d\n", NSStringFromClass([other class]).UTF8String, other.isVisible);
        }
    }
    MLCWindowListCreateImageFromArray createFromArray = (MLCWindowListCreateImageFromArray)dlsym(RTLD_DEFAULT, "CGWindowListCreateImageFromArray");
    if (create != NULL && w != nil) {
        CGImageRef img = NULL;
        NSMutableArray<NSWindow *> *popovers = [NSMutableArray array];
        if (getenv("MLC_ICONPICKER") || getenv("MLC_CUSTOMIZE")) {
            for (NSWindow *other in NSApp.windows) {
                if (other != w && other.isVisible && [NSStringFromClass([other class]) containsString:@"Popover"]) [popovers addObject:other];
            }
        }
        if (getenv("MLC_SHEETCOMP") && w.attachedSheet != nil) [popovers addObject:w.attachedSheet];   // window with its sheet over it
        if (getenv("MLC_SHEETONLY") && w.attachedSheet != nil) {
            // the add-computer sheet's own window
            img = create(CGRectNull, kCGWindowListOptionIncludingWindow, (uint32_t)w.attachedSheet.windowNumber,
                         kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution);
        }
        if (getenv("MLC_POPOVERONLY") && popovers.count > 0) {
            // the popover's own window, nothing else (so it is seen whole whatever the window under it)
            img = create(CGRectNull, kCGWindowListOptionIncludingWindow, (uint32_t)popovers.firstObject.windowNumber,
                         kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution);
            [popovers removeAllObjects];
        }
        if (img == NULL) {
            img = create(CGRectNull, kCGWindowListOptionIncludingWindow, (uint32_t)w.windowNumber,
                         kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution);
        }
        if (img != NULL) {
            if (popovers.count > 0) {
                // The window with its popover over it, composited by the window server so the popover's
                // glass has the page behind it. Only the window's rectangle, only windows above it.
                CGFloat screenHeight = NSScreen.screens.firstObject.frame.size.height;
                CGRect cgRect = CGRectMake(w.frame.origin.x, screenHeight - NSMaxY(w.frame), w.frame.size.width, w.frame.size.height);
                CGImageRef composite = create(cgRect, kCGWindowListOptionOnScreenAboveWindow | kCGWindowListOptionIncludingWindow,
                                              (uint32_t)w.windowNumber, kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution);
                if (composite != NULL) { CGImageRelease(img); img = composite; }
            }
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
            [[NSFileManager defaultManager] createDirectoryAtPath:out.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:out atomically:YES];
            CGImageRelease(img);
            fprintf(stderr, "ConceptHarness: wrote %s\n", out.UTF8String);
        }
    }
    [NSApp terminate:nil];
}

@end
#else
// Release builds: the fixture does not exist. These calls are the only trace of it and do nothing.
#import "ConceptHarness.h"
@implementation ConceptHarness
+ (BOOL)enabled { return NO; }
+ (BOOL)networkMocked { return NO; }
+ (NSString *)variant { return @""; }
+ (void)applyMockRuntimeStateToHost:(TemporaryHost *)host {}
+ (void)applyMockExtrasToApp:(TemporaryApp *)app {}
+ (void)seedIfNeeded {}
+ (void)startScripted {}
@end
#endif
