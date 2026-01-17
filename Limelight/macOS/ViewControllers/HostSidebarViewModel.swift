//
//  HostSidebarViewModel.swift
//  Limelight
//
//  Created by SkyHua on 2025-01-20.
//

import Foundation
import Combine

enum HostState: Int {
    case unknown = 0
    case offline = 1
    case online = 2
}

enum HostPairState: Int {
    case unknown = 0
    case unpaired = 1
    case paired = 2
}

struct HostDisplayModel: Identifiable {
    let uuid: String
    let name: String
    let state: HostState
    let pairState: HostPairState
    var isStreaming: Bool

    var id: String { uuid }

    init(from tempHost: TemporaryHost) {
        self.uuid = tempHost.uuid
        self.name = tempHost.name
        self.state = HostState(rawValue: Int(tempHost.state.rawValue)) ?? .unknown
        self.pairState = HostPairState(rawValue: Int(tempHost.pairState.rawValue)) ?? .unknown
        self.isStreaming = false
    }
}

class HostSidebarViewModel: ObservableObject {
    @Published var hosts: [HostDisplayModel] = []
    @Published var streamingHostUUID: String? = nil

    private var dataManager: DataManager
    private var discoveryObserver: NSObjectProtocol?
    private var latencyObserver: NSObjectProtocol?
    private var streamingObserver: NSObjectProtocol?
    private let initialHost: TemporaryHost?
    private let initialHosts: [TemporaryHost]

    init(initialHost: TemporaryHost? = nil, initialHosts: [TemporaryHost] = []) {
        self.dataManager = DataManager()
        self.initialHost = initialHost
        self.initialHosts = initialHosts
        loadHosts()
        setupObservers()
    }

    deinit {
        if let observer = discoveryObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = latencyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = streamingObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func loadHosts() {
        dataManager.removeHostsWithEmptyUuid()
        if let tempHosts = dataManager.getHosts() as? [TemporaryHost] {
            let dedupedHosts = self.deduplicateHosts(tempHosts)
                .filter { !$0.uuid.isEmpty }
            // Sort hosts: Online first, then by name
            let sortedHosts = dedupedHosts.sorted { (h1, h2) -> Bool in
                if h1.state == h2.state {
                    return h1.name < h2.name
                }
                return h1.state == .online
            }

            self.hosts = sortedHosts.map { host in
                let resolvedHost = self.resolveHostStateIfNeeded(host)
                var model = HostDisplayModel(from: resolvedHost)
                // Check if this host is the one currently streaming
                if let streamingUUID = self.streamingHostUUID, streamingUUID == host.uuid {
                    model.isStreaming = true
                }
                return model
            }
        }
    }

    private func resolveHostStateIfNeeded(_ host: TemporaryHost) -> TemporaryHost {
        // Prefer exact UUID match in the initial snapshot
        if let match = self.findMatchingHost(in: initialHosts, for: host) {
            if host.state == .unknown && match.state != .unknown {
                return match
            }
            return host
        }

        // Fallback to single initialHost
        if let initialHost = initialHost, initialHost.uuid == host.uuid {
            if host.state == .unknown && initialHost.state != .unknown {
                return initialHost
            }
        }

        return host
    }

    private func deduplicateHosts(_ hosts: [TemporaryHost]) -> [TemporaryHost] {
        var seen: [String: TemporaryHost] = [:]
        for host in hosts {
            let key = self.hostIdentityKey(host)
            if seen[key] == nil {
                seen[key] = host
            } else if let existing = seen[key] {
                // Prefer the host with a known state or UUID
                if existing.state == .unknown && host.state != .unknown {
                    seen[key] = host
                } else if existing.uuid.isEmpty && !host.uuid.isEmpty {
                    seen[key] = host
                }
            }
        }
        return Array(seen.values)
    }

    private func hostIdentityKey(_ host: TemporaryHost) -> String {
        if !host.uuid.isEmpty {
            return "uuid:\(host.uuid)"
        }
        if let mac = host.mac, !mac.isEmpty {
            return "mac:\(mac)"
        }
        if let address = host.address, !address.isEmpty {
            return "addr:\(address)"
        }
        return "name:\(host.name)"
    }

    private func findMatchingHost(in hosts: [TemporaryHost], for host: TemporaryHost) -> TemporaryHost? {
        let key = hostIdentityKey(host)
        return hosts.first { self.hostIdentityKey($0) == key }
    }

    private func setupObservers() {
        // Listen for host discovery updates
        // Assuming "HostDiscoveryUpdated" is the notification name used by DiscoveryManager
        // You might need to verify the actual notification name in the codebase
        discoveryObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("HostDiscoveryUpdated"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadHosts()
        }

        // Listen for host latency/status updates
        latencyObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("HostLatencyUpdated"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadHosts()
        }

        // Listen for streaming state changes from StreamingSessionManager
        streamingObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("StreamingStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let uuid = notification.userInfo?["hostUUID"] as? String {
                self?.streamingHostUUID = uuid
            } else {
                // If streaming stopped or state is idle, streamingHostUUID might be nil
                let state = notification.userInfo?["state"] as? Int ?? 0
                if state == 0 { // Idle
                    self?.streamingHostUUID = nil
                }
            }
            self?.loadHosts() // Reload to update isStreaming flags
        }
    }

    private func updateHostStreamingState(_ uuid: String) {
        // In this implementation, we simply reload all hosts to keep it simple
        // optimizing this to update only one item is possible if needed
        loadHosts()
    }
}
