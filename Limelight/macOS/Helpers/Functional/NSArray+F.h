//
//  NSArray+F.h
//  Functional
//
//  Created by Hannes Walz on 07.04.12.
//  Copyright 2012 leuchtetgruen. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "F.h"

@interface NSArray(F)
    - (void) each:(VoidIteratorArrayBlock) block;
    - (void) eachWithIndex:(VoidIteratorArrayWithIndexBlock) block;
    - (NSArray *) map:(MapArrayBlock) block;
    - (id) reduce:(ReduceArrayBlock) block withInitialMemo:(id) memo;
    - (NSArray *) bind:(BindArrayBlock) block;
    - (NSArray *) filter:(BoolArrayBlock) block;
    - (NSArray *) reject:(BoolArrayBlock) block;
    - (BOOL) isValidForAll:(BoolArrayBlock) block;
    - (BOOL) isValidForAny:(BoolArrayBlock) block;
    - (NSNumber *) countValidEntries:(BoolArrayBlock) block;

    - (id) max:(CompareArrayBlock) block;
    - (id) min:(CompareArrayBlock) block;
    - (NSArray *) sort:(NSComparator) block;
    - (NSDictionary *) group:(MapArrayBlock) block;
    - (NSArray *) zip:(NSArray *) rhs;

    - (NSArray *) dropWhile:(BoolArrayBlock) block;

    - (id) first;
    - (NSArray *) tail;
    - (NSArray *) reverse;
    - (NSArray *) flatten;

    - (NSArray *) arrayUntilIndex:(NSInteger) idx;
    - (NSArray *) arrayFromIndexOn:(NSInteger) idx;

    + (NSArray *) arrayFrom:(NSInteger) from To:(NSInteger) to;
@end
