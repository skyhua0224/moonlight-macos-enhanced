//
//  DatabaseSingleton.m
//  Moonlight
//
//  Created by Michael Kenny on 10/2/18.
//  Copyright © 2018 Moonlight Stream. All rights reserved.
//

#import "DatabaseSingleton.h"

@interface DatabaseSingleton ()
@property (strong, nonatomic) NSManagedObjectContext *managedObjectContext;
@property (strong, nonatomic) NSManagedObjectModel *managedObjectModel;
@property (strong, nonatomic) NSPersistentStoreCoordinator *persistentStoreCoordinator;
@end

@implementation DatabaseSingleton

+ (DatabaseSingleton *)shared {
    static DatabaseSingleton *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DatabaseSingleton alloc] init];
    });
    
    return instance;
}

- (void)saveContext
{
    NSError *error = nil;
    NSManagedObjectContext *managedObjectContext = self.managedObjectContext;
    if (managedObjectContext != nil) {
        if ([managedObjectContext hasChanges] && ![managedObjectContext save:&error]) {
            Log(LOG_E, @"Critical database error: %@, %@", error, [error userInfo]);
        }
    }
}

// Returns the managed object context for the application.
// If the context doesn't already exist, it is created and bound to the persistent store coordinator for the application.
- (NSManagedObjectContext *)managedObjectContext
{
    if (_managedObjectContext != nil) {
        return _managedObjectContext;
    }
    
    NSPersistentStoreCoordinator *coordinator = [self persistentStoreCoordinator];
    if (coordinator != nil) {
        _managedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        [_managedObjectContext setPersistentStoreCoordinator:coordinator];
    }
    return _managedObjectContext;
}

// Returns the managed object model for the application.
// If the model doesn't already exist, it is created from the application's model.
- (NSManagedObjectModel *)managedObjectModel
{
    if (_managedObjectModel != nil) {
        return _managedObjectModel;
    }
    _managedObjectModel = [NSManagedObjectModel mergedModelFromBundles:nil];
    return _managedObjectModel;
}

// Returns the persistent store coordinator for the application.
// If the coordinator doesn't already exist, it is created and the application's store added to it.
- (NSPersistentStoreCoordinator *)persistentStoreCoordinator
{
    if (_persistentStoreCoordinator != nil) {
        return _persistentStoreCoordinator;
    }
    
    NSURL *storeURL = [self getStoreURL];
    
    NSError *error = nil;
    _persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:[self managedObjectModel]];
    NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
                             [NSNumber numberWithBool:YES], NSMigratePersistentStoresAutomaticallyOption,
                             [NSNumber numberWithBool:YES], NSInferMappingModelAutomaticallyOption, nil];
    if (![_persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:options error:&error]) {
        // Log the error
        Log(LOG_E, @"Critical database error: %@, %@", error, [error userInfo]);
        
        // Drop the database
        [[NSFileManager defaultManager] removeItemAtURL:storeURL error:nil];
        
        // Try again
        return [self persistentStoreCoordinator];
    }
    
    return _persistentStoreCoordinator;
}


#pragma mark - Database Path

+ (NSURL *)applicationSupportDirectory {
    
    NSURL *directoryUrl = [[[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject]
            URLByAppendingPathComponent:@"Moonlight"];
    NSError *error;
    if (![[NSFileManager defaultManager] fileExistsAtPath:directoryUrl.path]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:directoryUrl.path withIntermediateDirectories:YES attributes:nil error:&error];
    }
    
    return directoryUrl;
}

- (NSURL *)getStoreURL {
    return [[DatabaseSingleton applicationSupportDirectory] URLByAppendingPathComponent:@"Moonlight_macOS.sqlite"];
}

@end
