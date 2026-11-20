#import "MLCapsLockCapture.h"

#include <assert.h>
#include <stdio.h>

@interface MLCapsLockCapture (TestInput)
- (void)addKeyboard:(id)keyboard;
- (void)removeKeyboard:(id)keyboard;
- (void)handleKeyboard:(id)keyboard down:(BOOL)down;
@end

int main(void) {
    @autoreleasepool {
        __block BOOL ownsInput = NO;
        NSMutableArray<NSNumber *> *edges = [NSMutableArray array];
        MLCapsLockCapture *capture = [[MLCapsLockCapture alloc]
            initWithOwnsInput:^BOOL {
              return ownsInput;
            }
            sendEdge:^(BOOL down) {
              [edges addObject:@(down)];
            }];

        NSObject *first = [NSObject new];
        NSObject *second = [NSObject new];
        assert(!capture.hasKeyboards);
        [capture addKeyboard:first];
        assert(capture.hasKeyboards);
        [capture handleKeyboard:first down:YES];
        [capture handleKeyboard:first down:NO];
        assert(edges.count == 0);
        puts("PASS: Direct Caps Lock requires keyboard ownership");

        ownsInput = YES;
        [capture handleKeyboard:first down:NO];
        [capture handleKeyboard:second down:YES];
        assert(edges.count == 0);
        [capture handleKeyboard:first down:YES];
        [capture handleKeyboard:first down:YES];
        [capture handleKeyboard:first down:NO];
        [capture handleKeyboard:first down:NO];
        [capture handleKeyboard:first down:YES];
        [capture handleKeyboard:first down:NO];
        assert(([edges isEqualToArray:@[ @YES, @NO, @YES, @NO ]]));
        puts("PASS: Direct Caps Lock sends each tap and ignores repeated or unmatched edges");

        [edges removeAllObjects];
        [capture addKeyboard:second];
        [capture handleKeyboard:first down:YES];
        [capture handleKeyboard:second down:YES];
        [capture removeKeyboard:first];
        assert(capture.hasKeyboards);
        [capture handleKeyboard:first down:NO];
        ownsInput = NO;
        [capture handleKeyboard:second down:NO];
        assert(([edges isEqualToArray:@[ @YES, @YES, @NO, @NO ]]));
        puts("PASS: Direct Caps Lock tracks keyboards independently and releases after unplug or "
             "ownership loss");

        [edges removeAllObjects];
        ownsInput = YES;
        [capture handleKeyboard:second down:YES];
        [capture stop];
        [capture stop];
        [capture handleKeyboard:second down:NO];
        assert(!capture.hasKeyboards);
        assert(([edges isEqualToArray:@[ @YES, @NO ]]));
        puts("PASS: Direct Caps Lock teardown balances held keys and is idempotent");
    }
}
