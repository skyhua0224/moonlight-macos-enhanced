//
//  AwdlHoldLedger.h
//  Who keeps awdl0 down, and what has to happen when the last one stops. Foundation only and part of the privileged
//  helper, not of the app: tests/awdl-hold-ledger compiles it with a fake interface.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The interface as the ledger sees it. Both blocks are called with the ledger's lock held and must not call back.
typedef struct {
    BOOL present;
    BOOL up;
} MLAwdlInterfaceSnapshot;

typedef MLAwdlInterfaceSnapshot (^MLAwdlInterfaceQuery)(void);
/// Brings the interface up or down; returns an empty string on success, otherwise the reason.
typedef NSString * _Nonnull (^MLAwdlInterfaceSetUp)(BOOL up);

@interface MLAwdlHoldLedger : NSObject

- (instancetype)initWithQuery:(MLAwdlInterfaceQuery)query setUp:(MLAwdlInterfaceSetUp)setUp NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Brings awdl0 down for `clientID`. Returns an empty string, or why it could not. A hold while another client holds (or
/// while a failed restore is pending) puts awdl0 down again only when the system brought it back up. A hold on an
/// interface that was already down leaves it as it was when the hold ends.
- (NSString *)holdForClient:(NSString *)clientID;

/// Ends the hold of `clientID`. Returns an empty string, or why awdl0 could not be brought back up; the restore is then
/// tried again by the next release, from any client, and by the next hold.
- (NSString *)releaseForClient:(NSString *)clientID;

/// The client's connection is gone: same as a release, nothing to report to.
- (void)clientDisconnected:(NSString *)clientID;

@property (nonatomic, readonly) NSUInteger holderCount;
/// The ledger put awdl0 down and has not yet seen it up again.
@property (nonatomic, readonly) BOOL restorePending;

@end

NS_ASSUME_NONNULL_END
