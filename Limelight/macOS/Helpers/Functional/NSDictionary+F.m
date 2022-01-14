//
//  NSDictionary+F.m
//  Functional
//
//  Created by Hannes Walz on 07.04.12.
//  Copyright 2012 leuchtetgruen. All rights reserved.
//

#import "NSDictionary+F.h"

@implementation NSDictionary(F)

- (void) each:(VoidIteratorDictBlock) block {
    [F eachInDict:self withBlock:block];
}

- (NSDictionary *) map:(MapDictBlock) block {
    return [F mapDict:self withBlock:block];
}

- (id) reduce:(ReduceDictBlock) block withInitialMemo:(id) memo {
    return [F reduceDictionary:self withBlock:block andInitialMemo:memo];
}

- (id) filter:(BoolDictionaryBlock) block {
    return [F filterDictionary:self withBlock:block];
}

- (NSDictionary*) reject:(BoolDictionaryBlock) block {
    return [F rejectDictionary:self withBlock:block];
}

- (BOOL) isValidForAll:(BoolDictionaryBlock) block {
    return [F allInDictionary:self withBlock:block];
}

- (BOOL) isValidForAny:(BoolDictionaryBlock) block {
    return [F anyInDictionary:self withBlock:block];
}

- (NSNumber *) countValidEntries:(BoolDictionaryBlock) block {
    return [F countInDictionary:self withBlock:block];
}

- (id) max:(CompareDictBlock) block {
    return [F maxDict:self withBlock:block];
}

- (id) min:(CompareDictBlock) block {
    return [F minDict:self withBlock:block];
}
@end
