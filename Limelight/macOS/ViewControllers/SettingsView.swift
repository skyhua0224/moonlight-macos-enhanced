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

struct SettingsView: View {
    @StateObject var settingsModel = SettingsModel()
    
    @SwiftUI.State private var selectedPane: PaneCell? = panes.first
    
    var body: some View {
        NavigationView {
            Sidebar(selectedPane: $selectedPane)
            Detail(pane: selectedPane)
                .environmentObject(settingsModel)
        }
        .frame(minWidth: 575, minHeight: 275)
    }
}

struct Sidebar: View {
    @Binding var selectedPane: PaneCell?
    
    var body: some View {
        List(selection: $selectedPane) {
            ForEach(panes, id: \.self) { pane in
                PaneCellView(paneCell: pane)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 160)
    }
}

struct Detail: View {
    var pane: PaneCell? = nil
    
    @EnvironmentObject private var settingsModel: SettingsModel
    
    var body: some View {
        if let pane {
            Group {
                if pane.title == "Stream" {
                    SettingPaneLoader(settingsModel) {
                        StreamView()
                    }
                } else if pane.title == "Video and Audio" {
                    SettingPaneLoader(settingsModel) {
                        VideoAndAudioView()
                    }
                } else if pane.title == "Input" {
                    SettingPaneLoader(settingsModel) {
                        InputView()
                    }
                } else if pane.title == "App" {
                    SettingPaneLoader(settingsModel) {
                        AppView()
                    }
                }
            }
            .environmentObject(settingsModel)
            .navigationSubtitle(pane.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if let hosts = SettingsModel.hosts {
                        HStack {
                            Text("Profile:")
                            
                            Picker("", selection: $settingsModel.selectedHost) {
                                ForEach(hosts, id: \.self) { host in
                                    if let host {
                                        Text(host.name)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct SettingPaneLoader<Content: View>: View {
    let settingsModel: SettingsModel
    let content: Content

    init(_ settingsModel: SettingsModel, @ViewBuilder content: () -> Content) {
        self.settingsModel = settingsModel
        self.content = content()
    }

    var body: some View {
        content
            .onAppear {
                settingsModel.loadSettings()
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
                .adaptiveForegroundColor(.white)
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
    @EnvironmentObject private var settingsModel: SettingsModel
    
    @SwiftUI.State private var showCustomResolutionGroup = false
    @SwiftUI.State private var showCustomFpsGroup = false
    
    var body: some View {
        ScrollView {
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
                        
                        FormCell(title: "Custom Resolution", contentWidth: 0, content: {
                            DimensionsInputView(widthBinding: $settingsModel.customResWidth, heightBinding: $settingsModel.customResHeight, placeholderDimensions: CGSize(width: 3440, height: 1440))
                        })
                    }
                    
                    Divider()
                    
                    FormCell(title: "FPS", contentWidth: 100, content: {
                        Picker("", selection: $settingsModel.selectedFps) {
                            ForEach(SettingsModel.fpss, id: \.self) { fps in
                                if fps == .zero {
                                    Text("Custom")
                                } else {
                                    Text("\(fps)")
                                }
                            }
                        }
                    })
                    
                    if showCustomFpsGroup {
                        Divider()
                        
                        FormCell(title: "Custom FPS", contentWidth: 0, content: {
                            TextField("40", value: $settingsModel.customFps, formatter: NumberOnlyFormatter())
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.plain)
                                .fixedSize()
                        })
                    }
                }
                
                Spacer()
                    .frame(height: 32)
                
                FormSection(title: "Bitrate") {
                    VStack(alignment: .leading) {
                        let bitrate = Int(SettingsModel.bitrateSteps[Int(settingsModel.bitrateSliderValue)])
                        Text("\(bitrate) Mbps")
                            .availableMonospacedDigit()
                        Slider(value: $settingsModel.bitrateSliderValue, in: 0...Float(SettingsModel.bitrateSteps.count - 1), step: 1)
                    }
                }
                
                Spacer()
            }
            .padding()
            .onAppear {
                func updateCustomResolutionGroup() {
                    showCustomResolutionGroup = settingsModel.selectedResolution == .zero
                }
                func updateCustomFpsGroup() {
                    showCustomFpsGroup = settingsModel.selectedFps == .zero
                }
                
                updateCustomResolutionGroup()
                updateCustomFpsGroup()
                settingsModel.resolutionChangedCallback = {
                    withAnimation {
                        updateCustomResolutionGroup()
                    }
                }
                settingsModel.fpsChangedCallback = {
                    withAnimation {
                        updateCustomFpsGroup()
                    }
                }
            }
        }
    }
}

struct VideoAndAudioView: View {
    @EnvironmentObject private var settingsModel: SettingsModel
    
    var body: some View {
        ScrollView {
            VStack {
                FormSection(title: "Video") {
                    FormCell(title: "Video Codec", contentWidth: 155, content: {
                        Picker("", selection: $settingsModel.selectedVideoCodec) {
                            ForEach(SettingsModel.videoCodecs, id: \.self) { codec in
                                Text(codec)
                            }
                        }
                    })
                    
                    Divider()
                    
                    ToggleCell(title: "HDR", boolBinding: $settingsModel.hdr)
                    
                    Divider()
                    
                    FormCell(title: "Frame Pacing", contentWidth: 155, content: {
                        Picker("", selection: $settingsModel.selectedPacingOptions) {
                            ForEach(SettingsModel.pacingOptions, id: \.self) { pacingOption in
                                Text(pacingOption)
                            }
                        }
                    })
                }
                
                Spacer()
                    .frame(height: 32)
                
                FormSection(title: "Audio") {
                    ToggleCell(title: "Play Sound on Host", boolBinding: $settingsModel.audioOnPC)
                }
                
                Spacer()
            }
            .padding()
        }
    }
}

struct InputView: View {
    @EnvironmentObject private var settingsModel: SettingsModel
    
    var body: some View {
        ScrollView {
            VStack {
                FormSection(title: "Controller") {
                    FormCell(title: "Multi-Controller Mode", contentWidth: 88, content: {
                        Picker("", selection: $settingsModel.selectedMultiControllerMode) {
                            ForEach(SettingsModel.multiControllerModes, id: \.self) { mode in
                                Text(mode)
                            }
                        }
                    })
                    
                    Divider()
                    
                    ToggleCell(title: "Rumble Controller", boolBinding: $settingsModel.rumble)
                }
                
                Spacer()
                    .frame(height: 32)
                
                FormSection(title: "Buttons") {
                    ToggleCell(title: "Swap A/B and X/Y Buttons", boolBinding: $settingsModel.swapButtons)
                    
                    Divider()
                    
                    ToggleCell(title: "Emulate Guide Button", boolBinding: $settingsModel.emulateGuide)
                }
                
                Spacer()
                    .frame(height: 32)
                
                FormSection(title: "Drivers") {
                    FormCell(title: "Controller Driver", contentWidth: 88, content: {
                        Picker("", selection: $settingsModel.selectedControllerDriver) {
                            ForEach(SettingsModel.controllerDrivers, id: \.self) { mode in
                                Text(mode)
                            }
                        }
                    })
                    
                    Divider()
                    
                    FormCell(title: "Mouse Driver", contentWidth: 88, content: {
                        Picker("", selection: $settingsModel.selectedMouseDriver) {
                            ForEach(SettingsModel.mouseDrivers, id: \.self) { mode in
                                Text(mode)
                            }
                        }
                    })
                }
                
                Spacer()
            }
            .padding()
        }
    }
}

struct AppView: View {
    @EnvironmentObject private var settingsModel: SettingsModel
    
    var body: some View {
        ScrollView {
            VStack {
                FormSection(title: "Behaviour") {
                    ToggleCell(title: "Automatically Fullscreen Stream Window", boolBinding: $settingsModel.autoFullscreen)
                }
                
                Spacer()
                    .frame(height: 32)
                
                FormSection(title: "Visuals") {
                    ToggleCell(title: "Dim Non-Hovered Apps", boolBinding: $settingsModel.dimNonHoveredArtwork)
                    
                    Divider()

                    FormCell(title: "Custom Artwork Dimensions", contentWidth: 0, content: {
                        DimensionsInputView(widthBinding: $settingsModel.appArtworkWidth, heightBinding: $settingsModel.appArtworkHeight, placeholderDimensions: CGSize(width: 300, height: 400))
                    })
                }
            }
            
            Spacer()
        }
        .padding()
    }
}

struct ToggleCell: View {
    let title: String
    @Binding var boolBinding: Bool

    var body: some View {
        FormCell(title: title, contentWidth: 0, content: {
            Toggle("", isOn: $boolBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
        })
    }
}

struct DimensionsInputView: View {
    @Binding var widthBinding: CGFloat?
    @Binding var heightBinding: CGFloat?
    let placeholderDimensions: CGSize
    
    var body: some View {
        HStack(spacing: 4) {
            TextField(formatDimension(placeholderDimensions.width), value: $widthBinding, formatter: NumberOnlyFormatter())
                .multilineTextAlignment(.trailing)
            
            Text("×")
            
            TextField(formatDimension(placeholderDimensions.height), value: $heightBinding, formatter: NumberOnlyFormatter())
                .multilineTextAlignment(.leading)
        }
        .textFieldStyle(.plain)
        .fixedSize()
    }
    
    func formatDimension(_ dimension: CGFloat) -> String {
        return "\(Int(dimension))"
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
                .if(contentWidth != 0, transform: { view in
                    view
                        .frame(width: contentWidth)
                })
        }
    }
}

extension CGSize: @retroactive Hashable {
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
