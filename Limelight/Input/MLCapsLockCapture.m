#import "MLCapsLockCapture.h"

#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDUsageTables.h>

static NSDictionary *CapsLockElementMatch(void) {
    // usb-if-hid-usage-tables-1-7-20261120, §10: Keyboard/Keypad usage 0x39.
    return @{
        @kIOHIDElementUsagePageKey : @(kHIDPage_KeyboardOrKeypad),
        @kIOHIDElementUsageKey : @(kHIDUsage_KeyboardCapsLock)
    };
}

@interface MLCapsLockCapture ()

- (void)addKeyboard:(id)keyboard;
- (void)removeKeyboard:(id)keyboard;
- (void)handleKeyboard:(id)keyboard down:(BOOL)down;

@end

static void KeyboardMatched(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    if (result != kIOReturnSuccess) {
        return;
    }
    // apple-iohid-device-20261120, IOHIDDeviceCopyMatchingElements.
    NSArray *elements = CFBridgingRelease(IOHIDDeviceCopyMatchingElements(
        device, (__bridge CFDictionaryRef)CapsLockElementMatch(), kIOHIDOptionsTypeNone));
    if (elements.count > 0) {
        [(__bridge MLCapsLockCapture *)context addKeyboard:(__bridge id)device];
    }
}

static void KeyboardRemoved(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    [(__bridge MLCapsLockCapture *)context removeKeyboard:(__bridge id)device];
}

static void CapsLockValueChanged(void *context, IOReturn result, void *sender,
                                 IOHIDValueRef value) {
    if (result != kIOReturnSuccess) {
        return;
    }
    // apple-iohid-element-20261120 and apple-iohid-value-20261120, GetDevice and GetIntegerValue.
    IOHIDElementRef element = IOHIDValueGetElement(value);
    if (IOHIDElementGetUsagePage(element) == kHIDPage_KeyboardOrKeypad &&
        IOHIDElementGetUsage(element) == kHIDUsage_KeyboardCapsLock) {
        [(__bridge MLCapsLockCapture *)context
            handleKeyboard:(__bridge id)IOHIDElementGetDevice(element)
                      down:IOHIDValueGetIntegerValue(value) != 0];
    }
}

@implementation MLCapsLockCapture {
    IOHIDManagerRef _manager;
    NSHashTable *_keyboards;
    NSHashTable *_heldKeyboards;
    BOOL (^_ownsInput)(void);
    void (^_sendEdge)(BOOL);
}

- (instancetype)initWithOwnsInput:(BOOL (^)(void))ownsInput sendEdge:(void (^)(BOOL))sendEdge {
    self = [super init];
    if (self) {
        _ownsInput = [ownsInput copy];
        _sendEdge = [sendEdge copy];
        // Device references remain owned by the manager until removal
        // (macos-apple-pointer-opaque-20261120).
        NSPointerFunctionsOptions identity =
            NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality;
        _keyboards = [NSHashTable hashTableWithOptions:identity];
        _heldKeyboards = [NSHashTable hashTableWithOptions:identity];
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)hasKeyboards {
    return _keyboards.count > 0;
}

- (BOOL)start {
    if (_manager != NULL) {
        return YES;
    }
    _manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDManagerOptionNone);
    if (_manager == NULL) {
        return NO;
    }

    // apple-iohid-manager-20261120, DeviceMatching, InputValueMatching and Open:
    // subscribe to one element on keyboards, and open them non-exclusively.
    NSDictionary *keyboards = @{
        @kIOHIDDeviceUsagePageKey : @(kHIDPage_GenericDesktop),
        @kIOHIDDeviceUsageKey : @(kHIDUsage_GD_Keyboard)
    };
    IOHIDManagerSetDeviceMatching(_manager, (__bridge CFDictionaryRef)keyboards);
    IOHIDManagerSetInputValueMatching(_manager, (__bridge CFDictionaryRef)CapsLockElementMatch());
    IOHIDManagerRegisterDeviceMatchingCallback(_manager, KeyboardMatched, (__bridge void *)self);
    IOHIDManagerRegisterDeviceRemovalCallback(_manager, KeyboardRemoved, (__bridge void *)self);
    IOHIDManagerRegisterInputValueCallback(_manager, CapsLockValueChanged, (__bridge void *)self);
    if (IOHIDManagerOpen(_manager, kIOHIDOptionsTypeNone) != kIOReturnSuccess) {
        CFRelease(_manager);
        _manager = NULL;
        return NO;
    }

    // Deliver on the AppKit run loop, including its common modes.
    // macos-apple-runloop-commonmodes-20261120, commonModes.
    IOHIDManagerScheduleWithRunLoop(_manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    return YES;
}

- (void)stop {
    if (_manager != NULL) {
        IOHIDManagerUnscheduleFromRunLoop(_manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        IOHIDManagerClose(_manager, kIOHIDOptionsTypeNone);
        CFRelease(_manager);
        _manager = NULL;
    }
    NSUInteger heldCount = _heldKeyboards.count;
    [_heldKeyboards removeAllObjects];
    [_keyboards removeAllObjects];
    for (NSUInteger i = 0; i < heldCount; i++) {
        _sendEdge(NO);
    }
}

- (void)addKeyboard:(id)keyboard {
    [_keyboards addObject:keyboard];
}

- (void)removeKeyboard:(id)keyboard {
    [self handleKeyboard:keyboard down:NO];
    [_keyboards removeObject:keyboard];
}

- (void)handleKeyboard:(id)keyboard down:(BOOL)down {
    if (![_keyboards containsObject:keyboard] || down == [_heldKeyboards containsObject:keyboard]) {
        return;
    }
    if (down) {
        if (!_ownsInput()) {
            return;
        }
        [_heldKeyboards addObject:keyboard];
    } else {
        [_heldKeyboards removeObject:keyboard];
    }
    _sendEdge(down);
}

@end
