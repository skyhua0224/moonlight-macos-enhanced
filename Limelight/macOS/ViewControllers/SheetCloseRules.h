#pragma once

// How an AppKit sheet that SwiftUI also tracks (the 连接方式 editor in Settings) is closed. Plain C so that tests/key-routing
// builds it without AppKit.
//
// #81: the 关闭 button ended the AppKit sheet but SwiftUI kept `isAddressEditorPresented` true, so the dialog could not be
// opened again and looked stuck. Whatever route closes the sheet, the owner of the SwiftUI state is told exactly once.

#include <stdbool.h>

typedef enum MLSheetCloseRoute {
    MLSheetCloseViaPresenter = 0,  // AppKit view-controller presentation: [presenter dismissViewController:]
    MLSheetCloseViaSheetParent,    // SwiftUI sheet host: [sheetParent endSheet:returnCode:]
    MLSheetCloseNoWindowRoute,     // the sheet is not on screen any more: nothing to end
} MLSheetCloseRoute;

typedef struct MLSheetClosePlan {
    MLSheetCloseRoute route;
    bool notifyCloseHandler;
} MLSheetClosePlan;

static inline MLSheetClosePlan MLSheetClose(bool hasPresenter, bool hasSheetParent, bool hasCloseHandler) {
    MLSheetClosePlan plan;
    plan.route = hasPresenter ? MLSheetCloseViaPresenter
               : hasSheetParent ? MLSheetCloseViaSheetParent
               : MLSheetCloseNoWindowRoute;
    plan.notifyCloseHandler = hasCloseHandler;
    return plan;
}
