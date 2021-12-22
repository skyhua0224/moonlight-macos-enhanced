//
//  NSNumber+F.h
//  Functional
//
//  Created by Hannes Walz on 12.04.12.
//  Copyright (c) 2012 leuchtetgruen. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "F.h"

@interface NSNumber(F)

    - (void) times:(VoidBlock) block;
@end
