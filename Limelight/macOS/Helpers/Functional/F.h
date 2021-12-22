//
//  F.h
//  Functional
//
//  Created by Hannes Walz on 07.04.12.
//  Copyright 2012 leuchtetgruen. All rights reserved.
//

#import <Foundation/Foundation.h>


typedef void (^VoidIteratorArrayBlock)(id obj);
typedef void (^VoidIteratorArrayWithIndexBlock)(id obj, NSInteger idx);
typedef void (^VoidIteratorDictBlock)(id key, id value);

typedef id (^MapArrayBlock)(id obj);
typedef id (^MapDictBlock)(id key, id obj);
typedef id (^MapIntBlock) (NSInteger i);

typedef NSArray * (^BindArrayBlock)(id obj);

typedef id (^ReduceArrayBlock)(id memo, id obj);
typedef id (^ReduceDictBlock)(id memo, id key, id value);

typedef BOOL (^BoolArrayBlock)(id obj);
typedef BOOL (^BoolDictionaryBlock)(id key, id value);

typedef NSComparisonResult (^CompareArrayBlock) (id a, id b);
typedef NSComparisonResult (^CompareDictBlock) (id k1, id v1 , id k2, id v2);

typedef void (^VoidBlock) (void);


@interface F : NSObject
    + (void) useConcurrency;
    + (void) dontUseConcurrency;
    + (void) useQueue:(dispatch_queue_t) queue;

    + (void) concurrently:(VoidBlock) block;
    + (void) concurrently:(VoidBlock)block withQueue:(dispatch_queue_t) queue;



    + (void) eachInArray:(NSArray *) arr withBlock:(VoidIteratorArrayBlock) block;
    + (void) eachInArrayWithIndex:(NSArray *) arr withBlock:(VoidIteratorArrayWithIndexBlock) block;
    + (void) eachInDict:(NSDictionary *) dict withBlock:(VoidIteratorDictBlock) block;

    + (NSArray *) mapArray:(NSArray *) arr withBlock:(MapArrayBlock) block;
    + (NSDictionary *) mapDict:(NSDictionary *) dict withBlock:(MapDictBlock) block;

    + (NSArray *) bindArray:(NSArray *) arr withBlock:(BindArrayBlock) block;
    + (NSArray *) zipArray:(NSArray *) lhs with:(NSArray *) rhs;

    + (NSObject *) reduceArray:(NSArray *) arr withBlock:(ReduceArrayBlock) block andInitialMemo:(id) memo;
    + (NSObject *) reduceDictionary:(NSDictionary *) dict withBlock:(ReduceDictBlock) block andInitialMemo:(id) memo;

    + (NSArray *) filterArray:(NSArray *) arr withBlock:(BoolArrayBlock) block;
    + (NSDictionary *) filterDictionary:(NSDictionary *) dict withBlock:(BoolDictionaryBlock) block;

    + (NSArray *) rejectArray:(NSArray *) arr withBlock:(BoolArrayBlock) block;
    + (NSDictionary *) rejectDictionary:(NSDictionary *) dict withBlock:(BoolDictionaryBlock) block;

    + (BOOL) allInArray:(NSArray *) arr withBlock:(BoolArrayBlock) block;
    + (BOOL) allInDictionary:(NSDictionary *) dict withBlock:(BoolDictionaryBlock) block;

    + (BOOL) anyInArray:(NSArray *) arr withBlock:(BoolArrayBlock) block;
    + (BOOL) anyInDictionary:(NSDictionary *) dict withBlock:(BoolDictionaryBlock) block;

    + (NSNumber *) countInArray:(NSArray *) arr withBlock:(BoolArrayBlock) block;
    + (NSNumber *) countInDictionary:(NSDictionary *) dict withBlock:(BoolDictionaryBlock) block;

    + (NSObject *) maxArray:(NSArray *) arr withBlock:(CompareArrayBlock) block;
    + (NSObject *) maxDict:(NSDictionary *) dict withBlock:(CompareDictBlock) block;
    + (NSObject *) minArray:(NSArray *) arr withBlock:(CompareArrayBlock) block;
    + (NSObject *) minDict:(NSDictionary *) dict withBlock:(CompareDictBlock) block;

    + (NSDictionary *) groupArray:(NSArray *) arr withBlock:(MapArrayBlock) block;
//    + (NSDictionary *) groupDictionary:(NSDictionary *) dict withBlock:(MapDictBlock) block;

    + (NSArray *) dropFromArray:(NSArray *) arr whileBlock:(BoolArrayBlock) block;

    + (void) times:(NSNumber *) nr RunBlock:(VoidBlock) block;

    + (void) asynchronously:(VoidBlock) block;
    + (void) onUIThread:(VoidBlock) block;
    + (NSArray *) mapRangeFrom:(NSInteger) from To:(NSInteger) to withBlock:(MapIntBlock) block;
@end
