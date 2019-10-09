//
//  ResolutionSyncRequester.swift
//  Moonlight for macOS
//
//  Created by Michael Kenny on 9/10/19.
//  Copyright © 2019 Moonlight Game Streaming Project. All rights reserved.
//

import Cocoa

class ResolutionSyncRequester: NSObject {
    @objc static public func setResolution() {
        
        let enabled = UserDefaults.standard.bool(forKey: "shouldSync")
        if !enabled {
            return
        }
        
        guard let host = UserDefaults.standard.string(forKey: "syncHostName") else { return }
        let width = UserDefaults.standard.integer(forKey: "syncWidth")
        let height = UserDefaults.standard.integer(forKey: "syncHeight")
        
        if let url = URL(string: "http://\(host):8080/resolutionsync/set?\(width)&\(height)") {
            ResolutionSyncRequester.makeRequest(url)
            print("ResolutionSync URL: \(url.absoluteString)")
        }
    }
    
    @objc static public func resetResolution() {

        let enabled = UserDefaults.standard.bool(forKey: "shouldSync")
        if !enabled {
            return
        }
        
        ResolutionSyncRequester.makeRequest(URL(string: "http://gaming-i7:8080/resolutionsync/reset")!)
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
