//
//  HIDSupport+Scroll.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 26/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//
#import "HIDSupport_Internal.h"

static uint64_t const HIDGCMouseScrollDuplicateSuppressMs = 45;

static inline void HIDUpdateScrollRuntimeStatus(HIDSupport *support, HIDScrollClassification classification) {
    NSString *summaryKey = @"Scroll Runtime Path Wheel";
    NSString *detailKey = @"Scroll Runtime Detail Wheel";

    switch (classification.semanticKind) {
        case HIDScrollSemanticKindContinuousGestureScroll:
            summaryKey = @"Scroll Runtime Path Gesture";
            detailKey = @"Scroll Runtime Detail Gesture";
            break;
        case HIDScrollSemanticKindSyntheticOrRewrittenScroll:
            summaryKey = @"Scroll Runtime Path Synthetic";
            detailKey = @"Scroll Runtime Detail Synthetic";
            break;
        case HIDScrollSemanticKindHorizontalWheel:
        case HIDScrollSemanticKindDiscreteWheel:
        default:
            break;
    }

    [SettingsClass updateScrollInputRuntimeStatusFor:support.host.uuid
                                          summaryKey:summaryKey
                                           detailKey:detailKey];
}

static inline BOOL HIDPhysicalWheelModePrefersHighPrecision(HIDPhysicalWheelModeOption mode) {
    switch (mode) {
        case HIDPhysicalWheelModeOptionAutomatic:
        case HIDPhysicalWheelModeOptionHighPrecision:
            return YES;
        case HIDPhysicalWheelModeOptionNotched:
        default:
            return NO;
    }
}

@implementation HIDSupport (Scroll)

- (void)handleGCMouseScrollValueY:(float)value API_AVAILABLE(macos(11.0)) {
    if (!self.useGCMouse || !self.shouldSendInputEvents || !isfinite(value) || value == 0.0f) {
        return;
    }

    uint64_t traceId = [self prepareScrollTraceFromSource:@"gcmouse"
                                                rawDeltaX:0.0
                                                rawDeltaY:value
                                                    phase:NSEventPhaseNone
                                            momentumPhase:NSEventPhaseNone
                                         hasPreciseDeltas:YES];

    CGFloat mappedDeltaY = value;
    if ([SettingsClass reverseScrollDirectionFor:self.host.uuid]) {
        mappedDeltaY = -mappedDeltaY;
    }

    signed char clicks = mappedDeltaY > 0.0f ? 1 : -1;
    uint64_t nowMs = LiGetMillis();
    BOOL suppressForPreciseTrace = NO;
    if (traceId != 0) {
        @synchronized (self.inputDiagnosticsLock) {
            suppressForPreciseTrace = self.activeScrollTraceId == traceId &&
                                      self.activeScrollTraceLockedToPrecise;
        }
    }
    if (suppressForPreciseTrace) {
        [self recordScrollInputDiagnosticsMode:@"gc-wheel-suppressed-precise-trace"
                                       traceId:traceId
                                     rawDeltaX:0.0
                                     rawDeltaY:mappedDeltaY
                                  rawWheelDeltaX:0
                                  rawWheelDeltaY:0
                              normalizedDeltaX:0.0
                              normalizedDeltaY:0.0
                                    continuous:NO
                              hasPreciseDeltas:YES
                                   lineDeltaX:0
                                   lineDeltaY:0
                                  pointDeltaX:0
                                  pointDeltaY:0
                                fixedDeltaXRaw:0
                                fixedDeltaYRaw:0
                                         phase:NSEventPhaseNone
                                 momentumPhase:NSEventPhaseNone
                                    dispatchedX:0
                                    dispatchedY:0];
        return;
    }
    uint64_t elapsedMs = self.gcMouseScrollLastEventMsY != 0 && nowMs >= self.gcMouseScrollLastEventMsY
        ? (nowMs - self.gcMouseScrollLastEventMsY)
        : UINT64_MAX;
    BOOL sameDirection = (self.gcMouseScrollLastClickY > 0 && clicks > 0) ||
                         (self.gcMouseScrollLastClickY < 0 && clicks < 0);

    if (sameDirection && elapsedMs <= HIDGCMouseScrollDuplicateSuppressMs) {
        self.suppressAppKitScrollUntilMsY = nowMs + HIDGCMouseAppKitSuppressMs;
        [self recordScrollInputDiagnosticsMode:@"gc-wheel-suppressed"
                                       traceId:traceId
                                     rawDeltaX:0.0
                                     rawDeltaY:mappedDeltaY
                                  rawWheelDeltaX:0
                                  rawWheelDeltaY:0
                              normalizedDeltaX:0.0
                              normalizedDeltaY:0.0
                                    continuous:NO
                              hasPreciseDeltas:YES
                                   lineDeltaX:0
                                   lineDeltaY:0
                                  pointDeltaX:0
                                  pointDeltaY:0
                                fixedDeltaXRaw:0
                                fixedDeltaYRaw:0
                                         phase:NSEventPhaseNone
                                 momentumPhase:NSEventPhaseNone
                                    dispatchedX:0
                                    dispatchedY:0];
        return;
    }

    self.gcMouseScrollLastEventMsY = nowMs;
    self.gcMouseScrollLastClickY = clicks;
    self.suppressAppKitScrollUntilMsY = nowMs + HIDGCMouseAppKitSuppressMs;
    self.accumulatedHighResScrollDeltaY = 0.0;
    self.accumulatedQuantizedWheelDeltaY = 0.0;
    self.accumulatedQuantizedWheelLastEventMsY = 0;
    CGFloat wheelSpeed = HIDWheelScrollSpeedForHost(self.host);

    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (!HIDValidateInputContext(inputCtx, "gcMouseScroll")) {
        return;
    }

    short dispatchedAmount = (short)lrint((CGFloat)(clicks * HIDScrollWheelDelta) * wheelSpeed);
    if (dispatchedAmount == 0) {
        dispatchedAmount = clicks > 0 ? 1 : -1;
    }

    LiNoteScrollTraceLocalDispatchCtx(inputCtx,
                                      traceId,
                                      nowMs,
                                      dispatchedAmount,
                                      false,
                                      false);
    LiSendHighResScrollEventCtx(inputCtx, dispatchedAmount);
    [SettingsClass updateScrollInputRuntimeStatusFor:self.host.uuid
                                          summaryKey:@"Scroll Runtime Path GameController"
                                           detailKey:@"Scroll Runtime Detail GameController"];
    [self recordScrollInputDiagnosticsMode:@"gc-wheel-quantized"
                                   traceId:traceId
                                 rawDeltaX:0.0
                                 rawDeltaY:mappedDeltaY
                              rawWheelDeltaX:0
                              rawWheelDeltaY:0
                          normalizedDeltaX:0.0
                          normalizedDeltaY:(CGFloat)clicks
                                continuous:NO
                          hasPreciseDeltas:YES
                               lineDeltaX:0
                               lineDeltaY:0
                              pointDeltaX:0
                              pointDeltaY:0
                                fixedDeltaXRaw:0
                                fixedDeltaYRaw:0
                                     phase:NSEventPhaseNone
                             momentumPhase:NSEventPhaseNone
                                    dispatchedX:0
                                    dispatchedY:dispatchedAmount];
}

- (void)scrollWheel:(NSEvent *)event {
    uint64_t traceId = [self prepareScrollTraceFromSource:@"appkit"
                                                rawDeltaX:event.scrollingDeltaX
                                                rawDeltaY:event.scrollingDeltaY
                                                    phase:event.phase
                                            momentumPhase:event.momentumPhase
                                         hasPreciseDeltas:event.hasPreciseScrollingDeltas];
    CGFloat absDeltaX = fabs(event.scrollingDeltaX);
    CGFloat absDeltaY = fabs(event.scrollingDeltaY);
    
    CGFloat deltaX = event.scrollingDeltaX;
    CGFloat deltaY = event.scrollingDeltaY;
    
    if ([SettingsClass reverseScrollDirectionFor:self.host.uuid]) {
        deltaX = -deltaX;
        deltaY = -deltaY;
    }

    BOOL horizontalDominant = absDeltaX > absDeltaY;
    NSInteger lineDeltaX = HIDScrollEventIntegerField(event, kCGScrollWheelEventDeltaAxis2);
    NSInteger lineDeltaY = HIDScrollEventIntegerField(event, kCGScrollWheelEventDeltaAxis1);
    NSInteger pointDeltaX = HIDScrollEventIntegerField(event, kCGScrollWheelEventPointDeltaAxis2);
    NSInteger pointDeltaY = HIDScrollEventIntegerField(event, kCGScrollWheelEventPointDeltaAxis1);
    NSInteger rawWheelDeltaX = HIDScrollEventIntegerField(event, kCGScrollWheelEventRawDeltaAxis2);
    NSInteger rawWheelDeltaY = HIDScrollEventIntegerField(event, kCGScrollWheelEventRawDeltaAxis1);
    NSInteger fixedDeltaXRaw = HIDScrollEventIntegerField(event, kCGScrollWheelEventFixedPtDeltaAxis2);
    NSInteger fixedDeltaYRaw = HIDScrollEventIntegerField(event, kCGScrollWheelEventFixedPtDeltaAxis1);
    NSInteger dominantRawWheelDelta = horizontalDominant ? rawWheelDeltaX : rawWheelDeltaY;
    NSInteger dominantLineDelta = horizontalDominant ? lineDeltaX : lineDeltaY;
    NSInteger dominantFixedDeltaRaw = horizontalDominant ? fixedDeltaXRaw : fixedDeltaYRaw;
    HIDScrollClassification classification = HIDClassifyAppKitScrollEvent(self,
                                                                          event,
                                                                          horizontalDominant,
                                                                          dominantRawWheelDelta,
                                                                          dominantLineDelta,
                                                                          dominantFixedDeltaRaw);
    BOOL precise = classification.semanticKind == HIDScrollSemanticKindContinuousGestureScroll;
    BOOL syntheticRewritten = classification.semanticKind == HIDScrollSemanticKindSyntheticOrRewrittenScroll;
    BOOL highResolutionPath = precise || syntheticRewritten;
    BOOL quantizedWheel = classification.quantizedWheel;
    BOOL appKitWheelLikeCandidate = classification.wheelLikeCandidate;
    BOOL physicalWheelSemantic = classification.semanticKind == HIDScrollSemanticKindDiscreteWheel ||
                                 classification.semanticKind == HIDScrollSemanticKindHorizontalWheel;
    HIDPhysicalWheelModeOption physicalWheelMode = HIDPhysicalWheelModeForHost(self.host);
    HIDRewrittenScrollModeOption rewrittenScrollMode = HIDRewrittenScrollModeForHost(self.host);
    if (!horizontalDominant &&
        self.suppressAppKitScrollUntilMsY > LiGetMillis() &&
        appKitWheelLikeCandidate) {
        [self recordScrollInputDiagnosticsMode:@"appkit-wheel-suppressed"
                                       traceId:traceId
                                     rawDeltaX:deltaX
                                     rawDeltaY:deltaY
                                  rawWheelDeltaX:rawWheelDeltaX
                                  rawWheelDeltaY:rawWheelDeltaY
                              normalizedDeltaX:0.0
                              normalizedDeltaY:0.0
                                    continuous:NO
                              hasPreciseDeltas:event.hasPreciseScrollingDeltas
                                   lineDeltaX:lineDeltaX
                                   lineDeltaY:lineDeltaY
                                  pointDeltaX:pointDeltaX
                                  pointDeltaY:pointDeltaY
                                fixedDeltaXRaw:fixedDeltaXRaw
                                fixedDeltaYRaw:fixedDeltaYRaw
                                         phase:event.phase
                                 momentumPhase:event.momentumPhase
                                    dispatchedX:0
                                    dispatchedY:0];
        return;
    }
    BOOL shouldLockTraceToPrecise = precise && !quantizedWheel;
    BOOL traceLockedToPrecise = NO;
    if (traceId != 0) {
        @synchronized (self.inputDiagnosticsLock) {
            if (self.activeScrollTraceId == traceId) {
                if (shouldLockTraceToPrecise) {
                    self.activeScrollTraceLockedToPrecise = YES;
                }
                traceLockedToPrecise = self.activeScrollTraceLockedToPrecise;
            }
        }
    }
    if (traceLockedToPrecise) {
        precise = YES;
        syntheticRewritten = NO;
        highResolutionPath = YES;
        quantizedWheel = NO;
        classification.semanticKind = HIDScrollSemanticKindContinuousGestureScroll;
        classification.quantizedWheel = NO;
        classification.capabilities |= HIDInputCapabilityContinuousScrollGesture;
    } else {
        precise = classification.semanticKind == HIDScrollSemanticKindContinuousGestureScroll;
        syntheticRewritten = classification.semanticKind == HIDScrollSemanticKindSyntheticOrRewrittenScroll;
        highResolutionPath = precise || syntheticRewritten;
        quantizedWheel = classification.quantizedWheel;
    }
    BOOL forceSyntheticNotched = NO;
    if (syntheticRewritten) {
        switch (rewrittenScrollMode) {
            case HIDRewrittenScrollModeOptionNotched:
                forceSyntheticNotched = YES;
                highResolutionPath = NO;
                quantizedWheel = NO;
                break;
            case HIDRewrittenScrollModeOptionHighPrecision:
                highResolutionPath = YES;
                quantizedWheel = NO;
                break;
            case HIDRewrittenScrollModeOptionAdaptive:
            default:
                break;
        }
    } else if (physicalWheelSemantic && !precise) {
        BOOL prefersHighPrecision = HIDPhysicalWheelModePrefersHighPrecision(physicalWheelMode);
        highResolutionPath = prefersHighPrecision;
        quantizedWheel = !prefersHighPrecision;
    }
    CGFloat normalizedDeltaX = 0.0;
    CGFloat normalizedDeltaY = 0.0;
    short dispatchedDeltaX = 0;
    short dispatchedDeltaY = 0;
    NSString *scrollMode = HIDScrollDiagnosticModeForClassification(classification);
    CGFloat wheelScrollSpeed = HIDWheelScrollSpeedForHost(self.host);
    CGFloat rewrittenScrollSpeed = HIDRewrittenScrollSpeedForHost(self.host);
    CGFloat gestureScrollSpeed = HIDGestureScrollSpeedForHost(self.host);
    CGFloat smartWheelTailFilter = HIDSmartWheelTailFilterForHost(self.host);

    if (syntheticRewritten) {
        switch (rewrittenScrollMode) {
            case HIDRewrittenScrollModeOptionNotched:
                scrollMode = @"appkit-rewritten-notched";
                break;
            case HIDRewrittenScrollModeOptionHighPrecision:
                scrollMode = @"appkit-rewritten-high-precision";
                break;
            case HIDRewrittenScrollModeOptionAdaptive:
            default:
                break;
        }
    } else if (physicalWheelSemantic && !precise) {
        if (physicalWheelMode == HIDPhysicalWheelModeOptionAutomatic) {
            scrollMode = horizontalDominant ? @"appkit-horizontal-wheel-auto" : @"appkit-wheel-auto";
        } else if (physicalWheelMode == HIDPhysicalWheelModeOptionHighPrecision) {
            scrollMode = horizontalDominant ? @"appkit-horizontal-wheel-high-precision" : @"appkit-wheel-high-precision";
        }
    }

    if (quantizedWheel) {
        self.accumulatedHighResScrollDeltaX = 0.0;
        self.accumulatedHighResScrollDeltaY = 0.0;
        BOOL deduplicateQuantizedWheel = self.useGCMouse;

        if (horizontalDominant) {
            NSInteger discreteDeltaX = HIDScrollEventDiscreteDeltaForAxis(event,
                                                                          kCGScrollWheelEventRawDeltaAxis2,
                                                                          kCGScrollWheelEventDeltaAxis2,
                                                                          -deltaX);
            signed char clicks = HIDDeduplicatedScrollClick(self,
                                                            HIDNormalizedDiscreteScrollClick(discreteDeltaX),
                                                            YES,
                                                            deduplicateQuantizedWheel);
            dispatchedDeltaX = (short)lrint((CGFloat)(clicks * HIDScrollWheelDelta) * wheelScrollSpeed);
            normalizedDeltaX = (CGFloat)clicks * wheelScrollSpeed;
        } else {
            NSInteger discreteDeltaY = HIDScrollEventDiscreteDeltaForAxis(event,
                                                                          kCGScrollWheelEventRawDeltaAxis1,
                                                                          kCGScrollWheelEventDeltaAxis1,
                                                                          deltaY);
            signed char clicks = HIDDeduplicatedScrollClick(self,
                                                            HIDNormalizedDiscreteScrollClick(discreteDeltaY),
                                                            NO,
                                                            deduplicateQuantizedWheel);
            dispatchedDeltaY = (short)lrint((CGFloat)(clicks * HIDScrollWheelDelta) * wheelScrollSpeed);
            normalizedDeltaY = (CGFloat)clicks * wheelScrollSpeed;
        }

    } else if (forceSyntheticNotched) {
        self.accumulatedQuantizedWheelLastEventMsX = 0;
        self.accumulatedQuantizedWheelLastEventMsY = 0;
        self.accumulatedQuantizedWheelDeltaX = 0.0;
        self.accumulatedQuantizedWheelDeltaY = 0.0;
        if (horizontalDominant) {
            CGFloat rewrittenDeltaX = -deltaX * rewrittenScrollSpeed;
            if (smartWheelTailFilter > 0.0 && fabs(rewrittenDeltaX) < smartWheelTailFilter) {
                rewrittenDeltaX = 0.0;
            }
            if ((self.accumulatedHighResScrollDeltaX < 0.0 && rewrittenDeltaX > 0.0) ||
                (self.accumulatedHighResScrollDeltaX > 0.0 && rewrittenDeltaX < 0.0)) {
                self.accumulatedHighResScrollDeltaX = 0.0;
            }
            self.accumulatedHighResScrollDeltaX += rewrittenDeltaX;
            CGFloat accumulatedDeltaX = self.accumulatedHighResScrollDeltaX;
            signed char clicks = HIDConsumeAccumulatedDiscreteScrollClick(&accumulatedDeltaX);
            self.accumulatedHighResScrollDeltaX = accumulatedDeltaX;
            dispatchedDeltaX = (short)lrint((CGFloat)(clicks * HIDScrollWheelDelta));
            normalizedDeltaX = (CGFloat)clicks;
        } else {
            CGFloat rewrittenDeltaY = deltaY * rewrittenScrollSpeed;
            if (smartWheelTailFilter > 0.0 && fabs(rewrittenDeltaY) < smartWheelTailFilter) {
                rewrittenDeltaY = 0.0;
            }
            if ((self.accumulatedHighResScrollDeltaY < 0.0 && rewrittenDeltaY > 0.0) ||
                (self.accumulatedHighResScrollDeltaY > 0.0 && rewrittenDeltaY < 0.0)) {
                self.accumulatedHighResScrollDeltaY = 0.0;
            }
            self.accumulatedHighResScrollDeltaY += rewrittenDeltaY;
            CGFloat accumulatedDeltaY = self.accumulatedHighResScrollDeltaY;
            signed char clicks = HIDConsumeAccumulatedDiscreteScrollClick(&accumulatedDeltaY);
            self.accumulatedHighResScrollDeltaY = accumulatedDeltaY;
            dispatchedDeltaY = (short)lrint((CGFloat)(clicks * HIDScrollWheelDelta));
            normalizedDeltaY = (CGFloat)clicks;
        }
    } else if (highResolutionPath) {
        self.accumulatedQuantizedWheelDeltaX = 0.0;
        self.accumulatedQuantizedWheelDeltaY = 0.0;
        self.accumulatedQuantizedWheelLastEventMsX = 0;
        self.accumulatedQuantizedWheelLastEventMsY = 0;
        CGFloat scrollSpeed = gestureScrollSpeed;
        if (syntheticRewritten) {
            scrollSpeed = rewrittenScrollSpeed;
        } else if (physicalWheelSemantic) {
            scrollSpeed = HIDPhysicalWheelModePrefersHighPrecision(physicalWheelMode)
                ? HIDPhysicalWheelHighPrecisionScrollSpeed(self.host, wheelScrollSpeed)
                : wheelScrollSpeed;
        }
        if (horizontalDominant) {
            CGFloat highResDeltaX = -deltaX * scrollSpeed;
            if (syntheticRewritten && smartWheelTailFilter > 0.0 && fabs(highResDeltaX) < smartWheelTailFilter) {
                highResDeltaX = 0.0;
            }
            if ((self.accumulatedHighResScrollDeltaX < 0.0 && highResDeltaX > 0.0) ||
                (self.accumulatedHighResScrollDeltaX > 0.0 && highResDeltaX < 0.0)) {
                self.accumulatedHighResScrollDeltaX = 0.0;
            }
            self.accumulatedHighResScrollDeltaX += highResDeltaX;
            CGFloat accumulatedDeltaX = self.accumulatedHighResScrollDeltaX;
            dispatchedDeltaX = HIDDispatchAccumulatedHighResScrollDelta(&accumulatedDeltaX);
            self.accumulatedHighResScrollDeltaX = accumulatedDeltaX;
            normalizedDeltaX = (CGFloat)dispatchedDeltaX;
        } else {
            CGFloat highResDeltaY = deltaY * scrollSpeed;
            if (syntheticRewritten && smartWheelTailFilter > 0.0 && fabs(highResDeltaY) < smartWheelTailFilter) {
                highResDeltaY = 0.0;
            }
            if ((self.accumulatedHighResScrollDeltaY < 0.0 && highResDeltaY > 0.0) ||
                (self.accumulatedHighResScrollDeltaY > 0.0 && highResDeltaY < 0.0)) {
                self.accumulatedHighResScrollDeltaY = 0.0;
            }
            self.accumulatedHighResScrollDeltaY += highResDeltaY;
            CGFloat accumulatedDeltaY = self.accumulatedHighResScrollDeltaY;
            dispatchedDeltaY = HIDDispatchAccumulatedHighResScrollDelta(&accumulatedDeltaY);
            self.accumulatedHighResScrollDeltaY = accumulatedDeltaY;
            normalizedDeltaY = (CGFloat)dispatchedDeltaY;
        }
    } else {
        self.accumulatedQuantizedWheelDeltaX = 0.0;
        self.accumulatedQuantizedWheelDeltaY = 0.0;
        self.accumulatedQuantizedWheelLastEventMsX = 0;
        self.accumulatedQuantizedWheelLastEventMsY = 0;
        self.accumulatedHighResScrollDeltaX = 0.0;
        self.accumulatedHighResScrollDeltaY = 0.0;
        if (horizontalDominant) {
            NSInteger discreteDeltaX = HIDScrollEventDiscreteDeltaForAxis(event,
                                                                          kCGScrollWheelEventRawDeltaAxis2,
                                                                          kCGScrollWheelEventDeltaAxis2,
                                                                          -deltaX);
            signed char clicks = HIDNormalizedDiscreteScrollClick(discreteDeltaX);
            dispatchedDeltaX = (short)lrint((CGFloat)(clicks * HIDScrollWheelDelta) * wheelScrollSpeed);
            normalizedDeltaX = (CGFloat)clicks * wheelScrollSpeed;
        } else {
            NSInteger discreteDeltaY = HIDScrollEventDiscreteDeltaForAxis(event,
                                                                          kCGScrollWheelEventRawDeltaAxis1,
                                                                          kCGScrollWheelEventDeltaAxis1,
                                                                          deltaY);
            signed char clicks = HIDNormalizedDiscreteScrollClick(discreteDeltaY);
            dispatchedDeltaY = (short)lrint((CGFloat)(clicks * HIDScrollWheelDelta) * wheelScrollSpeed);
            normalizedDeltaY = (CGFloat)clicks * wheelScrollSpeed;
        }
    }

    if (self.shouldSendInputEvents) {
        PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
        if (!HIDValidateInputContext(inputCtx, "scrollWheel")) {
            return;
        }
        BOOL dispatchHorizontal = dispatchedDeltaX != 0;
        short dispatchAmount = dispatchHorizontal ? dispatchedDeltaX : dispatchedDeltaY;
        BOOL dispatchHighRes = highResolutionPath && !quantizedWheel;
        if (dispatchAmount != 0) {
            LiNoteScrollTraceLocalDispatchCtx(inputCtx,
                                              traceId,
                                              LiGetMillis(),
                                              dispatchAmount,
                                              dispatchHighRes,
                                              dispatchHorizontal);
        }
        if (dispatchedDeltaX != 0) {
            LiSendHighResHScrollEventCtx(inputCtx, dispatchedDeltaX);
        } else if (dispatchedDeltaY != 0) {
            LiSendHighResScrollEventCtx(inputCtx, dispatchedDeltaY);
        }
    }

    [self recordScrollInputDiagnosticsMode:scrollMode
                                   traceId:traceId
                                 rawDeltaX:deltaX
                                 rawDeltaY:deltaY
                             rawWheelDeltaX:rawWheelDeltaX
                             rawWheelDeltaY:rawWheelDeltaY
                          normalizedDeltaX:normalizedDeltaX
                          normalizedDeltaY:normalizedDeltaY
                                continuous:precise
                          hasPreciseDeltas:event.hasPreciseScrollingDeltas
                               lineDeltaX:lineDeltaX
                               lineDeltaY:lineDeltaY
                              pointDeltaX:pointDeltaX
                              pointDeltaY:pointDeltaY
                            fixedDeltaXRaw:fixedDeltaXRaw
                            fixedDeltaYRaw:fixedDeltaYRaw
                                     phase:event.phase
                             momentumPhase:event.momentumPhase
                                dispatchedX:dispatchedDeltaX
                                dispatchedY:dispatchedDeltaY];
    HIDUpdateScrollRuntimeStatus(self, classification);
}


@end
