//
//  SettingsView.swift
//  Moonlight for macOS
//
//  Created by Michael Kenny on 15/1/2024.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI

struct PaneCell: Hashable {
    let title: String
    let symbol: String
    let color: Color
}

let panes: [PaneCell] = [
    PaneCell(title: "Stream", symbol: "airplayvideo", color: .blue),
    PaneCell(title: "Video and Audio", symbol: "video.fill", color: .orange),
    PaneCell(title: "Input", symbol: "keyboard.fill", color: .purple),
    PaneCell(title: "App", symbol: "appclip", color: .pink)
]

@available(macOS 13.0, *)
struct SettingsView: View {
    @SwiftUI.State private var selectedPane = panes.first!
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedPane) {
                ForEach(panes, id: \.self) { pane in
                    PaneCellView(paneCell: pane)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(160)
        } detail: {
            VStack {
                if selectedPane.title == "Stream" {
                    StreamView()
                }
            }
            .navigationSubtitle(selectedPane.title)
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

struct PaneCellView: View {
    let paneCell: PaneCell
    
    var body: some View {
        let iconSize = CGFloat(14)
        let containerSize = iconSize + (iconSize / 3)

        HStack(spacing: 6) {
            Image(systemName: paneCell.symbol)
                .font(.callout)
                .frame(width: containerSize, height: containerSize)
                .padding(1)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .foregroundColor(paneCell.color)
                )

            Text(paneCell.title)
        }
    }
}

struct StreamView: View {
    var body: some View {
        Text("Stream")
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
