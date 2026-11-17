//
//  MLDirectTouchRecognizer.m
//  Moonlight for macOS
//

#import "MLDirectTouchRecognizer.h"

@implementation MLDirectTouchRecognizer {
    NSMutableSet<id> *_accepted;   // identities being reported
    NSMutableSet<id> *_rejected;   // identities that landed on an overlay: not ours
    NSMutableSet<id> *_allDown;    // both
    NSGestureRecognizerState _requested;
}

- (instancetype)initWithTarget:(id)target action:(SEL)action {
    self = [super initWithTarget:target action:action];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)commonInit {
    _accepted = [NSMutableSet set];
    _rejected = [NSMutableSet set];
    _allDown = [NSMutableSet set];
    // Direct touches only: the property defaults to this from macOS 27 and to nothing before, and
    // NSTouchTypeMaskIndirect (a trackpad) is not supported by gesture recognizers. The trackpad
    // keeps its own path (MLPrecisionTouchpad).
    self.allowedTouchTypes = NSTouchTypeMaskDirect;
    // Source: apple-appkit-gesture-recognizers-20261117, "Set up gesture recognizers". Apple documents this exact
    // combination for direct-touch tracking. A zero mask keeps physical
    // mouse and trackpad button events out of this recognizer.
    self.buttonMask = 0;
    self.delaysPrimaryMouseButtonEvents = NO;
}

- (NSGestureRecognizerState)lastRequestedState { return _requested; }

// Every state change goes through here, so what this recognizer decided is also readable without AppKit's
// event engine driving it (the tests).
- (void)requestState:(NSGestureRecognizerState)state {
    _requested = state;
    self.state = state;
}

- (NSUInteger)activeTouchCount {
    return _accepted.count;
}

- (void)forgetAllTouches {
    [_accepted removeAllObjects];
    [_rejected removeAllObjects];
    [_allDown removeAllObjects];
}

#pragma mark - Prevention

// Nothing may stop this recognizer. By default no two gestures can be recognized at the same time
// (NSGestureRecognizer.h, canPreventGestureRecognizer:): once this one is recognized it prevents
// the others on the same touches, which is how AppKit's touch-to-mouse emulation is kept off the
// stream. It must also never be the one that is prevented.
- (BOOL)canBePreventedByGestureRecognizer:(NSGestureRecognizer *)preventingGestureRecognizer {
    return NO;
}

- (BOOL)canPreventGestureRecognizer:(NSGestureRecognizer *)preventedGestureRecognizer {
    return YES;
}

#pragma mark - Touches

static MLTouchPhase MLPhaseFromNSTouch(NSTouchPhase phase) {
    if (phase & NSTouchPhaseCancelled) return MLTouchPhaseCancelled;
    if (phase & NSTouchPhaseEnded) return MLTouchPhaseEnded;
    if (phase & NSTouchPhaseBegan) return MLTouchPhaseBegan;
    if (phase & NSTouchPhaseMoved) return MLTouchPhaseMoved;
    return MLTouchPhaseStationary;
}

- (void)handleEvent:(NSEvent *)event {
    NSView *view = self.view;
    if (view == nil) return;
    NSSet<NSTouch *> *touches = [event touchesMatchingPhase:NSTouchPhaseAny inView:view];
    NSMutableArray<MLTouchSample *> *samples = [NSMutableArray arrayWithCapacity:touches.count];
    NSMutableArray<MLTouchSample *> *everything = [NSMutableArray arrayWithCapacity:touches.count];

    // Started before ended, so a touch that begins and ends inside one event still comes out in order.
    NSArray<NSTouch *> *ordered = [touches.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSTouch *a, NSTouch *b) {
        BOOL aBegan = (a.phase & NSTouchPhaseBegan) != 0, bBegan = (b.phase & NSTouchPhaseBegan) != 0;
        if (aBegan == bBegan) return NSOrderedSame;
        return aBegan ? NSOrderedAscending : NSOrderedDescending;
    }];

    for (NSTouch *touch in ordered) {
        if (touch.type != NSTouchTypeDirect) continue;
        id identity = touch.identity;
        MLTouchPhase phase = MLPhaseFromNSTouch(touch.phase);
        NSPoint point = [touch locationInView:view];
        [everything addObject:[MLTouchSample sampleWithIdentity:identity phase:phase point:point timestamp:event.timestamp]];
        if (phase == MLTouchPhaseEnded || phase == MLTouchPhaseCancelled) {
            [_allDown removeObject:identity];
        } else {
            [_allDown addObject:identity];
        }

        if ([_rejected containsObject:identity]) {
            if (phase == MLTouchPhaseEnded || phase == MLTouchPhaseCancelled) [_rejected removeObject:identity];
            continue;
        }
        if (![_accepted containsObject:identity]) {
            // First sight of this touch, whatever its phase says (a late attach is treated as a start).
            if (phase == MLTouchPhaseEnded || phase == MLTouchPhaseCancelled) continue;
            BOOL ours = self.acceptsTouchAtPoint == nil || self.acceptsTouchAtPoint(point);
            if (!ours) {
                [_rejected addObject:identity];
                continue;
            }
            [_accepted addObject:identity];
            phase = MLTouchPhaseBegan;
        }
        [samples addObject:[MLTouchSample sampleWithIdentity:identity phase:phase point:point timestamp:event.timestamp]];
        if (phase == MLTouchPhaseEnded || phase == MLTouchPhaseCancelled) [_accepted removeObject:identity];
    }

    // The stream's touches first, so the host hears of them at once; then everything, for the observers.
    if (samples.count > 0 && self.samplesHandler != nil) {
        self.samplesHandler(samples);
    }
    if (everything.count > 0 && self.allSamplesHandler != nil) {
        self.allSamplesHandler(everything, _allDown.count);
    }
}

- (void)advanceStateAfterEventWithCancelled:(BOOL)cancelled {
    if (_accepted.count > 0) {
        // Claiming the first accepted touch is what keeps the system's mouse emulation off it.
        [self requestState:(_requested == NSGestureRecognizerStatePossible) ? NSGestureRecognizerStateBegan
                                                                       : NSGestureRecognizerStateChanged];
    } else if (_requested == NSGestureRecognizerStatePossible) {
        // Every touch so far belongs to an overlay control: stay out of its way.
        if (_rejected.count > 0) [self requestState:NSGestureRecognizerStateFailed];
    } else {
        [self requestState:cancelled ? NSGestureRecognizerStateCancelled : NSGestureRecognizerStateEnded];
    }
}

- (void)touchesBeganWithEvent:(NSEvent *)event {
    [self handleEvent:event];
    [self advanceStateAfterEventWithCancelled:NO];
}

- (void)touchesMovedWithEvent:(NSEvent *)event {
    [self handleEvent:event];
    [self advanceStateAfterEventWithCancelled:NO];
}

- (void)touchesEndedWithEvent:(NSEvent *)event {
    [self handleEvent:event];
    [self advanceStateAfterEventWithCancelled:NO];
}

- (void)touchesCancelledWithEvent:(NSEvent *)event {
    [self handleEvent:event];
    [self advanceStateAfterEventWithCancelled:YES];
}

- (void)reset {
    [super reset];
    _requested = NSGestureRecognizerStatePossible;
    // Ended or cancelled: AppKit ignores whatever is still down, so forget it too.
    [_accepted removeAllObjects];
    [_rejected removeAllObjects];
    [_allDown removeAllObjects];
}

#pragma mark - Mouse

// This recognizer is for touches only. A mouse sequence on the view is not its business and must
// reach the view's own handling untouched.
- (void)mouseDown:(NSEvent *)event { [self requestState:NSGestureRecognizerStateFailed]; }
- (void)rightMouseDown:(NSEvent *)event { [self requestState:NSGestureRecognizerStateFailed]; }
- (void)otherMouseDown:(NSEvent *)event { [self requestState:NSGestureRecognizerStateFailed]; }

@end
