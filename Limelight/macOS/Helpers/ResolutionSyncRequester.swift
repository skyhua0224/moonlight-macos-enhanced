//
//  ResolutionSyncRequester.swift
//  Moonlight for macOS
//
//  Created by Michael Kenny on 9/10/19.
//  Copyright © 2019 Moonlight Game Streaming Project. All rights reserved.
//

import Foundation

class ResolutionSyncRequester: NSObject {
    
    static let port = 8080
    
    @objc static public func setResolution(for host: String) {
        let disableMouseAcceleration = UserDefaults.standard.bool(forKey: "disablePointerPrecison")
        if disableMouseAcceleration {
            Self.disableMouseAcceleration(for: host)
        }

        let enabled = UserDefaults.standard.bool(forKey: "shouldSync")
        if !enabled {
            Self.setRefreshRate(for: host)
            return
        }
        
        let width = UserDefaults.standard.integer(forKey: "syncWidth")
        let height = UserDefaults.standard.integer(forKey: "syncHeight")

        if let url = URL(string: "http://\(host):\(port)/resolutionsync/set?\(width)&\(height)&\(60)") {
            ResolutionSyncRequester.makeRequest(url)
            print("ResolutionSync URL: \(url.absoluteString)")
        }
    }

    @objc static public func resetResolution(for host: String) {
        ResolutionSyncRequester.makeRequest(URL(string: "http://\(host):\(port)/resolutionsync/reset")!)
    }

    @objc static public func setRefreshRate(for host: String) {
        ResolutionSyncRequester.makeRequest(URL(string: "http://\(host):\(port)/resolutionsync/setRefreshRate?\(60)")!)
    }

    @objc static public func disableMouseAcceleration(for host: String) {
        ResolutionSyncRequester.makeRequest(URL(string: "http://\(host):\(port)/resolutionsync/disableMouseAcceleration")!)
    }
    
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
