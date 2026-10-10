//
//  LogBuffer.m
//  Moonlight
//

#import "LogBuffer.h"

// The ring keeps about kLogBufferCapacity entries. It is trimmed in chunks so that the
// common append is O(1) instead of shifting the whole array for every line.
static const NSUInteger kLogBufferCapacity = 5000;
static const NSUInteger kLogBufferTrimSlack = 500;
// The change signal is delivered at most once per interval (about five times a second).
static const CFTimeInterval kLogChangeSignalMinInterval = 0.2;

@implementation MLLogEntry

- (instancetype)initWithSequence:(NSUInteger)sequence
                       timestamp:(NSTimeInterval)timestamp
                   timestampText:(NSString *)timestampText
                           level:(LogLevel)level
                             tag:(nullable NSString *)tag
                         message:(NSString *)message
                            line:(NSString *)line
                        fileLine:(NSString *)fileLine
                   noiseCategory:(NSInteger)noiseCategory
                           inRaw:(BOOL)inRaw
                       inCurated:(BOOL)inCurated
                       isSummary:(BOOL)isSummary {
    self = [super init];
    if (self) {
        _sequence = sequence;
        _timestamp = timestamp;
        _timestampText = [timestampText copy];
        _level = level;
        _tag = [tag copy];
        _message = [message copy];
        _line = [line copy];
        _fileLine = [fileLine copy];
        _noiseCategory = noiseCategory;
        _inRaw = inRaw;
        _inCurated = inCurated;
        _isSummary = isSummary;
    }
    return self;
}

@end

@interface LogBuffer () {
    // Guards everything below. Writers (the logging queue) and readers hold it only for
    // short array operations, never while calling out.
    NSLock *_lock;
    NSMutableArray<MLLogEntry *> *_entries;
    NSMutableDictionary<NSNumber *, void (^)(void)> *_subscribers;
    unsigned long long _nextToken;
    BOOL _signalScheduled;
    CFTimeInterval _lastSignalTime;
}
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
        _lock = [[NSLock alloc] init];
        _entries = [[NSMutableArray alloc] init];
        _subscribers = [[NSMutableDictionary alloc] init];
        _nextToken = 0;
        _signalScheduled = NO;
        _lastSignalTime = 0;
    }
    return self;
}

// MARK: Reading

- (NSUInteger)latestSequence {
    [_lock lock];
    NSUInteger latest = _entries.lastObject.sequence;
    [_lock unlock];
    return latest;
}

- (NSArray<MLLogEntry *> *)entriesAfterSequence:(NSUInteger)sequence limit:(NSUInteger)limit {
    [_lock lock];
    NSUInteger count = _entries.count;
    NSArray<MLLogEntry *> *result = @[];
    if (count > 0) {
        // Sequences are contiguous, so the position follows from the first one. The two loops
        // only correct the index if that assumption were ever violated.
        NSUInteger firstSequence = _entries[0].sequence;
        NSUInteger startIndex = (sequence >= firstSequence) ? (sequence - firstSequence + 1) : 0;
        if (startIndex > count) {
            startIndex = count;
        }
        while (startIndex > 0 && _entries[startIndex - 1].sequence > sequence) {
            startIndex--;
        }
        while (startIndex < count && _entries[startIndex].sequence <= sequence) {
            startIndex++;
        }
        if (startIndex < count) {
            NSUInteger length = count - startIndex;
            if (limit > 0 && length > limit) {
                startIndex = count - limit;
                length = limit;
            }
            result = [_entries subarrayWithRange:NSMakeRange(startIndex, length)];
        }
    }
    [_lock unlock];
    return result;
}

- (NSArray<MLLogEntry *> *)lastEntries:(NSUInteger)count {
    [_lock lock];
    NSUInteger total = _entries.count;
    NSUInteger length = MIN(count, total);
    NSArray<MLLogEntry *> *result = length > 0
        ? [_entries subarrayWithRange:NSMakeRange(total - length, length)]
        : @[];
    [_lock unlock];
    return result;
}

- (NSArray<NSString *> *)allLines {
    NSArray<MLLogEntry *> *entries = [self lastEntries:NSUIntegerMax];
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:entries.count];
    for (MLLogEntry *entry in entries) {
        [lines addObject:entry.line];
    }
    return lines;
}

// MARK: Change signal

- (id<NSObject>)subscribeToChangesWithHandler:(void (^)(void))handler {
    [_lock lock];
    _nextToken += 1;
    NSNumber *token = @(_nextToken);
    _subscribers[token] = [handler copy];
    [_lock unlock];
    return token;
}

- (void)unsubscribe:(id<NSObject>)token {
    if (![token isKindOfClass:[NSNumber class]]) {
        return;
    }
    [_lock lock];
    [_subscribers removeObjectForKey:(NSNumber *)token];
    [_lock unlock];
}

// MARK: Producer

- (void)appendEntries:(NSArray<MLLogEntry *> *)entries {
    if (entries.count == 0) {
        return;
    }

    [_lock lock];
    [_entries addObjectsFromArray:entries];
    if (_entries.count > kLogBufferCapacity + kLogBufferTrimSlack) {
        [_entries removeObjectsInRange:NSMakeRange(0, _entries.count - kLogBufferCapacity)];
    }
    BOOL hasSubscribers = _subscribers.count > 0;
    BOOL needsSchedule = hasSubscribers && !_signalScheduled;
    CFTimeInterval wait = 0;
    if (needsSchedule) {
        _signalScheduled = YES;
        wait = MAX(0, _lastSignalTime + kLogChangeSignalMinInterval - [[NSProcessInfo processInfo] systemUptime]);
    }
    [_lock unlock];

    if (!needsSchedule) {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self deliverChangeSignal];
    });
}

// Main queue.
- (void)deliverChangeSignal {
    [_lock lock];
    _signalScheduled = NO;
    _lastSignalTime = [[NSProcessInfo processInfo] systemUptime];
    NSArray<void (^)(void)> *handlers = _subscribers.allValues;
    [_lock unlock];

    for (void (^handler)(void) in handlers) {
        handler();
    }
}

@end
