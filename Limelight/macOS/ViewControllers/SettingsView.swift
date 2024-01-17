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
    @StateObject var settingsModel = SettingsModel()

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
                        .environmentObject(settingsModel)
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
        .frame(minWidth: 500)
        .onAppear {
            NSWindow.allowsAutomaticWindowTabbing = false
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

@available(macOS 12.0, *)
struct StreamView: View {
    @EnvironmentObject private var settingsModel: SettingsModel
    
    @SwiftUI.State private var showCustomResolutionGroup = false
    
    var body: some View {
        VStack {
            FormSection(title: "Resolution and FPS") {
                FormCell(title: "Resolution", contentWidth: 100, content: {
                    Picker("", selection: $settingsModel.selectedResolution) {
                        ForEach(SettingsModel.resolutions, id: \.self) { resolution in
                            if resolution == .zero {
                                Text("Custom")
                            } else {
                                Text(verbatim: resolution.height == 2160 ? "4K" : "\(Int(resolution.height))p")
                            }
                        }
                    }
                })
                
                if showCustomResolutionGroup {
                    Divider()
                
                    FormCell(title: "Custom Width", contentWidth: 60, content: {
                        TextField("", value: $settingsModel.customResWidth, format: .number)
                            .multilineTextAlignment(.trailing)
                    })
                    FormCell(title: "Custom Height", contentWidth: 60, content: {
                        TextField("", value: $settingsModel.customResHeight, format: .number)
                            .multilineTextAlignment(.trailing)
                    })
                }
                
                Divider()
                
                FormCell(title: "FPS", contentWidth: 100, content: {
                    Picker("", selection: $settingsModel.selectedFps) {
                        ForEach(SettingsModel.fpss, id: \.self) { fps in
                            Text("\(fps)")
                        }
                    }
                })
            }
            
            Spacer()
                .frame(height: 32)
            
            if #available(macOS 12.0, *) {
                FormSection(title: "Bitrate") {
                    VStack(alignment: .leading) {
                        let bitrate = SettingsModel.bitrateSteps[Int(settingsModel.bitrateSliderValue)].formatted(FloatingPointFormatStyle())
                        Text("\(bitrate) Mbps")
                            .monospacedDigit()
                        Slider(value: $settingsModel.bitrateSliderValue, in: 0...Float(SettingsModel.bitrateSteps.count - 1), step: 1)
                    }
                }
            }
            
            Spacer()
        }
        .padding()
        .onAppear {
            func updateCustomResolutionGroup() {
                showCustomResolutionGroup = settingsModel.selectedResolution == .zero
            }
            
            updateCustomResolutionGroup()
            settingsModel.resolutionChangedCallback = {
                withAnimation {
                    updateCustomResolutionGroup()
//                    UserDefaults.standard.set(settingsModel.selectedResolution == .zero, forKey: "useCustomRes")
                }
            }
        }
    }
}

struct TestView: View {
    var body: some View {
        Text("Test")
    }
}

struct FormSection<Content: View>: View {
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        GroupBox(content: {
            VStack {
                Group {
                    content
                }
                .padding([.top], 1)
            }
            .padding([.top, .bottom], 6)
            .padding([.leading, .trailing], 6)
        }, label: {
            Text(title)
                .font(
                    .system(.body, design: .rounded)
                    .weight(.semibold)
                )
                .padding(.bottom, 6)
        })
    }
}

struct FormCell<Content: View>: View {
    let title: String
    let contentWidth: CGFloat
    let content: Content
    
    init(title: String, contentWidth: CGFloat, @ViewBuilder content: () -> Content) {
        self.title = title
        self.contentWidth = contentWidth
        self.content = content()
    }
    
    var body: some View {
        HStack {
            Text(title)
            
            Spacer()

            content
            .frame(width: contentWidth)
        }
    }
}

extension CGSize: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(width)
    hasher.combine(height)
  }
}

#Preview {
    if #available(macOS 13.0, *) {
        return SettingsView()
    } else {
        return Text("Not supported")
    }
}
