//
//  ConnectionDetailsViewController.swift
//  Moonlight for macOS
//
//  Created by GitHub Copilot on 2024/06/01.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import Cocoa

@objc class ConnectionDetailsViewController: NSViewController {
    
    private let host: TemporaryHost
    
    @objc init(host: TemporaryHost) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func loadView() {
        let view = NSView()
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 500)
        self.view = view
        
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        view.addSubview(scrollView)

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        
        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.distribution = .fill
        mainStack.spacing = 24
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(mainStack)

        func addSectionView(_ section: NSView) {
            section.translatesAutoresizingMaskIntoConstraints = false
            mainStack.addArrangedSubview(section)
            NSLayoutConstraint.activate([
                section.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor),
                section.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor),
            ])
        }
        
        let closeButton = NSButton(title: LanguageManager.shared.localize("Close"), target: self, action: #selector(dismissController))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.keyEquivalent = "\r"
        closeButton.bezelStyle = .rounded
        view.addSubview(closeButton)
        
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -20),
            
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            closeButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
        ])

        // Constrain the document view to the scroll view's contentView so Auto Layout can compute
        // a stable document size and origin (avoids top/left clipping).
        let contentInset: CGFloat = 24
        NSLayoutConstraint.activate([
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.bottomAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.bottomAnchor),

            mainStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: contentInset),
            mainStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -contentInset),
            mainStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: contentInset),
            mainStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -contentInset),
        ])
        
        // --- Populate Sections ---
        
        // Basic Info
        let basicGrid = createGrid()
        addRow(label: "Host Name", value: host.name, to: basicGrid)
        
        let statusString: String
        switch host.state {
        case .online: statusString = LanguageManager.shared.localize("Online")
        case .offline: statusString = LanguageManager.shared.localize("Offline")
        default: statusString = LanguageManager.shared.localize("Unknown")
        }
        addRow(label: "Status", value: statusString, to: basicGrid)
        
        let pairStateString = host.pairState == .paired ? LanguageManager.shared.localize("Paired") : LanguageManager.shared.localize("Unpaired")
        addRow(label: "Pair State", value: pairStateString, to: basicGrid)
        
        addSectionView(createSection(title: "Basic Info", content: basicGrid))
        
        // Network
        let networkGrid = createGrid()
        addRow(label: "Active Address", value: host.activeAddress, to: networkGrid)
        addRow(label: "Local Address", value: host.localAddress, to: networkGrid)
        addRow(label: "External Address", value: host.externalAddress, to: networkGrid)
        addRow(label: "IPv6 Address", value: host.ipv6Address, to: networkGrid)
        addRow(label: "Manual Address", value: host.address, to: networkGrid)
        addRow(label: "MAC Address", value: host.mac, to: networkGrid)
        
        addSectionView(createSection(title: "Network", content: networkGrid))
        
        // System
        let systemGrid = createGrid()
        addRow(label: "UUID", value: host.uuid, to: systemGrid)
        addRow(label: "Running Game", value: host.currentGame, to: systemGrid)
        
        addSectionView(createSection(title: "System", content: systemGrid))
        
        // Latency
        if let latencies = host.addressLatencies, !latencies.isEmpty {
            let latencyGrid = createGrid()
            let states = host.addressStates ?? [:]
            
            for (addr, latency) in latencies {
                let isOnline = states[addr]?.boolValue ?? false
                let status = isOnline ? LanguageManager.shared.localize("Online") : LanguageManager.shared.localize("Offline")
                let detail = "\(status) (\(latency)ms)"
                addRow(label: addr, value: detail, to: latencyGrid)
            }
            addSectionView(createSection(title: "Latency", content: latencyGrid))
        }
    }
    
    private func createGrid() -> NSGridView {
        let grid = NSGridView(views: [])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 16
        grid.rowSpacing = 6
        grid.rowAlignment = .firstBaseline
        return grid
    }
    
    private func createSection(title: String, content: NSView) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.distribution = .fill
        container.spacing = 10
        
        let titleLabel = NSTextField(labelWithString: LanguageManager.shared.localize(title))
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .left
        
        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.contentInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        card.addSubview(content)

        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: card.contentInsets.left),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -card.contentInsets.right),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: card.contentInsets.top),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -card.contentInsets.bottom)
        ])

        container.addArrangedSubview(titleLabel)
        container.addArrangedSubview(card)
        
        // Make box fill width
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalTo: container.widthAnchor),
            titleLabel.widthAnchor.constraint(equalTo: container.widthAnchor)
        ])
        
        return container
    }
    
    private func addRow(label: String, value: String?, to gridView: NSGridView) {
        let labelStr = LanguageManager.shared.localize(label)
        let labelField = NSTextField(labelWithString: labelStr)
        labelField.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        labelField.alignment = .right
        labelField.textColor = .labelColor
        labelField.setContentHuggingPriority(.required, for: .horizontal)
        labelField.setContentCompressionResistancePriority(.required, for: .horizontal)
        
        let valueField = NSTextField(labelWithString: value ?? "-")
        valueField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        valueField.isSelectable = true
        valueField.textColor = .secondaryLabelColor
        valueField.usesSingleLineMode = false
        valueField.lineBreakMode = .byWordWrapping
        valueField.maximumNumberOfLines = 0
        valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        
        gridView.addRow(with: [labelField, valueField])
    }
    
    @objc func dismissController() {
        self.dismiss(nil)
    }
}

final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

final class CardView: NSView {
    var contentInsets: NSEdgeInsets = .init(top: 12, left: 12, bottom: 12, right: 12)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
