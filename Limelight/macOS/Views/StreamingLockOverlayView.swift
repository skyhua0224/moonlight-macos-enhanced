//
//  StreamingLockOverlayView.swift
//  Limelight
//
//  Created by SkyHua on 2025-01-20.
//

import SwiftUI

@objc public class StreamingLockOverlayViewFactory: NSObject {
    @objc public static func createOverlay(hostName: String,
                                  appName: String,
                                  onShowWindow: @escaping () -> Void,
                                  onDisconnect: @escaping () -> Void) -> NSViewController {
        let view = StreamingLockOverlayView(hostName: hostName,
                                          appName: appName,
                                          connectionState: "Connected",
                                          onShowWindow: onShowWindow,
                                          onDisconnect: onDisconnect)
        return NSHostingController(rootView: view)
    }
}

// MARK: - Offline Overlay Factory (Added to existing file to ensure compilation)
@objc public class OfflineHostOverlayViewFactory: NSObject {
    @objc public static func createOverlay(hostName: String,
                                         onWake: @escaping () -> Void,
                                         onRefresh: @escaping () -> Void,
                                         onCancel: @escaping () -> Void) -> NSViewController {
        let view = OfflineHostOverlayView(hostName: hostName,
                                        onWake: onWake,
                                        onRefresh: onRefresh,
                                        onCancel: onCancel)
        return NSHostingController(rootView: view)
    }
}

// MARK: - Streaming Overlay View
struct StreamingLockOverlayView: View {
    let hostName: String
    let appName: String
    let connectionState: String
    let onShowWindow: () -> Void
    let onDisconnect: () -> Void

    @SwiftUI.State private var languageVersion = 0

    var body: some View {
        ZStack {
            // Frosted glass background
            Rectangle()
                .fill(Material.ultraThinMaterial)
                .ignoresSafeArea()

            // Central card
            VStack(spacing: 24) {
                Image(systemName: "airplayvideo")
                    .font(.system(size: 48))
                    .foregroundColor(.blue)
                    .shadow(color: .blue.opacity(0.3), radius: 8, x: 0, y: 0)

                VStack(spacing: 8) {
                    Text(LanguageManager.shared.localize("Streaming Active"))
                        .font(.system(size: 20, weight: .regular))
                        .foregroundColor(.primary)

                    Text(String(format: LanguageManager.shared.localize("Host: %@"), hostName))
                        .font(.body)
                        .foregroundColor(.secondary)

                    Text(String(format: LanguageManager.shared.localize("App: %@"), appName))
                        .font(.body)
                        .foregroundColor(.secondary)

                    Text(LanguageManager.shared.localize(connectionState))
                        .font(.caption)
                        .foregroundColor(.green)
                        .padding(.top, 4)
                }

                VStack(spacing: 12) {
                    Button(action: onShowWindow) {
                        HStack {
                            Image(systemName: "arrow.up.forward.app")
                            Text(LanguageManager.shared.localize("Show Stream Window"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .shadow(radius: 2)

                    Button(action: onDisconnect) {
                        HStack {
                            Image(systemName: "xmark.circle")
                            Text(LanguageManager.shared.localize("Disconnect"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.large)
                    .shadow(radius: 1)
                }
            }
            .padding(32)
            .frame(width: 350)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Material.regular)
            )
            .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10) // Enhanced card shadow
            .id(languageVersion)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LanguageChanged"))) { _ in
            languageVersion += 1
        }
    }
}

// MARK: - Offline Overlay View
struct OfflineHostOverlayView: View {
    let hostName: String
    let onWake: () -> Void
    let onRefresh: () -> Void
    let onCancel: () -> Void

    @SwiftUI.State private var isWaking = false
    @SwiftUI.State private var languageVersion = 0
    @SwiftUI.State private var refreshRotation = 0.0

    init(hostName: String, onWake: @escaping () -> Void, onRefresh: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.hostName = hostName
        self.onWake = onWake
        self.onRefresh = onRefresh
        self.onCancel = onCancel
    }

    var body: some View {
        ZStack {
            // Frosted glass background
            Rectangle()
                .fill(Material.ultraThinMaterial)
                .ignoresSafeArea()

            // Central card
            VStack(spacing: 24) {
                ZStack {
                    Image(systemName: "power.circle")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                        .opacity(isWaking ? 0.5 : 1.0)
                        .animation(isWaking ? Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true) : .default, value: isWaking)
                    
                    if !isWaking {
                        // Refresh button overlay
                        Button(action: {
                            // Trigger refresh visual
                            withAnimation(.linear(duration: 1)) {
                                refreshRotation += 360
                            }
                            onRefresh()
                        }) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.blue)
                                .background(Circle().fill(Color.white).padding(2))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 24, y: 24)
                        .rotationEffect(.degrees(refreshRotation))
                        .help(LanguageManager.shared.localize("Refresh Status"))
                    }
                }

                VStack(spacing: 8) {
                    Text(String(format: LanguageManager.shared.localize("%@ is Offline"), hostName))
                        .font(.title2.weight(.semibold))
                        .foregroundColor(.primary)

                    Text(isWaking ? LanguageManager.shared.localize("Sending Wake-on-LAN packets...") : LanguageManager.shared.localize("This computer is currently offline or sleeping."))
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                VStack(spacing: 12) {
                    Button(action: {
                        isWaking = true
                        onWake()

                        // Reset waking state after a delay if still offline
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            // We don't automatically set isWaking to false here because
                            // we want to keep the "waking" UI state until the host actually comes online
                            // or the user cancels. But we can stop the pulse effect visually if desired,
                            // or just keep it pulsing to show we're waiting.
                        }
                    }) {
                        HStack {
                            if isWaking {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(.trailing, 4)
                            } else {
                                Image(systemName: "bolt.fill")
                            }
                            Text(isWaking ? LanguageManager.shared.localize("Waking...") : LanguageManager.shared.localize("Wake Host"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isWaking)
                    .shadow(radius: 2)

                    Button(action: onCancel) {
                        Text(LanguageManager.shared.localize("Back to Computers"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .shadow(radius: 1)
                }
            }
            .padding(40)
            .frame(width: 400)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Material.regular)
                    .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
            )
            .id(languageVersion)
        }
        .transition(.opacity)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LanguageChanged"))) { _ in
            languageVersion += 1
        }
    }
}
