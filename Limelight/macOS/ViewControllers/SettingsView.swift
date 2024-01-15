//
//  SettingsView.swift
//  Moonlight for macOS
//
//  Created by Michael Kenny on 15/1/2024.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI

@available(macOS 13.0, *)
struct SettingsView: View {
    @State private var selectedPane = "General"
    let panes = [
        "General",
        "Test"
    ]
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedPane) {
                ForEach(panes, id: \.self) { pane in
                    Text(pane)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(150)
        } detail: {
            VStack {
                if selectedPane == "General" {
                    GeneralView()
                } else if selectedPane == "Test" {
                    TestView()
                }
            }
            .navigationSubtitle(selectedPane)
            .toolbarRole(.editor)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                }
            }
        }
    }
}

struct GeneralView: View {
    var body: some View {
        Text("General")
    }
}

struct TestView: View {
    var body: some View {
        Text("Test")
    }
}

#Preview {
    if #available(macOS 13.0, *) {
        return SettingsView()
    } else {
        return Text("Not supported")
    }
}
