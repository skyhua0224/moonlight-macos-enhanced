//
//  ResolutionSyncRequester.swift
//  Moonlight for macOS
//
//  Created by Michael Kenny on 9/10/19.
//  Copyright © 2019 Moonlight Game Streaming Project. All rights reserved.
//

import Foundation

class ResolutionSyncRequester: NSObject {
    
    // MARK: - Resolution
    
    static let port = 8080
    
    @objc static public func setResolution(for host: String, refreshRate: Int) {
        setupController(for: host)
        
        let disableMouseAcceleration = UserDefaults.standard.bool(forKey: "disablePointerPrecision")
        if disableMouseAcceleration {
            Self.disableMouseAcceleration(for: host)
        }
        
        Self.setMouseSpeed(for: host, speed: UserDefaults.standard.integer(forKey: "pointerSpeed"))
        Self.setScrollLines(for: host, lines: UserDefaults.standard.integer(forKey: "scrollWheelLines"))

        let enabled = UserDefaults.standard.bool(forKey: "shouldSync")
        if !enabled {
            Self.setRefreshRate(for: host, refreshRate: refreshRate)
            return
        }
        
        let width = UserDefaults.standard.integer(forKey: "syncWidth")
        let height = UserDefaults.standard.integer(forKey: "syncHeight")

        if let url = URL(string: "http://\(host):\(port)/resolutionsync/set?\(width)&\(height)&\(refreshRate)") {
            ResolutionSyncRequester.makeRequest(url)
            print("ResolutionSync URL: \(url.absoluteString)")
        }
    }

    @objc static public func resetResolution(for host: String) {
        teardownController(for: host)

        ResolutionSyncRequester.makeRequest(URL(string: "http://\(host):\(port)/resolutionsync/reset")!)
    }

    static private func setRefreshRate(for host: String, refreshRate: Int) {
        ResolutionSyncRequester.makeRequest(URL(string: "http://\(host):\(port)/resolutionsync/setRefreshRate?\(refreshRate)")!)
    }

    
    // MARK: - Mouse
    
    static private func disableMouseAcceleration(for host: String) {
        ResolutionSyncRequester.makeRequest(URL(string: "http://\(host):\(port)/resolutionsync/disableMouseAcceleration")!)
    }

    static private func setMouseSpeed(for host: String, speed: Int) {
        ResolutionSyncRequester.makeRequest(URL(string: "http://\(host):\(port)/resolutionsync/setMouseSpeed?\(speed)")!)
    }

    static private func setScrollLines(for host: String, lines: Int) {
        ResolutionSyncRequester.makeRequest(URL(string: "http://\(host):\(port)/resolutionsync/setScrollLines?\(lines)")!)
    }

    
    // MARK: - Controller
    
    static private func setupController(for host: String) {
        ResolutionSyncRequester.makeRequest(URL(string: "http://\(host):\(port)/resolutionsync/setupController")!)
    }

    static private func teardownController(for host: String) {
        ResolutionSyncRequester.makeRequest(URL(string: "http://\(host):\(port)/resolutionsync/teardownController")!)
    }

    
    // MARK: - Helpers
    
    private static func makeRequest(_ url: URL) {

        let task = URLSession.shared.dataTask(with: url) {(data, response, error) in
            if let returnedData = data {
                print(NSString(data: returnedData, encoding: String.Encoding.utf8.rawValue)!)
            }
            DispatchQueue.main.async(execute: {
                if let actualError = error {
                    print("Failed: \(actualError.localizedDescription)")
                }
            });
        }
        
        task.resume()
    }
    
}
