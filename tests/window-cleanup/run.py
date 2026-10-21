"""Exercise production close methods against a deterministic Foundation window model."""
from pathlib import Path
import subprocess,tempfile,sys
root=Path(__file__).resolve().parents[2]
s=(root/'Limelight/macOS/ViewControllers/StreamViewController.m').read_text()
w=(root/'Limelight/macOS/ViewControllers/StreamViewController+WindowModes.m').read_text()
close=s[s.index('@implementation ClientWindow'):s.index('static NSScreen *MLScreenContainingMouseLocation')]
life=s[s.index('- (void)tearDownPresentationWindowObservers {'):s.index('- (void)tearDownStreamLifecycleObserversAndTimers {')]
network=s[s.index('- (void)tearDownStreamLifecycleObserversAndTimers {'):]
network=network[:network.index('\n- (',5)]
for key in ['windowDidExitFullScreenNotification','windowDidEnterFullScreenNotification','windowWillCloseNotification']:
 assert key not in network, 'Network cleanup must not remove presentation observers'
start=s.index('        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {')
end=s.index('            if (weakSelf.pendingWindowMode',start)
continuation=s[start:end]+'        }\n'
a=w.index('- (void)windowDidFailToExitFullScreen:');b=w.index('- (void)windowWillEnterFullScreen:',a)
failure=w[a:b]
fixture=r'''
#import <Foundation/Foundation.h>
#include <assert.h>
#define LOG_W 1
#define Log(...) ((void)0)
@class NSWindowController;
@interface NSViewController : NSObject
@end
@implementation NSViewController
@end
@interface NSWindow : NSObject
@property(weak) NSWindowController *windowController;
@property NSViewController *contentViewController;
@property(weak) id delegate;
@property BOOL excludedFromWindowsMenu;
@property BOOL ignoresMouseEvents;
@property double alphaValue;
@property BOOL visible;
@property int closes;
- (void)close;
- (void)makeKeyAndOrderFront:(id)sender;
@end
@implementation NSWindow
- (void)close { self.closes++; self.visible=NO; [[NSNotificationCenter defaultCenter] postNotificationName:@"willClose" object:self]; }
- (void)makeKeyAndOrderFront:(id)sender { self.visible=YES; }
@end
@interface NSWindowController : NSObject
@property NSWindow *window;
@end
@implementation NSWindowController
@end
@interface FakeApp : NSObject
@property int removals;
- (void)removeWindowsItem:(NSWindow *)window;
@end
@implementation FakeApp
- (void)removeWindowsItem:(NSWindow *)window { self.removals++; }
@end
static FakeApp *NSApp;
@interface StreamViewController : NSViewController
@property NSWindowController *presentationWindowController;
@property BOOL pendingCloseWindowAfterFullscreenExit;
@property BOOL fullscreenTransitionInProgress;
@property BOOL stopped;
@property int stops;
@property int powerReleases;
@property int closeContinuations;
@property id windowDidExitFullScreenNotification;
@property id windowDidEnterFullScreenNotification;
@property id windowWillCloseNotification;
@property(weak) NSWindow *testWindow;
- (void)beginStopStreamIfNeededWithReason:(NSString *)reason;
- (void)allowDisplaySleep;
- (void)finishClosingStreamWindow:(NSWindow *)window;
- (BOOL)isOurWindowTheWindowInNotiifcation:(NSNotification *)note;
- (void)logCurrentWindowStateWithContext:(NSString *)context;
- (void)requestSafeCloseOfStreamWindow;
- (void)tearDownPresentationWindowObservers;
- (void)windowDidFailToExitFullScreen:(NSWindow *)window;
@end
@interface ClientWindow : NSWindow
@end
'''
impl=r'''
@implementation StreamViewController
- (void)beginStopStreamIfNeededWithReason:(NSString *)r { if (!self.stopped) { self.stopped=YES; self.stops++; } }
- (void)allowDisplaySleep { self.powerReleases++; }
- (BOOL)isOurWindowTheWindowInNotiifcation:(NSNotification *)n { return n.object==self.testWindow; }
- (void)logCurrentWindowStateWithContext:(NSString *)s {}
- (void)requestSafeCloseOfStreamWindow { self.closeContinuations++; [self.testWindow close]; }
'''+life+failure+'\n@end\n'
checks=r'''
static ClientWindow *create(StreamViewController **out) {
 ClientWindow *window=[ClientWindow new];StreamViewController *c=[StreamViewController new];NSWindowController *wc=[NSWindowController new];
 wc.window=window;window.windowController=wc;window.contentViewController=c;c.presentationWindowController=wc;c.testWindow=window;
 window.visible=YES;window.alphaValue=1;*out=c;return window;
}
int main(void) { @autoreleasepool {
 NSApp=[FakeApp new];
 __weak ClientWindow *deadWindow;__weak StreamViewController *deadController;
 @autoreleasepool {
  StreamViewController *c;ClientWindow *window=create(&c);deadWindow=window;deadController=c;
  [window close];assert(window.closes==1 && !window.visible && window.excludedFromWindowsMenu);
  assert(!window.contentViewController && !window.windowController.window && !c.presentationWindowController);
  assert(c.stops==1 && c.powerReleases==1);
 }
 assert(!deadWindow && !deadController);
 StreamViewController *c,*other;ClientWindow *window=create(&c),*live=create(&other);
 c.pendingCloseWindowAfterFullscreenExit=YES;c.fullscreenTransitionInProgress=YES;
 __weak StreamViewController *weakSelf=c;
 c.windowDidExitFullScreenNotification=[[NSNotificationCenter defaultCenter] addObserverForName:@"didExit" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
'''+continuation+r'''
 }];
 // Network stop occurs before AppKit reports exit from the native fullscreen Space.
 [c beginStopStreamIfNeededWithReason:@"disconnect"];
 [[NSNotificationCenter defaultCenter] postNotificationName:@"didExit" object:live];assert(c.closeContinuations==0);
 [[NSNotificationCenter defaultCenter] postNotificationName:@"didExit" object:window];
 assert(c.closeContinuations==1 && window.closes==1 && !window.visible);
 assert(c.windowDidExitFullScreenNotification==nil && c.stops==1);
 assert(live.visible && live.closes==0 && other.stops==0);
 [[NSNotificationCenter defaultCenter] postNotificationName:@"didExit" object:window];assert(window.closes==1);
 // Failure to leave fullscreen restores a usable window instead of an invisible ghost.
 other.pendingCloseWindowAfterFullscreenExit=YES;other.fullscreenTransitionInProgress=YES;
 live.alphaValue=0;live.ignoresMouseEvents=YES;live.visible=NO;
 [other windowDidFailToExitFullScreen:live];
 assert(live.visible && live.alphaValue==1 && !live.ignoresMouseEvents && !other.pendingCloseWindowAfterFullscreenExit);
 [live close];
 puts("PASS: production close breaks window/VC/controller cycle and removes window entries");
 puts("PASS: production fullscreen continuation survives stream stop; unrelated/repeated events are harmless");
 puts("PASS: failed fullscreen exit restores a visible, interactive window; another stream is unaffected");
} }
'''
with tempfile.TemporaryDirectory(prefix='moonlight-window-test-') as tmp:
 p=Path(tmp);f=p/'test.m';f.write_text(fixture+close+impl+checks)
 subprocess.run(['clang','-fobjc-arc','-fblocks','-framework','Foundation',str(f),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)

# Shared adapters must also survive delayed teardown of a previous presentation.
for script in ('shared_input.py', 'awdl_ownership.py'):
 subprocess.run([sys.executable, str(root/'tests/window-cleanup'/script)], check=True)
