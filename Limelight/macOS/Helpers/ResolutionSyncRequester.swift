//
//  ResolutionSyncRequester.swift
//  Moonlight for macOS
//
//  Created by Michael Kenny on 9/10/19.
//  Copyright © 2019 Moonlight Game Streaming Project. All rights reserved.
//

import Foundation

class ResolutionSyncRequester: NSObject {
    
    @objc static public func setResolution() {
        guard let host = UserDefaults.standard.string(forKey: "syncHostName") else { return }
        
        let disableMouseAcceleration = UserDefaults.standard.bool(forKey: "disablePointerPrecison")
        if disableMouseAcceleration {
            Self.disableMouseAcceleration()
        }

        let enabled = UserDefaults.standard.bool(forKey: "shouldSync")
        if !enabled {
            Self.setRefreshRate()
            return
        }
        
        let width = UserDefaults.standard.integer(forKey: "syncWidth")
        let height = UserDefaults.standard.integer(forKey: "syncHeight")

        if let url = URL(string: "http://\(host):8080/resolutionsync/set?\(width)&\(height)&\(60)") {
            ResolutionSyncRequester.makeRequest(url)
            print("ResolutionSync URL: \(url.absoluteString)")
        }
    }

    @objc static public func setRefreshRate() {
        guard let host = UserDefaults.standard.string(forKey: "syncHostName") else { return }
        ResolutionSyncRequester.makeRequest(URL(string: "http://\(host):8080/resolutionsync/setRefreshRate?\(60)")!)
    }

    @objc static public func resetResolution() {
        guard let host = UserDefaults.standard.string(forKey: "syncHostName") else { return }
        ResolutionSyncRequester.makeRequest(URL(string: "http://\(host):8080/resolutionsync/reset")!)
    }

    @objc static public func disableMouseAcceleration() {
        guard let host = UserDefaults.standard.string(forKey: "syncHostName") else { return }
        ResolutionSyncRequester.makeRequest(URL(string: "http://\(host):8080/resolutionsync/disableMouseAcceleration")!)
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
