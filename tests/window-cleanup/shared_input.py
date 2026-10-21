"""Execute the production GCMouse handlers against shared fake devices."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'Limelight/Input/HIDSupport+Pointer.m').read_text()


def method(signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        if source[end] == '{':
            depth += 1
        elif source[end] == '}':
            depth -= 1
        end += 1
    return source[start:end]


owner_helper = method('static NSMapTable<GCMouse *, HIDSupport *> *HIDGCMouseCallbackOwners')

fixture = r'''
#import <Foundation/Foundation.h>
#include <assert.h>
#define BUTTON_LEFT 1
#define BUTTON_MIDDLE 2
#define BUTTON_RIGHT 3
#define BUTTON_X1 4
#define BUTTON_X2 5
#define BUTTON_ACTION_PRESS 1
#define BUTTON_ACTION_RELEASE 0
typedef void *PML_INPUT_STREAM_CONTEXT;
@interface GCControllerButtonInput : NSObject
@property(copy) void (^pressedChangedHandler)(GCControllerButtonInput *, float, BOOL);
@end
@implementation GCControllerButtonInput
@end
@interface GCControllerAxisInput : NSObject
@property(copy) void (^valueChangedHandler)(GCControllerAxisInput *, float);
@end
@implementation GCControllerAxisInput
@end
@interface Scroll : NSObject
@property(copy) void (^valueChangedHandler)(void);
@property GCControllerAxisInput *yAxis;
@end
@implementation Scroll
@end
@interface GCMouseInput : NSObject
@property(copy) void (^mouseMovedHandler)(GCMouseInput *, float, float);
@property GCControllerButtonInput *leftButton, *middleButton, *rightButton;
@property NSArray<GCControllerButtonInput *> *auxiliaryButtons;
@property Scroll *scroll;
@end
@implementation GCMouseInput
@end
@interface GCMouse : NSObject
@property GCMouseInput *mouseInput;
@end
@implementation GCMouse
@end
@interface Touchpad : NSObject
- (BOOL)consumeMouseButton:(int)button pressed:(BOOL)pressed;
@end
@implementation Touchpad
- (BOOL)consumeMouseButton:(int)button pressed:(BOOL)pressed { return NO; }
@end
@interface HIDSupport : NSObject
@property BOOL useGCMouse, shouldSendInputEvents;
@property float mouseDeltaX, mouseDeltaY;
@property int scrollEvents;
@property Touchpad *precisionTouchpad;
- (void)handleGCMouseScrollValueY:(float)value;
- (void)registerMouseCallbacks:(GCMouse *)mouse;
- (void)unregisterMouseCallbacks:(GCMouse *)mouse;
@end
static int buttonEvents;
static PML_INPUT_STREAM_CONTEXT HIDInputContext(HIDSupport *support) { return (void *)1; }
static void LiSendMouseButtonEventCtx(PML_INPUT_STREAM_CONTEXT ctx, int action, int button) { buttonEvents++; }
'''
implementation = owner_helper + '\n@implementation HIDSupport\n' + r'''
- (void)handleGCMouseScrollValueY:(float)value { self.scrollEvents++; }
''' + method('-(void)registerMouseCallbacks:') + '\n' + method('-(void)unregisterMouseCallbacks:') + '\n@end\n'
checks = r'''
static GCMouse *device(void) {
 GCMouse *mouse=[GCMouse new]; mouse.mouseInput=[GCMouseInput new];
 mouse.mouseInput.leftButton=[GCControllerButtonInput new];
 mouse.mouseInput.middleButton=[GCControllerButtonInput new];
 mouse.mouseInput.rightButton=[GCControllerButtonInput new];
 mouse.mouseInput.auxiliaryButtons=@[[GCControllerButtonInput new],[GCControllerButtonInput new]];
 mouse.mouseInput.scroll=[Scroll new]; mouse.mouseInput.scroll.yAxis=[GCControllerAxisInput new];
 return mouse;
}
static HIDSupport *support(void) {
 HIDSupport *s=[HIDSupport new]; s.useGCMouse=YES; s.shouldSendInputEvents=YES; return s;
}
static void assertHandlers(GCMouse *mouse, BOOL present) {
 assert((mouse.mouseInput.mouseMovedHandler != nil)==present);
 assert((mouse.mouseInput.leftButton.pressedChangedHandler != nil)==present);
 assert((mouse.mouseInput.middleButton.pressedChangedHandler != nil)==present);
 assert((mouse.mouseInput.rightButton.pressedChangedHandler != nil)==present);
 for (GCControllerButtonInput *button in mouse.mouseInput.auxiliaryButtons) {
  assert((button.pressedChangedHandler != nil)==present);
 }
 assert((mouse.mouseInput.scroll.yAxis.valueChangedHandler != nil)==present);
}
int main(void) { @autoreleasepool {
 GCMouse *shared=device(), *oldOnly=device();
 HIDSupport *old=support(), *current=support();
 [old registerMouseCallbacks:shared]; [old registerMouseCallbacks:oldOnly];
 [current registerMouseCallbacks:shared];
 // Late teardown of the previous stream must preserve the replacement's callbacks.
 [old unregisterMouseCallbacks:shared]; assertHandlers(shared, YES);
 shared.mouseInput.mouseMovedHandler(shared.mouseInput, 3, 4);
 shared.mouseInput.leftButton.pressedChangedHandler(shared.mouseInput.leftButton, 1, YES);
 shared.mouseInput.scroll.yAxis.valueChangedHandler(shared.mouseInput.scroll.yAxis, 1);
 assert(current.mouseDeltaX==3 && current.mouseDeltaY==-4 && current.scrollEvents==1 && buttonEvents==1);
 assert(old.mouseDeltaX==0 && old.scrollEvents==0);
 [old unregisterMouseCallbacks:oldOnly]; assertHandlers(oldOnly, NO);
 [current unregisterMouseCallbacks:shared]; assertHandlers(shared, NO);
 [current unregisterMouseCallbacks:shared]; assertHandlers(shared, NO);
 // Changing driver and registering again must still work for the current owner.
 [current registerMouseCallbacks:shared]; current.useGCMouse=NO;
 [current registerMouseCallbacks:shared]; assertHandlers(shared, NO);
 [old unregisterMouseCallbacks:shared];
 current.useGCMouse=YES; [current registerMouseCallbacks:shared];
 [old unregisterMouseCallbacks:shared]; assertHandlers(shared, YES);
 [current unregisterMouseCallbacks:shared];
 __weak HIDSupport *released;
 @autoreleasepool {
  HIDSupport *temporary=support(); released=temporary;
  [temporary registerMouseCallbacks:shared]; [temporary unregisterMouseCallbacks:shared];
 }
 assert(released==nil);
 puts("PASS: stale mouse cleanup preserves another stream's movement, buttons and scroll");
 puts("PASS: owned cleanup, repeated cleanup, driver refresh and owner lifetime");
} }
'''
with tempfile.TemporaryDirectory(prefix='moonlight-shared-input-') as tmp:
    path = Path(tmp)
    (path / 'test.m').write_text(fixture + implementation + checks)
    subprocess.run(['clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation',
                    str(path / 'test.m'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
