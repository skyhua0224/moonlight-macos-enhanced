//
//  AppListResponse.m
//  Moonlight
//
//  Created by Diego Waxemberg on 2/1/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "AppListResponse.h"
#import "TemporaryApp.h"
#import "DataManager.h"
#import <libxml2/libxml/xmlreader.h>

@implementation AppListResponse {
    NSMutableSet* _appList;
}
@synthesize data, statusCode, statusMessage;

static const char* TAG_APP = "App";
static const char* TAG_APP_TITLE = "AppTitle";
static const char* TAG_APP_ID = "ID";
static const char* TAG_HDR_SUPPORTED = "IsHdrSupported";
static const char* TAG_APP_INSTALL_PATH = "AppInstallPath";
static const char* TAG_SUPER_CMDS = "SuperCmds";

// The host serializes menu commands as a JSON array of {"id", "name"} inside
// the SuperCmds element; the literal "null" means the app has none.
static NSArray<MLAppSuperCommand *> *ParseSuperCommands(NSString *json) {
    if (json.length == 0) {
        return @[];
    }

    id parsed = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                                options:0
                                                  error:nil];
    if (![parsed isKindOfClass:[NSArray class]]) {
        return @[];
    }

    NSMutableArray<MLAppSuperCommand *> *commands = [NSMutableArray array];
    for (id entry in (NSArray *)parsed) {
        if (![entry isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        id rawId = entry[@"id"];
        id rawName = entry[@"name"];
        NSString *commandId = [rawId isKindOfClass:[NSString class]] ? rawId :
            ([rawId isKindOfClass:[NSNumber class]] ? [rawId stringValue] : nil);
        NSString *name = [rawName isKindOfClass:[NSString class]] ? rawName : nil;
        if (commandId.length == 0) {
            continue;
        }

        MLAppSuperCommand *command = [[MLAppSuperCommand alloc] init];
        command.commandId = commandId;
        command.name = name.length > 0 ? name : commandId;
        [commands addObject:command];
    }
    return commands;
}

- (void)populateWithData:(NSData *)xml {
    self.data = xml;
    _appList = [[NSMutableSet alloc] init];
    [self parseData];
}

- (void) parseData {
    xmlDocPtr docPtr = xmlParseMemory([self.data bytes], (int)[self.data length]);
    if (docPtr == NULL) {
        Log(LOG_W, @"An error occured trying to parse xml.");
        return;
    }
    
    xmlNodePtr node = xmlDocGetRootElement(docPtr);
    if (node == NULL) {
        Log(LOG_W, @"No root XML element.");
        xmlFreeDoc(docPtr);
        return;
    }
    
    xmlChar* statusStr = xmlGetProp(node, (const xmlChar*)[TAG_STATUS_CODE UTF8String]);
    if (statusStr != NULL) {
        int status = [[NSString stringWithUTF8String:(const char*)statusStr] intValue];
        xmlFree(statusStr);
        self.statusCode = status;
    }
    
    xmlChar* statusMsgXml = xmlGetProp(node, (const xmlChar*)[TAG_STATUS_MESSAGE UTF8String]);
    NSString* statusMsg;
    if (statusMsgXml != NULL) {
        statusMsg = [NSString stringWithUTF8String:(const char*)statusMsgXml];
        xmlFree(statusMsgXml);
    }
    else {
        statusMsg = @"Server Error";
    }
    self.statusMessage = statusMsg;
    
    node = node->children;
    
    while (node != NULL) {
        //Log(LOG_D, @"node: %s", node->name);
        if (!xmlStrcmp(node->name, (xmlChar*)TAG_APP)) {
            xmlNodePtr appInfoNode = node->xmlChildrenNode;
            NSString* appName = @"";
            NSString* appId = nil;
            NSString* hdrSupported = @"0";
            NSString* appInstallPath = nil;
            NSString* superCmds = nil;
            while (appInfoNode != NULL) {
                if (!xmlStrcmp(appInfoNode->name, (xmlChar*)TAG_APP_TITLE)) {
                    xmlChar* nodeVal = xmlNodeListGetString(docPtr, appInfoNode->xmlChildrenNode, 1);
                    if (nodeVal != NULL) {
                        appName = [[NSString alloc] initWithCString:(const char*)nodeVal encoding:NSUTF8StringEncoding];
                        xmlFree(nodeVal);
                    }
                } else if (!xmlStrcmp(appInfoNode->name, (xmlChar*)TAG_APP_ID)) {
                    xmlChar* nodeVal = xmlNodeListGetString(docPtr, appInfoNode->xmlChildrenNode, 1);
                    if (nodeVal != NULL) {
                        appId = [[NSString alloc] initWithCString:(const char*)nodeVal encoding:NSUTF8StringEncoding];
                        xmlFree(nodeVal);
                    }
                } else if (!xmlStrcmp(appInfoNode->name, (xmlChar*)TAG_HDR_SUPPORTED)) {
                    xmlChar* nodeVal = xmlNodeListGetString(docPtr, appInfoNode->xmlChildrenNode, 1);
                    if (nodeVal != NULL) {
                        hdrSupported = [[NSString alloc] initWithCString:(const char*)nodeVal encoding:NSUTF8StringEncoding];
                        xmlFree(nodeVal);
                    }
                } else if (!xmlStrcmp(appInfoNode->name, (xmlChar*)TAG_APP_INSTALL_PATH)) {
                    xmlChar* nodeVal = xmlNodeListGetString(docPtr, appInfoNode->xmlChildrenNode, 1);
                    if (nodeVal != NULL) {
                        appInstallPath = [[NSString alloc] initWithCString:(const char*)nodeVal encoding:NSUTF8StringEncoding];
                        xmlFree(nodeVal);
                    }
                } else if (!xmlStrcmp(appInfoNode->name, (xmlChar*)TAG_SUPER_CMDS)) {
                    xmlChar* nodeVal = xmlNodeListGetString(docPtr, appInfoNode->xmlChildrenNode, 1);
                    if (nodeVal != NULL) {
                        superCmds = [[NSString alloc] initWithCString:(const char*)nodeVal encoding:NSUTF8StringEncoding];
                        xmlFree(nodeVal);
                    }
                }

                appInfoNode = appInfoNode->next;
            }
            if (appId != nil) {
                TemporaryApp* app = [[TemporaryApp alloc] init];
                app.name = appName;
                app.id = appId;
                app.hdrSupported = [hdrSupported intValue] != 0;
                app.installPath = appInstallPath;
                app.superCommands = ParseSuperCommands(superCmds);
                [_appList addObject:app];
            }
        }
        node = node->next;
    }
    
    xmlFreeDoc(docPtr);
}

- (NSSet*) getAppList {
    return _appList;
}

- (BOOL) isStatusOk {
    return self.statusCode == 200;
}

@end
