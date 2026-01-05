//
//  LogBuffer.h
//  Moonlight
//

#import "Logger.h"
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const MoonlightLogDidAppendNotification;
FOUNDATION_EXPORT NSString *const MoonlightLogNotificationLineKey;
FOUNDATION_EXPORT NSString *const MoonlightLogNotificationLevelKey;

@interface LogBuffer : NSObject

+ (instancetype)shared;

- (void)appendLine:(NSString *)line level:(LogLevel)level;
- (NSArray<NSString *> *)allLines;

@end

NS_ASSUME_NONNULL_END
