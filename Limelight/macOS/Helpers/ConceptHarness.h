//
//  ConceptHarness.h
//  Concept-only test harness for the hosts/apps page design round. Active only when
//  MLC_HARNESS is set in the environment; with it unset nothing here runs.
//
#import <Cocoa/Cocoa.h>

@class TemporaryHost;
@class TemporaryApp;

NS_ASSUME_NONNULL_BEGIN

@interface ConceptHarness : NSObject
+ (BOOL)enabled;
/// Enabled and no MLC_REAL_NET: discovery and the host requests are replaced by the mock state.
+ (BOOL)networkMocked;
/// Which design variant the scene should show (MLC_VARIANT), empty when unset.
+ (NSString *)variant;
/// Mock runtime state (online/offline, latency, running app) for a host loaded from the store.
+ (void)applyMockRuntimeStateToHost:(TemporaryHost *)host;
+ (void)applyMockExtrasToApp:(TemporaryApp *)app;
+ (void)seedIfNeeded;
+ (void)startScripted;
@end

NS_ASSUME_NONNULL_END
