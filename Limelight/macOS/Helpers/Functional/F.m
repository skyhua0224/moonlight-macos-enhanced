//
//  F.m
//  Functional
//
//  Created by Hannes Walz on 07.04.12.
//  Copyright 2012 leuchtetgruen. All rights reserved.
//

#import "F.h"

@implementation F
static dispatch_queue_t F_queue;
static BOOL F_concurrently = NO;

+ (void) useConcurrency {
    NSLog(@"ATTENTION - USING CONCURRENCY WILL RESULT IN A NON-SEQUENTIAL EXECUTION OF THE PASSED BLOCKS");
    F_concurrently = YES;
    F_queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
}

+ (void) dontUseConcurrency {
    F_concurrently = NO;
}

+ (void) useQueue:(dispatch_queue_t) queue {
    F_queue = queue;
}

+ (void) concurrently:(VoidBlock) block {
    [self useConcurrency];
    block();
    [self dontUseConcurrency];
}

+ (void) concurrently:(VoidBlock)block withQueue:(dispatch_queue_t) queue {
    [self useConcurrency];
    [self useQueue:queue];
    block();
    [self dontUseConcurrency];
}

+ (void) eachInArray:(NSArray *) arr withBlock:(VoidIteratorArrayBlock) block {
    if (F_concurrently) {
        dispatch_apply([arr count], F_queue, ^(size_t i) {
            block([arr objectAtIndex:i]);
        });
    }
    else {
        [arr enumerateObjectsUsingBlock:^(__strong id obj, NSUInteger idx, BOOL *stop) {
            block(obj);
        }];
    }
}

+ (void) eachInArrayWithIndex:(NSArray *) arr withBlock:(VoidIteratorArrayWithIndexBlock) block {
    if (F_concurrently) {
        dispatch_apply([arr count], F_queue, ^(size_t i) {
            block([arr objectAtIndex:i], i);
        });
    }
    else {
        [arr enumerateObjectsUsingBlock:^(__strong id obj, NSUInteger idx, BOOL *stop) {
            block(obj, idx);
        }];
    }
}

+ (void) eachInDict:(NSDictionary *) dict withBlock:(VoidIteratorDictBlock) block {
    if (F_concurrently) {
        NSArray *keys = [dict allKeys];
        dispatch_apply([keys count], F_queue, ^(size_t i) {
            id key = [keys objectAtIndex:i];
            block(key, [dict objectForKey:key]);
        });
    }
    else {
        [dict enumerateKeysAndObjectsUsingBlock:^(__strong id key, __strong id obj, BOOL *stop) {
            block(key, obj);
        }];
    }
}


+ (NSArray *) mapArray:(NSArray *) arr withBlock:(MapArrayBlock) block {
    NSMutableArray *mutArr = [NSMutableArray arrayWithCapacity:[arr count]];

    if (F_concurrently) {
        for (NSUInteger i=0; i < [arr count]; i++) {
            [mutArr addObject:[NSNull null]];
        }
        dispatch_semaphore_t itemLock = dispatch_semaphore_create(1);
        dispatch_apply([arr count], F_queue, ^(size_t i) {
            id o = block([arr objectAtIndex:i]);
            dispatch_semaphore_wait(itemLock, DISPATCH_TIME_FOREVER);
            [mutArr replaceObjectAtIndex:i withObject:o];
            dispatch_semaphore_signal(itemLock);
        });
    }
    else {
        for (id obj in arr) {
            [mutArr addObject:block(obj)];
        }
    }
    return [NSArray arrayWithArray:mutArr];
}

+ (NSArray *) bindArray:(NSArray *) arr withBlock:(BindArrayBlock) block
{
    NSMutableArray *mutArr = [NSMutableArray arrayWithCapacity:[arr count]];
    for (id obj in arr) {
        [mutArr addObjectsFromArray:block(obj)];
    }
    return mutArr;
}

+ (NSArray *) zipArray:(NSArray *) lhs with:(NSArray *) rhs
{
    NSEnumerator *lEnum = [lhs objectEnumerator];
    NSEnumerator *rEnum = [rhs objectEnumerator];
    NSMutableArray *mutArr = [NSMutableArray arrayWithCapacity:MIN([lhs count],[rhs count])];
    
    while (true) {
        id leftObject = [lEnum nextObject];
        id rightObject = [rEnum nextObject];
        if (leftObject && rightObject) {
            [mutArr addObject:@[leftObject,rightObject]];
        } else {
            break;
        }
    }
    return mutArr;
}

+ (NSDictionary *) mapDict:(NSDictionary *) dict withBlock:(MapDictBlock) block {
    NSMutableDictionary *mutDict = [NSMutableDictionary dictionaryWithCapacity:[[dict allKeys] count]];

    if (F_concurrently) {
        dispatch_semaphore_t itemLock = dispatch_semaphore_create(2);
        NSArray *keys = [dict allKeys];
        dispatch_apply([keys count], F_queue, ^(size_t i) {
            id key = [keys objectAtIndex:i];
            id map_o = block(key, [dict objectForKey:key]);
            dispatch_semaphore_wait(itemLock, DISPATCH_TIME_FOREVER);
            [mutDict setValue:map_o forKey:key];
            dispatch_semaphore_signal(itemLock);
        });
    }
    else {
        for (id key in dict) {
            id obj = [dict objectForKey:key];
            [mutDict setValue:block(key, obj) forKey:key];
        }
    }
    return [NSDictionary dictionaryWithDictionary:mutDict];
}

+ (NSObject *) reduceArray:(NSArray *) arr withBlock:(ReduceArrayBlock) block andInitialMemo:(__strong id) memo {
    for (id obj in arr) {
        memo = block(memo, obj);
    }
    return memo;
}

+ (NSObject *) reduceDictionary:(NSDictionary *) dict withBlock:(ReduceDictBlock) block andInitialMemo:(__strong id) memo {
    for (id key in dict) {
        id obj = [dict objectForKey:key];
        memo = block(memo, key, obj);
    }
    return memo;
}

+ (NSArray *) filterArray:(NSArray *) arr withBlock:(BoolArrayBlock) block {
    if (F_concurrently) {
        NSMutableArray *nilArray = [NSMutableArray arrayWithCapacity:[arr count]];
        for (NSUInteger i=0; i < [arr count]; i++) {
            [nilArray addObject:[NSNull null]];
        }
        dispatch_semaphore_t itemLock = dispatch_semaphore_create(1);
        dispatch_apply([arr count], F_queue, ^(size_t i) {
            BOOL keep = block([arr objectAtIndex:i]);
            if (keep) {
                dispatch_semaphore_wait(itemLock, DISPATCH_TIME_FOREVER);
                [nilArray replaceObjectAtIndex:i withObject:[arr objectAtIndex:i]];
                dispatch_semaphore_signal(itemLock);
            }
        });
        [nilArray removeObjectIdenticalTo:[NSNull null]];
        return [NSArray arrayWithArray:nilArray];
    }
    else {
        NSMutableArray *mutArr = [NSMutableArray array];
        for (id obj in arr) {
            if (block(obj)) [mutArr addObject:obj];
        }
        return [NSArray arrayWithArray:mutArr];
    }
}

+ (NSDictionary *) filterDictionary:(NSDictionary *) dict withBlock:(BoolDictionaryBlock) block {
    NSMutableDictionary *mutDict = [NSMutableDictionary dictionaryWithCapacity:[[dict allKeys] count]];
    if (F_concurrently) {
        dispatch_semaphore_t itemLock = dispatch_semaphore_create(1);
        NSArray *keys = [dict allKeys];
        dispatch_apply([keys count], F_queue, ^(size_t i) {
            id key = [keys objectAtIndex:i];
            BOOL keep = block(key, [dict objectForKey:key]);
            if (keep) {
                dispatch_semaphore_wait(itemLock, DISPATCH_TIME_FOREVER);
                [mutDict setObject:[dict objectForKey:key] forKey:key];
                dispatch_semaphore_signal(itemLock);
            }
        });
    }
    else {
        for (id key in dict) {
            if (block(key, [dict objectForKey:key])) [mutDict setObject:[dict objectForKey:key]  forKey:key];
        }
    }
    return [NSDictionary dictionaryWithDictionary:mutDict];
}

+ (NSArray *) rejectArray:(NSArray *) arr withBlock:(BoolArrayBlock) block {
    if (F_concurrently) {
        NSMutableArray *nilArray = [NSMutableArray arrayWithCapacity:[arr count]];
        for (NSUInteger i=0; i < [arr count]; i++) {
            [nilArray addObject:[NSNull null]];
        }
        dispatch_semaphore_t itemLock = dispatch_semaphore_create(1);
        dispatch_apply([arr count], F_queue, ^(size_t i) {
            BOOL keep = !block([arr objectAtIndex:i]);
            if (keep) {
                dispatch_semaphore_wait(itemLock, DISPATCH_TIME_FOREVER);
                [nilArray replaceObjectAtIndex:i withObject:[arr objectAtIndex:i]];
                dispatch_semaphore_signal(itemLock);
            }
        });
        [nilArray removeObjectIdenticalTo:[NSNull null]];
        return [NSArray arrayWithArray:nilArray];
    }
    else {
        NSMutableArray *mutArr = [NSMutableArray array];
        for (id obj in arr) {
            if (!block(obj)) [mutArr addObject:obj];
        }
        return [NSArray arrayWithArray:mutArr];
    }
}

+ (NSDictionary *) rejectDictionary:(NSDictionary *) dict withBlock:(BoolDictionaryBlock) block {
    NSMutableDictionary *mutDict = [NSMutableDictionary dictionary];
    if (F_concurrently) {
        dispatch_semaphore_t itemLock = dispatch_semaphore_create(1);
        NSArray *keys = [dict allKeys];
        dispatch_apply([keys count], F_queue, ^(size_t i) {
            id key = [keys objectAtIndex:i];
            BOOL keep = !block(key, [dict objectForKey:key]);
            if (keep) {
                dispatch_semaphore_wait(itemLock, DISPATCH_TIME_FOREVER);
                [mutDict setObject:[dict objectForKey:key] forKey:key];
                dispatch_semaphore_signal(itemLock);
            }
        });
    }
    else {
        for (id key in dict) {
            if (!block(key, [dict objectForKey:key])) [mutDict setObject:[dict objectForKey:key]  forKey:key];
        }
    }
    return [NSDictionary dictionaryWithDictionary:mutDict];
}

+ (BOOL) allInArray:(NSArray *) arr withBlock:(BoolArrayBlock) block {
    __block BOOL validForAll = true;

    if (F_concurrently) {
        dispatch_apply([arr count], F_queue, ^(size_t i) {
            if (!validForAll) return;
            validForAll = (validForAll && block([arr objectAtIndex:i]));
        });
    }
    else {
        for (id obj in arr) {
            validForAll = (validForAll && block(obj));
            if (!validForAll) break;
        }
    }
    return validForAll;
}

+ (BOOL) allInDictionary:(NSDictionary *) dict withBlock:(BoolDictionaryBlock) block {
    __block BOOL validForAll = true;

    if (F_concurrently) {
        NSArray *keys = [dict allKeys];
        dispatch_apply([keys count], F_queue, ^(size_t i) {
            if (!validForAll) return;
            id key = [keys objectAtIndex:i];
            validForAll = (validForAll && block(key, [dict objectForKey:key]));
        });
    }
    else {
        for (id key in dict) {
            validForAll = (validForAll && block(key, [dict objectForKey:key]));
            if (!validForAll) break;
        }
    }
    return validForAll;
}

+ (BOOL) anyInArray:(NSArray *) arr withBlock:(BoolArrayBlock) block {
    __block BOOL validForAny = false;

    if (F_concurrently) {
        dispatch_apply([arr count], F_queue, ^(size_t i) {
            if (validForAny) return;
            validForAny = (validForAny || block([arr objectAtIndex:i]));
        });
    }
    else {
        for (id obj in arr) {
            validForAny = (validForAny || block(obj));
            if (validForAny) break;
        }
    }
    return validForAny;
}

+ (BOOL) anyInDictionary:(NSDictionary *) dict withBlock:(BoolDictionaryBlock) block {
    __block BOOL validForAny = false;

    if (F_concurrently) {
        NSArray *keys = [dict allKeys];
        dispatch_apply([keys count], F_queue, ^(size_t i) {
            if (validForAny) return;
            id key = [keys objectAtIndex:i];
            validForAny = (validForAny || block(key, [dict objectForKey:key]));
        });
    }
    else {
        for (id key in dict) {
            validForAny = (validForAny || block(key, [dict objectForKey:key]));
            if (validForAny) break;
        }
    }
    return validForAny;
}

+ (NSNumber *) countInArray:(NSArray *) arr withBlock:(BoolArrayBlock) block {
    __block NSInteger ctr = 0;

    if (F_concurrently) {
        dispatch_apply([arr count], F_queue, ^(size_t i) {
            if (block([arr objectAtIndex:i])) ctr++;
        });
    }
    else {
        for (id obj in arr) {
            if(block(obj)) ctr++;
        }
    }
    return [NSNumber numberWithInteger:ctr];
}

+ (NSNumber *) countInDictionary:(NSDictionary *) dict withBlock:(BoolDictionaryBlock) block {
    __block NSInteger ctr = 0;

    if (F_concurrently) {
        NSArray *keys = [dict allKeys];
        dispatch_apply([keys count], F_queue, ^(size_t i) {
            id key = [keys objectAtIndex:i];
            if (block(key, [dict objectForKey:key])) ctr++;
        });
    }
    else {
        for (id key in dict) {
            if (block(key, [dict objectForKey:key])) ctr++;
        }
    }
    return [NSNumber numberWithInteger:ctr];
}



+ (id) maxArray:(NSArray *) arr withBlock:(CompareArrayBlock) block {
    if ([arr count]<1) return NULL;

    id biggest = [arr objectAtIndex:0];
    for (id obj in arr) {
        if (block(biggest, obj) == NSOrderedAscending) biggest = obj;
    }
    return biggest;
}

+ (id) maxDict:(NSDictionary *) dict withBlock:(CompareDictBlock) block {
    if ([dict count] < 1) return NULL;

    id biggest = NULL;
    id biggestKey = @"";
    for (id key in dict) {
        if (biggest == NULL) {
            biggest = [dict objectForKey:key];
            biggestKey = key;
        }
        if (block(biggestKey, biggest, key, [dict objectForKey:key]) == NSOrderedAscending) {
            biggest = [dict objectForKey:key];
            biggestKey = key;
        }
    }
    return biggest;
}

+ (id) minArray:(NSArray *) arr withBlock:(CompareArrayBlock) block {
    if ([arr count]<1) return NULL;

    id smallest = [arr objectAtIndex:0];
    for (id obj in arr) {
        if (block(smallest, obj) == NSOrderedDescending) smallest = obj;
    }
    return smallest;
}

+ (id) minDict:(NSDictionary *) dict withBlock:(CompareDictBlock) block {
    if ([dict count] < 1) return NULL;

    id smallest = NULL;
    id smallestKey = @"";
    for (id key in dict) {
        if (smallest == NULL) {
            smallest = [dict objectForKey:key];
            smallestKey = key;
        }
        if (block(smallestKey, smallest, key, [dict objectForKey:key]) == NSOrderedDescending) {
            smallest = [dict objectForKey:key];
            smallestKey = key;
        }
    }
    return smallest;
}

+ (NSDictionary *) groupArray:(NSArray *) arr withBlock:(MapArrayBlock) block {
    NSMutableDictionary *mutDictOfMutArrays = [NSMutableDictionary dictionary];
    for (id obj in arr) {
        id transformed = block(obj);
        if ([mutDictOfMutArrays objectForKey:transformed]==nil) {
            [mutDictOfMutArrays setObject:[NSMutableArray array] forKey:transformed];
        }
        NSMutableArray *itemsInThisGroup = [mutDictOfMutArrays objectForKey:transformed];
        [itemsInThisGroup addObject:obj];
    }

    NSMutableDictionary *mutDictOfArrays = [NSMutableDictionary dictionary];
    for (id key in mutDictOfMutArrays) {

        NSMutableArray *mutArr = (NSMutableArray *) [mutDictOfMutArrays objectForKey:key];
        [mutDictOfArrays setObject:[NSArray arrayWithArray:mutArr] forKey:key];
    }
    return [NSDictionary dictionaryWithDictionary:mutDictOfArrays];
}

+ (NSArray *) dropFromArray:(NSArray *) arr whileBlock:(BoolArrayBlock) block {
    NSMutableArray *mutArray = [NSMutableArray array];
    NSUInteger i = 0;
    for (i = 0; i < [arr count]; i++) {
        if (!block([arr objectAtIndex:i])) break;
    }
    for (NSUInteger j=i; j < [arr count]; j++) {
        [mutArray addObject:[arr objectAtIndex:j]];
    }
    return [NSArray arrayWithArray:mutArray];
}

+ (void) times:(NSNumber *) nr RunBlock:(VoidBlock) block {
    for (int i=0; i < [nr intValue]; i++) block();
}


+ (void) asynchronously:(VoidBlock) block {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), block);
}

+ (void) onUIThread:(VoidBlock) block {
    if ([NSThread isMainThread]) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
}

+ (NSArray *) mapRangeFrom:(NSInteger) from To:(NSInteger) to withBlock:(MapIntBlock) block {
    NSMutableArray *mutArr = [NSMutableArray arrayWithCapacity:(to-from)];

    if (F_concurrently) {
        for (NSInteger i=from; i < to; i++) {
            [mutArr addObject:[NSNull null]];
        }
        dispatch_semaphore_t itemLock = dispatch_semaphore_create(1);
        dispatch_apply((to-from), F_queue, ^(size_t i) {
            id o = block(from + i);
            dispatch_semaphore_wait(itemLock, DISPATCH_TIME_FOREVER);
            [mutArr replaceObjectAtIndex:i withObject:o];
            dispatch_semaphore_signal(itemLock);
        });
    }
    else {
        for (NSInteger i=from; i<to; i++) {
            [mutArr addObject:block(i)];
        }
    }
    return [NSArray arrayWithArray:mutArr];
}

@end
