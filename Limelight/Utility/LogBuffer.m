//
//  LogBuffer.m
//  Moonlight
//

#import "LogBuffer.h"

NSNotificationName const MoonlightLogDidAppendNotification = @"MoonlightLogDidAppendNotification";
NSString * const MoonlightLogNotificationLineKey = @"line";
NSString * const MoonlightLogNotificationLevelKey = @"level";

@interface LogBuffer ()

@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSMutableArray<NSString *> *lines;
@property(nonatomic) NSUInteger maxLines;

@end

@implementation LogBuffer

+ (instancetype)shared {
    static LogBuffer *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[LogBuffer alloc] initPrivate];
    });
    return sharedInstance;
}

- (instancetype)init {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:@"Use +[LogBuffer shared]"
                                 userInfo:nil];
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.moonlight.logbuffer", DISPATCH_QUEUE_SERIAL);
        _lines = [[NSMutableArray alloc] init];
        _maxLines = 2000;
    }
    return self;
}

- (void)appendLine:(NSString *)line level:(LogLevel)level {
    if (!line) {
        return;
    }

    dispatch_async(self.queue, ^{
        [self.lines addObject:line];
        if (self.lines.count > self.maxLines) {
            NSUInteger overflow = self.lines.count - self.maxLines;
            [self.lines removeObjectsInRange:NSMakeRange(0, overflow)];
        }

        NSDictionary *userInfo = @{
            MoonlightLogNotificationLineKey: line,
            MoonlightLogNotificationLevelKey: @(level),
        };

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:MoonlightLogDidAppendNotification object:nil userInfo:userInfo];
        });
    });
}

- (NSArray<NSString *> *)allLines {
    __block NSArray<NSString *> *snapshot = nil;
    dispatch_sync(self.queue, ^{
        snapshot = [self.lines copy];
    });
    return snapshot ?: @[];
}

@end
