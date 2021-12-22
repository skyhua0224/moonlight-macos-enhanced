//
//  NSDictionary+F.h
//  Functional
//
//  Created by Hannes Walz on 07.04.12.
//  Copyright 2012 leuchtetgruen. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "F.h"

@interface NSDictionary(F)
    - (void) each:(VoidIteratorDictBlock) block;
    - (NSDictionary *) map:(MapDictBlock) block;
    - (id) reduce:(ReduceDictBlock) block withInitialMemo:(id) memo;
    - (NSDictionary*) filter:(BoolDictionaryBlock) block;
    - (NSDictionary*) reject:(BoolDictionaryBlock) block;
    - (BOOL) isValidForAll:(BoolDictionaryBlock) block;
    - (BOOL) isValidForAny:(BoolDictionaryBlock) block;
    - (NSNumber *) countValidEntries:(BoolDictionaryBlock) block;
    - (id) max:(CompareDictBlock) block;
    - (id) min:(CompareDictBlock) block;
@end
