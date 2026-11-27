//
//  MDNSManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/14/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "TemporaryHost.h"

@protocol MDNSCallback <NSObject>

- (void) updateHost:(TemporaryHost*)host;

@end

@interface MDNSManager : NSObject <NSNetServiceBrowserDelegate, NSNetServiceDelegate>

@property id<MDNSCallback> callback;

/// The defaults that hold the 「自动发现新主机」 switch (autoDiscoverNewHosts). Standard defaults unless a test replaces them.
@property (nonatomic, strong) NSUserDefaults *defaults;
/// Answers 「is the host list on screen and the app in front」. Replaced by tests; the default looks at NSApp and its windows.
@property (nonatomic, copy) BOOL (^foregroundProvider)(void);
/// YES while the Bonjour browser is asked to search (switch on, host list visible, app active, no stream or launch).
@property (nonatomic, readonly) BOOL searchRunning;

/// The switch; absent means on.
+ (BOOL)autoDiscoveryEnabledInDefaults:(NSUserDefaults *)defaults;
/// Seconds until the browser is restarted after `round` restarts: 5 s for the first 30 s, then doubling to a 60 s cap.
+ (NSTimeInterval)restartIntervalForRound:(NSUInteger)round;
- (NSTimeInterval)restartIntervalForRound:(NSUInteger)round;
/// Creates the Bonjour browser; tests override it.
- (NSNetServiceBrowser *)makeBrowser;
/// Re-reads the switch and the window state and starts or stops the search at once. Notifications call it too.
- (void)refreshSearchPolicy;

- (id) initWithCallback:(id<MDNSCallback>) callback;
- (void) searchForHosts;
- (void) stopSearching;
- (void) forgetHosts;

@end



