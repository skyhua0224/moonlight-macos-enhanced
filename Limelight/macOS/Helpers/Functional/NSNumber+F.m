//
//  NSNumber+F.m
//  Functional
//
//  Created by Hannes Walz on 12.04.12.
//  Copyright (c) 2012 leuchtetgruen. All rights reserved.
//

#import "NSNumber+F.h"

@implementation NSNumber(F)

- (void) times:(VoidBlock) block {
    [F times:self RunBlock:block];
}
@end
