//
//  TemporaryApp.m
//  Moonlight
//
//  Created by Cameron Gutman on 9/30/15.
//  Copyright © 2015 Moonlight Stream. All rights reserved.
//

#import "TemporaryApp.h"

@implementation TemporaryApp

- (id) initFromApp:(App*)app withTempHost:(TemporaryHost*)tempHost {
    self = [self init];
    
    self.id = app.id;
    self.image = app.image;
    self.name = app.name;
    self.host = tempHost;
    
    return self;
}

- (void) propagateChangesToParent:(App*)parent withHost:(Host*)host {
    parent.id = self.id;
    parent.name = self.name;
    parent.host = host;
}

- (NSComparisonResult)compareName:(TemporaryApp *)other {
    BOOL selfSpecial = [TemporaryApp isSpecialName:self.name];
    BOOL otherSpecial = [TemporaryApp isSpecialName:other.name];

    if (!selfSpecial && !otherSpecial) {
        return [self.name caseInsensitiveCompare:other.name];
    } else if (!selfSpecial && otherSpecial) {
        return NSOrderedDescending;
    } else if (selfSpecial && !otherSpecial) {
        return NSOrderedAscending;
    } else {
        return [self.name caseInsensitiveCompare:other.name];
    }
}

+ (BOOL)isSpecialName:(NSString *)name {
    return [name isEqualToString:@"Desktop"] || [name isEqualToString:@"Steam"];
}

- (NSUInteger)hash {
    return [self.host.uuid hash] * 31 + [self.id intValue];
}

- (BOOL)isEqual:(id)object {
    if (self == object) {
        return YES;
    }
    
    if (![object isKindOfClass:[App class]]) {
        return NO;
    }
    
    return [self.host.uuid isEqualToString:((App*)object).host.uuid] &&
    [self.id isEqualToString:((App*)object).id];
}

@end
