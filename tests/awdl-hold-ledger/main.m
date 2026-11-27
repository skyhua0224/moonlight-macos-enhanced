#import <Foundation/Foundation.h>

#import "AwdlHoldLedger.h"

static int failures = 0;

#define CHECK(name, cond) do { \
    if (cond) { printf("ok   %s\n", name); } \
    else { failures++; printf("FAIL %s\n", name); } \
} while (0)

/// awdl0 as the ledger sees it, with a log of what was asked of it.
@interface FakeInterface : NSObject
@property BOOL present;
@property BOOL up;
@property (copy) NSString *failDown;
@property (copy) NSString *failUp;
@property (strong) NSMutableArray<NSString *> *commands;
- (MLAwdlHoldLedger *)makeLedger;
@end

@implementation FakeInterface
- (instancetype)init {
    self = [super init];
    _present = YES;
    _up = YES;
    _commands = [NSMutableArray array];
    return self;
}
- (MLAwdlHoldLedger *)makeLedger {
    __weak FakeInterface *weakSelf = self;
    return [[MLAwdlHoldLedger alloc]
        initWithQuery:^MLAwdlInterfaceSnapshot{
            MLAwdlInterfaceSnapshot snapshot = { .present = weakSelf.present, .up = weakSelf.up };
            return snapshot;
        }
        setUp:^NSString *(BOOL up) {
            FakeInterface *strongSelf = weakSelf;
            [strongSelf.commands addObject:up ? @"up" : @"down"];
            NSString *failure = up ? strongSelf.failUp : strongSelf.failDown;
            if (failure.length > 0) {
                return failure;
            }
            strongSelf.up = up;
            return @"";
        }];
}
@end

static NSString *joined(FakeInterface *i) {
    return [i.commands componentsJoinedByString:@","];
}

int main(void) {
    @autoreleasepool {
        {
            FakeInterface *i = [FakeInterface new];
            MLAwdlHoldLedger *l = [i makeLedger];
            CHECK("hold from up: down, restore pending", [[l holdForClient:@"a"] isEqualToString:@""] && !i.up && l.restorePending && l.holderCount == 1);
            CHECK("release: up again", [[l releaseForClient:@"a"] isEqualToString:@""] && i.up && !l.restorePending && l.holderCount == 0);
            CHECK("one down, one up", [joined(i) isEqualToString:@"down,up"]);
            CHECK("repeated release does nothing", [[l releaseForClient:@"a"] isEqualToString:@""] && [joined(i) isEqualToString:@"down,up"]);
        }
        {
            FakeInterface *i = [FakeInterface new];
            MLAwdlHoldLedger *l = [i makeLedger];
            [l holdForClient:@"a"];
            [l holdForClient:@"b"];
            CHECK("second holder: no second command", [joined(i) isEqualToString:@"down"] && l.holderCount == 2);
            [l releaseForClient:@"a"];
            CHECK("first release: still down", !i.up && l.holderCount == 1);
            [l releaseForClient:@"b"];
            CHECK("last release: up", i.up && [joined(i) isEqualToString:@"down,up"]);
        }
        {
            FakeInterface *i = [FakeInterface new];
            MLAwdlHoldLedger *l = [i makeLedger];
            [l holdForClient:@"a"];
            [l clientDisconnected:@"a"];
            CHECK("client gone (quit, crash, force quit): awdl0 comes back", i.up && !l.restorePending && l.holderCount == 0);
            [l clientDisconnected:@"never-held"];
            CHECK("a connection that held nothing restores nothing", [joined(i) isEqualToString:@"down,up"]);
        }
        {
            FakeInterface *i = [FakeInterface new];
            MLAwdlHoldLedger *l = [i makeLedger];
            [l holdForClient:@"a"];
            [l holdForClient:@"b"];
            [l clientDisconnected:@"a"];
            CHECK("one of two clients gone: still down", !i.up);
            [l clientDisconnected:@"b"];
            CHECK("both gone: up", i.up);
        }
        {
            FakeInterface *i = [FakeInterface new];
            i.up = NO;
            MLAwdlHoldLedger *l = [i makeLedger];
            CHECK("hold on an interface that was down: nothing to do", [[l holdForClient:@"a"] isEqualToString:@""] && !l.restorePending && i.commands.count == 0);
            [l releaseForClient:@"a"];
            CHECK("and nothing to give back", !i.up && i.commands.count == 0);
        }
        {
            FakeInterface *i = [FakeInterface new];
            i.failDown = @"ifconfig: down failed";
            MLAwdlHoldLedger *l = [i makeLedger];
            CHECK("down fails: the reason is returned", [[l holdForClient:@"a"] isEqualToString:@"ifconfig: down failed"]);
            CHECK("and nothing is held", l.holderCount == 0 && !l.restorePending && i.up);
        }
        {
            FakeInterface *i = [FakeInterface new];
            i.present = NO;
            MLAwdlHoldLedger *l = [i makeLedger];
            CHECK("no awdl0: refused", [[l holdForClient:@"a"] length] > 0 && l.holderCount == 0 && i.commands.count == 0);
        }
        {
            FakeInterface *i = [FakeInterface new];
            MLAwdlHoldLedger *l = [i makeLedger];
            [l holdForClient:@"a"];
            i.failUp = @"busy";
            CHECK("up fails: the reason is returned", [[l releaseForClient:@"a"] isEqualToString:@"busy"]);
            CHECK("and the restore stays pending", l.restorePending && l.holderCount == 0 && !i.up);
            i.failUp = nil;
            CHECK("any later release retries it", [[l releaseForClient:@"other"] isEqualToString:@""] && i.up && !l.restorePending);
        }
        {
            FakeInterface *i = [FakeInterface new];
            MLAwdlHoldLedger *l = [i makeLedger];
            [l holdForClient:@"a"];
            i.failUp = @"busy";
            [l clientDisconnected:@"a"];
            i.failUp = nil;
            [l holdForClient:@"b"];
            CHECK("a hold after a failed restore keeps the original state", !i.up && l.restorePending);
            [l releaseForClient:@"b"];
            CHECK("and gives it back", i.up && !l.restorePending);
        }
        {
            FakeInterface *i = [FakeInterface new];
            MLAwdlHoldLedger *l = [i makeLedger];
            [l holdForClient:@"a"];
            i.up = YES; // the system brought it up under the running stream (wake)
            CHECK("hold again after the system brought awdl0 up: down again", [[l holdForClient:@"a"] isEqualToString:@""] && !i.up && l.holderCount == 1);
            [l releaseForClient:@"a"];
            CHECK("and one release gives it back", i.up && [joined(i) isEqualToString:@"down,down,up"]);
        }
        {
            FakeInterface *i = [FakeInterface new];
            i.up = NO;
            MLAwdlHoldLedger *l = [i makeLedger];
            [l holdForClient:@"a"];
            i.up = YES; // the system raised an interface the user had turned off
            [l holdForClient:@"a"];
            CHECK("an interface that was down before is not turned off again", i.up && i.commands.count == 0);
        }
    }

    if (failures > 0) {
        printf("%d failed\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
