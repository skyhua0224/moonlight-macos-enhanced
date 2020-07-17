//
//  DatabaseSingleton.h
//  Moonlight
//
//  Created by Michael Kenny on 10/2/18.
//  Copyright © 2018 Moonlight Stream. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface DatabaseSingleton : NSObject

+ (DatabaseSingleton *)shared;

@property (readonly, strong, nonatomic) NSManagedObjectContext *managedObjectContext;
@property (readonly, strong, nonatomic) NSManagedObjectModel *managedObjectModel;
@property (readonly, strong, nonatomic) NSPersistentStoreCoordinator *persistentStoreCoordinator;

- (void)saveContext;

+ (NSURL *)applicationSupportDirectory;

@end
