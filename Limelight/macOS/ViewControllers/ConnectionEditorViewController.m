//
//  ConnectionEditorViewController.m
//  Moonlight for macOS
//
//  Created by GitHub Copilot on 2026/01/16.
//

#import "ConnectionEditorViewController.h"
#import "TemporaryHost.h"
#import "ConnectionEndpointStore.h"
#import "HttpManager.h"
#import "ServerInfoResponse.h"
#import "HttpRequest.h"
#import "IdManager.h"
#import "DataManager.h"
#import "LatencyProbe.h"
#import "Moonlight-Swift.h"

@interface ConnectionEditorViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) TemporaryHost *host;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTextField *autoLabel;
@property (nonatomic, strong) NSPopUpButton *defaultPopup;
@property (nonatomic, strong) NSPopUpButton *currentPopup;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSTextField *addField;
@property (nonatomic, strong) NSButton *removeButton;
@property (nonatomic, strong) NSButton *testAllButton;
@property (nonatomic, strong) NSArray<NSString *> *endpoints;
@property (nonatomic, strong) NSSet<NSString *> *manualSet;
@end

@implementation ConnectionEditorViewController

- (instancetype)initWithHost:(TemporaryHost *)host {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _host = host;
        _endpoints = @[];
    }
    return self;
}

- (void)loadView {
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 560)];
    self.view = view;

    NSStackView *rootStack = [[NSStackView alloc] init];
    rootStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    rootStack.alignment = NSLayoutAttributeLeading;
    rootStack.distribution = NSStackViewDistributionFill;
    rootStack.spacing = 16;
    rootStack.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:rootStack];

    NSTextField *title = [NSTextField labelWithString:[NSString stringWithFormat:@"连接方式 - %@", self.host.name ?: @"-"]];
    title.font = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
    [rootStack addArrangedSubview:title];

    NSStackView *summaryStack = [[NSStackView alloc] init];
    summaryStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    summaryStack.alignment = NSLayoutAttributeLeading;
    summaryStack.spacing = 6;
    [rootStack addArrangedSubview:summaryStack];

    self.statusLabel = [NSTextField labelWithString:@""];
    self.autoLabel = [NSTextField labelWithString:@""];
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    self.autoLabel.textColor = NSColor.secondaryLabelColor;
    [summaryStack addArrangedSubview:self.statusLabel];
    [summaryStack addArrangedSubview:self.autoLabel];

    NSStackView *methodStack = [[NSStackView alloc] init];
    methodStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    methodStack.alignment = NSLayoutAttributeLeading;
    methodStack.spacing = 8;
    [rootStack addArrangedSubview:methodStack];

    NSStackView *defaultRow = [[NSStackView alloc] init];
    defaultRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    defaultRow.alignment = NSLayoutAttributeCenterY;
    defaultRow.spacing = 8;
    [methodStack addArrangedSubview:defaultRow];

    NSTextField *defaultLabel = [NSTextField labelWithString:@"默认连接方式"];
    [defaultRow addArrangedSubview:defaultLabel];

    self.defaultPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.defaultPopup.target = self;
    self.defaultPopup.action = @selector(defaultMethodChanged:);
    [defaultRow addArrangedSubview:self.defaultPopup];

    NSStackView *currentRow = [[NSStackView alloc] init];
    currentRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    currentRow.alignment = NSLayoutAttributeCenterY;
    currentRow.spacing = 8;
    [methodStack addArrangedSubview:currentRow];

    NSTextField *currentLabel = [NSTextField labelWithString:@"本次连接方式"];
    [currentRow addArrangedSubview:currentLabel];

    self.currentPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.currentPopup.target = self;
    self.currentPopup.action = @selector(currentMethodChanged:);
    [currentRow addArrangedSubview:self.currentPopup];

    NSScrollView *scrollView = [[NSScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.hasVerticalScroller = YES;
    scrollView.drawsBackground = NO;
    scrollView.autohidesScrollers = YES;
    [rootStack addArrangedSubview:scrollView];

    self.tableView = [[NSTableView alloc] init];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.usesAlternatingRowBackgroundColors = YES;
    self.tableView.headerView = [[NSTableHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 0, 24)];
    self.tableView.doubleAction = @selector(handleDoubleClick:);

    NSTableColumn *addressCol = [[NSTableColumn alloc] initWithIdentifier:@"address"];
    addressCol.title = @"地址";
    addressCol.width = 320;
    [self.tableView addTableColumn:addressCol];

    NSTableColumn *sourceCol = [[NSTableColumn alloc] initWithIdentifier:@"source"];
    sourceCol.title = @"来源";
    sourceCol.width = 80;
    [self.tableView addTableColumn:sourceCol];

    NSTableColumn *statusCol = [[NSTableColumn alloc] initWithIdentifier:@"status"];
    statusCol.title = @"状态";
    statusCol.width = 140;
    [self.tableView addTableColumn:statusCol];

    scrollView.documentView = self.tableView;

    NSStackView *addStack = [[NSStackView alloc] init];
    addStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    addStack.alignment = NSLayoutAttributeCenterY;
    addStack.spacing = 8;
    addStack.translatesAutoresizingMaskIntoConstraints = NO;
    [rootStack addArrangedSubview:addStack];

    self.addField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.addField.placeholderString = @"添加地址（IP/域名/IPv6，可含端口）";
    [addStack addArrangedSubview:self.addField];

    NSButton *addButton = [NSButton buttonWithTitle:@"新增" target:self action:@selector(addEndpoint)];
    [addStack addArrangedSubview:addButton];

    self.removeButton = [NSButton buttonWithTitle:@"删除" target:self action:@selector(removeSelectedEndpoint)];
    self.removeButton.enabled = NO;
    [addStack addArrangedSubview:self.removeButton];

    NSStackView *actions = [[NSStackView alloc] init];
    actions.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    actions.alignment = NSLayoutAttributeCenterY;
    actions.spacing = 10;
    actions.translatesAutoresizingMaskIntoConstraints = NO;
    [rootStack addArrangedSubview:actions];

    NSView *actionsSpacer = [[NSView alloc] initWithFrame:NSZeroRect];
    actionsSpacer.translatesAutoresizingMaskIntoConstraints = NO;
    [actions addArrangedSubview:actionsSpacer];
    [actionsSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [actionsSpacer setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.testAllButton = [NSButton buttonWithTitle:@"测速全部" target:self action:@selector(testAllEndpoints)];
    [actions addArrangedSubview:self.testAllButton];

    NSButton *closeButton = [NSButton buttonWithTitle:@"关闭" target:self action:@selector(closeSheet)];
    [actions addArrangedSubview:closeButton];

    [NSLayoutConstraint activateConstraints:@[
        [rootStack.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:20],
        [rootStack.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-20],
        [rootStack.topAnchor constraintEqualToAnchor:view.topAnchor constant:20],
        [rootStack.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-20],

        [scrollView.leadingAnchor constraintEqualToAnchor:rootStack.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:rootStack.trailingAnchor],
        [scrollView.heightAnchor constraintGreaterThanOrEqualToConstant:280],

        [self.addField.widthAnchor constraintGreaterThanOrEqualToConstant:320]
    ]];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    [self reloadEndpointsUI];
}

- (void)reloadEndpointsUI {
    self.endpoints = [ConnectionEndpointStore allEndpointsForHost:self.host];
    NSArray *manual = [ConnectionEndpointStore manualEndpointsForHost:self.host.uuid];
    self.manualSet = [NSSet setWithArray:manual];

    [self.tableView reloadData];
    [self updateSummaryLabels];
    [self updateRemoveButtonState];
    [self reloadMethodPopups];
}

- (void)reloadMethodPopups {
    [self.defaultPopup removeAllItems];
    [self.currentPopup removeAllItems];

    [self.defaultPopup addItemWithTitle:@"不设默认（自动）"];
    self.defaultPopup.lastItem.representedObject = @"__none__";

    [self.defaultPopup addItemWithTitle:@"自动"];
    self.defaultPopup.lastItem.representedObject = @"Auto";

    [self.currentPopup addItemWithTitle:@"自动"];
    self.currentPopup.lastItem.representedObject = @"Auto";

    for (NSString *addr in self.endpoints) {
        [self.defaultPopup addItemWithTitle:addr];
        self.defaultPopup.lastItem.representedObject = addr;

        [self.currentPopup addItemWithTitle:addr];
        self.currentPopup.lastItem.representedObject = addr;
    }

    NSString *defaultMethod = [ConnectionEndpointStore defaultConnectionMethodForHost:self.host.uuid];
    if (defaultMethod.length == 0) {
        [self.defaultPopup selectItemAtIndex:0];
    } else {
        NSInteger idx = [self indexOfPopup:self.defaultPopup forValue:defaultMethod fallback:@"Auto"];
        [self.defaultPopup selectItemAtIndex:idx];
    }

    NSDictionary *prefs = [SettingsClass getSettingsFor:self.host.uuid];
    NSString *currentMethod = prefs[@"connectionMethod"] ?: @"Auto";
    NSInteger currentIdx = [self indexOfPopup:self.currentPopup forValue:currentMethod fallback:@"Auto"];
    [self.currentPopup selectItemAtIndex:currentIdx];
}

- (NSInteger)indexOfPopup:(NSPopUpButton *)popup forValue:(NSString *)value fallback:(NSString *)fallback {
    for (NSInteger i = 0; i < popup.numberOfItems; i++) {
        NSMenuItem *item = [popup itemAtIndex:i];
        NSString *rep = item.representedObject;
        if ([rep isEqualToString:value]) {
            return i;
        }
    }
    for (NSInteger i = 0; i < popup.numberOfItems; i++) {
        NSMenuItem *item = [popup itemAtIndex:i];
        NSString *rep = item.representedObject;
        if ([rep isEqualToString:fallback]) {
            return i;
        }
    }
    return 0;
}

- (NSString *)sourceLabelForAddress:(NSString *)addr manualSet:(NSSet *)manualSet {
    if ([manualSet containsObject:addr]) {
        return @"手动";
    }
    if (self.host.activeAddress && [addr isEqualToString:self.host.activeAddress]) {
        return @"当前";
    }
    if (self.host.localAddress && [addr isEqualToString:self.host.localAddress]) {
        return @"局域网";
    }
    if (self.host.externalAddress && [addr isEqualToString:self.host.externalAddress]) {
        return @"外网";
    }
    if (self.host.ipv6Address && [addr isEqualToString:self.host.ipv6Address]) {
        return @"IPv6";
    }
    if (self.host.address && [addr isEqualToString:self.host.address]) {
        return @"手动地址";
    }
    return @"";
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.endpoints.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row < 0 || row >= self.endpoints.count) {
        return nil;
    }
    NSString *addr = self.endpoints[row];
    NSString *identifier = tableColumn.identifier;

    NSTableCellView *cell = [tableView makeViewWithIdentifier:identifier owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableColumn.width, 22)];
        NSTextField *textField = [NSTextField labelWithString:@""];
        textField.translatesAutoresizingMaskIntoConstraints = NO;
        textField.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [cell addSubview:textField];
        cell.textField = textField;
        cell.identifier = identifier;
        [NSLayoutConstraint activateConstraints:@[
            [textField.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
            [textField.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
            [textField.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]
        ]];
    }

    if ([identifier isEqualToString:@"address"]) {
        cell.textField.stringValue = addr;
        cell.textField.textColor = NSColor.labelColor;
    } else if ([identifier isEqualToString:@"source"]) {
        cell.textField.stringValue = [self sourceLabelForAddress:addr manualSet:self.manualSet];
        cell.textField.textColor = NSColor.secondaryLabelColor;
    } else if ([identifier isEqualToString:@"status"]) {
        cell.textField.stringValue = [self statusTextForAddress:addr];
        cell.textField.textColor = NSColor.secondaryLabelColor;
    }

    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    [self updateRemoveButtonState];
}

- (void)updateRemoveButtonState {
    self.removeButton.enabled = self.tableView.selectedRow >= 0 && self.tableView.selectedRow < self.endpoints.count;
}

- (NSString *)statusTextForAddress:(NSString *)addr {
    NSNumber *state = self.host.addressStates[addr];
    NSNumber *latency = self.host.addressLatencies[addr];

    if (state && state.intValue == 1) {
        if (latency && latency.intValue >= 0) {
            return [NSString stringWithFormat:@"在线 (%dms)", latency.intValue];
        }
        return @"在线";
    }
    if (state && state.intValue == 0) {
        return @"离线";
    }
    return @"未知";
}

- (void)updateSummaryLabels {
    BOOL anyOnline = NO;
    for (NSString *addr in self.endpoints) {
        NSNumber *state = self.host.addressStates[addr];
        if (state && state.intValue == 1) {
            anyOnline = YES;
            break;
        }
    }

    self.statusLabel.stringValue = [NSString stringWithFormat:@"主机状态：%@", anyOnline ? @"在线" : @"离线"];
    NSString *autoAddr = self.host.activeAddress ?: @"-";
    self.autoLabel.stringValue = [NSString stringWithFormat:@"自动选择：%@", autoAddr];
}

- (void)addEndpoint {
    NSString *input = self.addField.stringValue ?: @"";
    if ([ConnectionEndpointStore addManualEndpoint:input forHost:self.host.uuid]) {
        self.addField.stringValue = @"";
        [self reloadEndpointsUI];
    }
}

- (void)removeSelectedEndpoint {
    NSInteger row = self.tableView.selectedRow;
    if (row < 0 || row >= self.endpoints.count) {
        return;
    }

    NSString *addr = self.endpoints[row];
    [ConnectionEndpointStore removeManualEndpoint:addr forHost:self.host.uuid];
    [ConnectionEndpointStore disableEndpoint:addr forHost:self.host.uuid];
    [self reloadEndpointsUI];
}

- (void)defaultMethodChanged:(NSPopUpButton *)sender {
    NSString *value = sender.selectedItem.representedObject;
    if ([value isEqualToString:@"__none__"]) {
        [ConnectionEndpointStore setDefaultConnectionMethod:nil forHost:self.host.uuid];
    } else {
        [ConnectionEndpointStore setDefaultConnectionMethod:value forHost:self.host.uuid];
    }
}

- (void)currentMethodChanged:(NSPopUpButton *)sender {
    NSString *value = sender.selectedItem.representedObject ?: @"Auto";
    [SettingsClass setConnectionMethod:value for:self.host.uuid];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ConnectionMethodUpdated"
                                                        object:nil
                                                      userInfo:@{ @"uuid": self.host.uuid ?: @"", @"method": value }];
}

- (void)handleDoubleClick:(id)sender {
    NSInteger row = self.tableView.clickedRow;
    if (row < 0 || row >= self.endpoints.count) {
        return;
    }

    NSString *oldAddr = self.endpoints[row];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"编辑连接方式";
    alert.informativeText = @"修改地址后会替换当前连接方式";

    NSTextField *inputField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
    inputField.stringValue = oldAddr;
    alert.accessoryView = inputField;
    [alert addButtonWithTitle:@"保存"];
    [alert addButtonWithTitle:@"取消"];

    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse returnCode) {
        if (returnCode != NSAlertFirstButtonReturn) {
            return;
        }

        NSString *newAddr = inputField.stringValue ?: @"";
        if (newAddr.length == 0) {
            return;
        }

        if ([newAddr isEqualToString:oldAddr]) {
            return;
        }

        [ConnectionEndpointStore disableEndpoint:oldAddr forHost:self.host.uuid];
        [ConnectionEndpointStore removeManualEndpoint:oldAddr forHost:self.host.uuid];
        [ConnectionEndpointStore addManualEndpoint:newAddr forHost:self.host.uuid];
        [self reloadEndpointsUI];
    }];
}

- (void)testAllEndpoints {
    self.testAllButton.enabled = NO;

    NSArray *addresses = [ConnectionEndpointStore allEndpointsForHost:self.host];
    if (addresses.count == 0) {
        self.testAllButton.enabled = YES;
        return;
    }

    dispatch_group_t group = dispatch_group_create();
    NSMutableDictionary *latencies = [[NSMutableDictionary alloc] init];
    NSMutableDictionary *states = [[NSMutableDictionary alloc] init];
    NSLock *lock = [[NSLock alloc] init];

    __block BOOL receivedResponse = NO;
    __block double minLatency = DBL_MAX;
    __block NSString *bestAddress = nil;

    for (NSString *address in addresses) {
        dispatch_group_enter(group);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSDate *start = [NSDate date];
            ServerInfoResponse *resp = [self requestInfoAtAddress:address cert:self.host.serverCert];
            NSTimeInterval rtt = -[start timeIntervalSinceNow] * 1000.0;
            BOOL success = [self checkResponse:resp];

            [lock lock];
            if (success) {
                receivedResponse = YES;
                NSNumber *pingMs = [LatencyProbe icmpPingMsForAddress:address];
                if (pingMs != nil) {
                    latencies[address] = pingMs;
                } else {
                    latencies[address] = @((int)rtt);
                }
                states[address] = @(1);
                double bestMetric = pingMs != nil ? pingMs.doubleValue : rtt;
                if (bestMetric < minLatency) {
                    minLatency = bestMetric;
                    bestAddress = address;
                }
            } else {
                states[address] = @(0);
            }
            [lock unlock];
            dispatch_group_leave(group);
        });
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        self.host.addressLatencies = latencies;
        self.host.addressStates = states;
        self.host.state = receivedResponse ? StateOnline : StateOffline;

        if (receivedResponse && bestAddress.length > 0) {
            self.host.activeAddress = bestAddress;
            DataManager *dataManager = [[DataManager alloc] init];
            [dataManager updateHost:self.host];
        }

        [[NSNotificationCenter defaultCenter] postNotificationName:@"HostLatencyUpdated" object:nil userInfo:@{
            @"uuid": self.host.uuid ?: @"",
            @"latencies": latencies,
            @"states": states
        }];

        self.testAllButton.enabled = YES;
        [self reloadEndpointsUI];
    });
}

- (ServerInfoResponse *)requestInfoAtAddress:(NSString *)address cert:(NSData *)cert {
    HttpManager *hMan = [[HttpManager alloc] initWithHost:address uniqueId:[IdManager getUniqueId] serverCert:cert];
    ServerInfoResponse *response = [[ServerInfoResponse alloc] init];
    [hMan executeRequestSynchronously:[HttpRequest requestForResponse:response
                                                      withUrlRequest:[hMan newServerInfoRequest:true]
                                                      fallbackError:401
                                                    fallbackRequest:[hMan newHttpServerInfoRequest]]];
    return response;
}

- (BOOL)checkResponse:(ServerInfoResponse *)response {
    if ([response isStatusOk]) {
        NSString *uuid = [response getStringTag:TAG_UNIQUE_ID];
        if (self.host.uuid == nil || [uuid isEqualToString:self.host.uuid]) {
            return YES;
        }
    }
    return NO;
}

- (void)closeSheet {
    [self dismissController:nil];
}

@end
