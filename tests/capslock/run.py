from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2]
s=(root/'Limelight/macOS/ViewControllers/SettingsShortcuts.swift').read_text()
start=s.index('@objcMembers\nfinal class CapsLockKeyEvent:')
end=s.index('\n@objcMembers\nfinal class StreamShortcut:',start)
helper=s[start:end]
program='''import AppKit
import Carbon.HIToolbox
'''+helper+'''
func event(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ type: NSEvent.EventType = .flagsChanged) -> NSEvent {
 NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 1,
 windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
 isARepeat: false, keyCode: code)!
}
for flags: NSEvent.ModifierFlags in [[], [.capsLock], [.capsLock,.control], [.shift]] {
 let e=event(UInt16(kVK_CapsLock), flags)
 let press=CapsLockKeyEvent.keyPress(from:e)!
 precondition(press.type == .keyDown && press.keyCode == UInt16(kVK_CapsLock))
 precondition(press.modifierFlags == flags && !press.isARepeat)
}
precondition(CapsLockKeyEvent.keyPress(from:event(UInt16(kVK_Shift), [.shift])) == nil)
precondition(CapsLockKeyEvent.keyPress(from:event(UInt16(kVK_Tab), [], .keyDown)) == nil)
print("PASS: actual Caps Lock event normalization, on/off, chords and unrelated keys")
'''
def extract_method(source, signature):
 a=source.index(signature);i=source.index('{',a)+1;depth=1
 while depth:
  if source[i]=='{':depth+=1
  elif source[i]=='}':depth-=1
  i+=1
 return source[a:i]

vc=(root/'Limelight/macOS/ViewControllers/StreamViewController+MouseCapture.m').read_text()
a=vc.index('- (void)flagsChanged:(NSEvent *)event {');b=vc.index('    NSEventModifierFlags relevantModifiers = ',a)
method=vc[a:b]+ '    self.otherModifiers++;\n}\n'
input_vc=(root/'Limelight/macOS/ViewControllers/StreamViewController+Input.m').read_text()
uses_direct_caps_lock=extract_method(input_vc, '- (BOOL)usesDirectCapsLock {')
hid=(root/'Limelight/Input/HIDSupport.m').read_text()
modifier_helpers='\n'.join(extract_method(hid, signature) for signature in (
 'static HIDKeyboardPhysicalModifierMask HIDEffectivePhysicalModifierMaskForEvent(',
 'static char HIDRemoteModifierFlagsToGenericFlags(',
))
hid_methods='\n'.join(extract_method(hid, signature) for signature in (
 '- (void)syncKeyboardModifierStateForEvent:',
 '- (void)sendDirectCapsLockDown:',
))
controller_methods='\n'.join((
 extract_method(vc, '- (void)resolveDeferredCommandModifierWithoutRemoteTapWithReason:'),
 extract_method(input_vc, '- (void)forwardDirectCapsLockPressWithModifierFlags:'),
))
native='''#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#include <assert.h>
#include "KeyboardRouting.h"

enum { KEY_ACTION_DOWN = 0x03, KEY_ACTION_UP = 0x04 };
enum { MODIFIER_SHIFT = 0x01, MODIFIER_CTRL = 0x02, MODIFIER_ALT = 0x04, MODIFIER_META = 0x08 };
typedef id PML_INPUT_STREAM_CONTEXT;
static NSMutableArray<NSArray<NSNumber *> *> *packets;
#define HIDInputContext(support) (support)
#define HIDValidateInputContext(ctx, operation) ((ctx) != nil)
#define HIDDispatchInput(support, ctx, block) (block)()
#define Log(...) ((void)0)

static void LiSendKeyboardEventCtx(PML_INPUT_STREAM_CONTEXT input, short key, char action, char modifiers) {
    [packets addObject:@[@(key & 0xff), @(action), @(modifiers)]];
}

'''+modifier_helpers+'''
@interface CapsLockKeyEvent : NSObject
+ (NSEvent *)keyPressFrom:(NSEvent *)e;
@end
@implementation CapsLockKeyEvent
+ (NSEvent *)keyPressFrom:(NSEvent *)e { return e; }
@end
@interface FakeHID : NSObject
@property BOOL shouldSendInputEvents;
@property NSUInteger keyboardRemoteModifierMask;
@property NSDictionary *mappings;
- (void)sendDirectCapsLockDown:(BOOL)down modifierEvent:(NSEvent *)event;
- (void)syncKeyboardModifierStateForEvent:(NSEvent *)event;
@end
@implementation FakeHID
- (NSUInteger)desiredRemoteKeyboardModifierMaskForEvent:(NSEvent *)event {
    HIDKeyboardPhysicalModifierMask held = HIDEffectivePhysicalModifierMaskForEvent(0, event);
    return MLDesiredRemoteModifierMask(held, (MLModifierPolicy){0});
}
'''+hid_methods+'''
@end
@interface FakeCapsLockCapture : NSObject
@property BOOL hasKeyboards;
@end
@implementation FakeCapsLockCapture
@end
@interface InputMonitoringPermissionManager : NSObject
@property BOOL hasCurrentSystemGrant;
+ (instancetype)sharedManager;
@end
@implementation InputMonitoringPermissionManager
+ (instancetype)sharedManager {
 static InputMonitoringPermissionManager *manager;
 if (!manager) manager=[InputMonitoringPermissionManager new];
 return manager;
}
@end
@interface TestStream : NSObject
@property BOOL capsLockStateKnown;
@property BOOL capsLockLastState;
@property BOOL deferredCommandModifierPendingForShortcutTranslation;
@property BOOL deferredCommandModifierForwardedAsHeld;
@property NSUInteger deferredCommandModifierDispatchToken;
@property FakeCapsLockCapture *directCapsLockCapture;
- (BOOL)usesDirectCapsLock;
@property FakeHID *hidSupport;
@property int forwarded;
@property int otherModifiers;
@property BOOL imeEnabled;
@property int inputMethodEvents;
- (void)flagsChanged:(NSEvent *)e;
- (BOOL)onKeyboardEquivalent:(NSEvent *)e;
- (void)forwardDirectCapsLockPressWithModifierFlags:(NSEventModifierFlags)flags;
@end
@implementation TestStream
- (BOOL)onKeyboardEquivalent:(NSEvent *)e { self.forwarded++; return YES; }
- (void)routeFlagsChangedToInputMethod:(NSEvent *)e {
 if (self.imeEnabled && self.hidSupport.shouldSendInputEvents) self.inputMethodEvents++;
}
- (BOOL)ownsKeyboardForDirectCapsLock { return self.hidSupport.shouldSendInputEvents; }
- (void)stopDirectCapsLockCapture { self.directCapsLockCapture = nil; }
'''+uses_direct_caps_lock+'\n'+controller_methods+'\n'+method+'''
@end
static NSEvent *flags(unsigned short key, NSEventModifierFlags flags) {
 return [NSEvent keyEventWithType:NSEventTypeFlagsChanged location:NSZeroPoint modifierFlags:flags timestamp:1 windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:key];
}
int main(void) { @autoreleasepool {
 TestStream *c=[TestStream new]; c.hidSupport=[FakeHID new]; c.hidSupport.shouldSendInputEvents=YES;c.imeEnabled=YES;
 [c flagsChanged:flags(kVK_CapsLock,NSEventModifierFlagCapsLock)]; assert(c.forwarded==1 && c.inputMethodEvents==1);
 [c flagsChanged:flags(kVK_CapsLock,NSEventModifierFlagCapsLock)]; assert(c.forwarded==1);
 [c flagsChanged:flags(kVK_CapsLock,0)]; assert(c.forwarded==2);
 [c flagsChanged:flags(kVK_CapsLock,0)]; assert(c.forwarded==2);
 [c flagsChanged:flags(kVK_Shift,NSEventModifierFlagShift)]; assert(c.otherModifiers==1 && c.forwarded==2);
 c.hidSupport.shouldSendInputEvents=NO;
 [c flagsChanged:flags(kVK_CapsLock,NSEventModifierFlagCapsLock)]; assert(c.forwarded==2);
 assert(c.inputMethodEvents==5); // All captured flags reach the input method, including duplicate Caps edges.
 // Recapture rebases to the current local Caps state, so the next off transition is delivered.
 c.capsLockStateKnown=YES; c.capsLockLastState=YES; c.hidSupport.shouldSendInputEvents=YES;
 [c flagsChanged:flags(kVK_CapsLock,0)]; assert(c.forwarded==3 && c.inputMethodEvents==6);
 // First event may be an OFF transition.
 TestStream *d=[TestStream new];d.hidSupport=[FakeHID new];d.hidSupport.shouldSendInputEvents=YES;
 [d flagsChanged:flags(kVK_CapsLock,0)]; assert(d.forwarded==1);
 puts("PASS: actual Caps Lock routing, duplicate edges, capture gate, recapture, input-method delivery and modifier regression");
 InputMonitoringPermissionManager *permission=[InputMonitoringPermissionManager sharedManager];
 permission.hasCurrentSystemGrant=YES;
 assert(![c usesDirectCapsLock]);
 c.directCapsLockCapture=[FakeCapsLockCapture new];
 assert(![c usesDirectCapsLock]);
 c.directCapsLockCapture.hasKeyboards=YES;
 assert([c usesDirectCapsLock]);
 [c flagsChanged:flags(kVK_CapsLock,NSEventModifierFlagCapsLock)];
 assert(c.forwarded==3 && c.inputMethodEvents==7 && c.capsLockLastState);
 permission.hasCurrentSystemGrant=NO;
 [c flagsChanged:flags(kVK_CapsLock,NSEventModifierFlagCapsLock)];
 assert(c.forwarded==3);
 [c flagsChanged:flags(kVK_CapsLock,0)];
 assert(c.forwarded==4 && c.directCapsLockCapture==nil);
 puts("PASS: direct capture suppresses legacy forwarding and permission loss restores fallback");

 TestStream *chord = [TestStream new];
 chord.hidSupport = [FakeHID new];
 chord.hidSupport.shouldSendInputEvents = YES;
 chord.hidSupport.mappings = @{@(kVK_CapsLock): @0x14};
 chord.deferredCommandModifierPendingForShortcutTranslation = YES;
 packets = [NSMutableArray array];

 [chord forwardDirectCapsLockPressWithModifierFlags:NSEventModifierFlagCommand];
 assert(!chord.deferredCommandModifierPendingForShortcutTranslation);
 [chord.hidSupport sendDirectCapsLockDown:NO modifierEvent:nil];
 [chord.hidSupport syncKeyboardModifierStateForEvent:flags(kVK_Command, 0)];

 NSArray *expected = @[
    @[@0x5B, @(KEY_ACTION_DOWN), @(MODIFIER_META)],
    @[@0x14, @(KEY_ACTION_DOWN), @(MODIFIER_META)],
    @[@0x14, @(KEY_ACTION_UP), @(MODIFIER_META)],
    @[@0x5B, @(KEY_ACTION_UP), @0],
 ];
 assert([packets isEqualToArray:expected]);
 puts("PASS: Command held with direct Caps Lock sends Win down, Caps Lock down/up, then Win up");
} }
'''

editor=(root/'Limelight/macOS/ViewControllers/SettingsShortcutEditors.swift').read_text()
install=editor[editor.index('  private func installMonitor()',editor.index('private struct KeyboardTranslationRuleEditorSheet:')):]
callback=install[install.index('{ event in')+len('{ event in'):install.index('\n    }')]
handle=extract_method(install,'  private func handle(_ event: NSEvent) -> NSEvent?')
program+='''
struct StreamShortcut { let keyCode: Int; let modifierFlags: NSEvent.ModifierFlags }
enum StreamShortcutProfile {
 static func relevantModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
  flags.intersection([.control,.option,.shift,.command,.function])
 }
}
class Recorder {
 enum CaptureTarget { case trigger,output }
 var captureTarget: CaptureTarget? = nil
 var triggerShortcut: StreamShortcut? = nil
 var remoteOutputShortcut: StreamShortcut? = nil
 func monitor(_ event:NSEvent)->NSEvent? {
'''+callback+'\n }\n'+handle+'''
}
let recorder=Recorder()
let caps=event(UInt16(kVK_CapsLock),[.capsLock,.control])
let shift=event(UInt16(kVK_Shift),[.shift])
let tab=event(UInt16(kVK_Tab),[],.keyDown)
// No replacement events may escape an idle recorder, including a Caps release.
for e in [caps,shift,tab,event(UInt16(kVK_CapsLock),[])] {
 precondition(recorder.monitor(e) === e)
}
recorder.captureTarget = .trigger
precondition(recorder.monitor(shift) === shift && recorder.captureTarget != nil)
precondition(recorder.monitor(caps) == nil)
precondition(recorder.triggerShortcut?.keyCode == kVK_CapsLock)
precondition(recorder.triggerShortcut?.modifierFlags == [.control])
let release=event(UInt16(kVK_CapsLock),[])
precondition(recorder.monitor(release) === release)
recorder.captureTarget = .output
precondition(recorder.monitor(release) == nil && recorder.remoteOutputShortcut?.keyCode == kVK_CapsLock)
recorder.captureTarget = .trigger
precondition(recorder.monitor(event(UInt16(kVK_Escape),[],.keyDown)) == nil && recorder.captureTarget == nil)
recorder.captureTarget = .trigger
precondition(recorder.monitor(tab) == nil && recorder.triggerShortcut?.keyCode == kVK_Tab)
print("PASS: idle recorder preserves event identity; Caps trigger/output, release, ordinary keys and cancellation work")
'''

with tempfile.TemporaryDirectory(prefix='capslock-tests-') as tmp:
 p=Path(tmp);(p/'test.swift').write_text(program);(p/'test.m').write_text(native)
 subprocess.run(['swift','-module-cache-path',str(p/'swift-cache'),str(p/'test.swift')],check=True)
 inputs=root/'Limelight/Input'
 subprocess.run(['clang','-fobjc-arc','-framework','AppKit','-framework','Carbon',
                 '-I',str(inputs),str(p/'test.m'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
 subprocess.run(['clang','-fobjc-arc','-framework','Foundation','-framework','IOKit',
                 '-I',str(inputs),str(inputs/'MLCapsLockCapture.m'),
                 str(root/'tests/capslock/direct.m'),'-o',str(p/'direct')],check=True)
 subprocess.run([str(p/'direct')],check=True)
# The recorder must accept flagsChanged only for Caps, and Caps must have a supported display key.
editor=(root/'Limelight/macOS/ViewControllers/SettingsShortcutEditors.swift').read_text()
assert 'guard let press = CapsLockKeyEvent.keyPress(from: event) else { return event }' in editor
assert 'kVK_CapsLock: "Caps Lock"' in s
print('PASS: translation recorder normalization and Caps Lock label wired')
