//
//  ResolutionSyncRequester.swift
//  Moonlight for macOS
//
//  Created by Michael Kenny on 9/10/19.
//  Copyright © 2019 Moonlight Game Streaming Project. All rights reserved.
//

#if USE_RESOLUTION_SYNC
import Foundation

class ResolutionSyncRequester: NSObject {
    
    // MARK: - Resolution
    
    static private var disableResolutionSync: Bool {
        !UserDefaults.standard.bool(forKey: "enableResolutionSync")
    }

    static let port = 48020
    
    @objc static public func setResolution(for host: String, refreshRate: Int, isResume: Bool) {
        if disableResolutionSync {
            return
        }
        
        let pointerSpeed = UserDefaults.standard.integer(forKey: "pointerSpeed")
        let scrollLines = UserDefaults.standard.integer(forKey: "scrollWheelLines")

        var url = "http://\(host):\(port)/set?fps=\(refreshRate)&is_resume=\(isResume ? 1 : 0)&mouse_speed=\(pointerSpeed)&scroll_lines=\(scrollLines)"

        if UserDefaults.standard.bool(forKey: "shouldSync") {
            let width = UserDefaults.standard.integer(forKey: "syncWidth")
            let height = UserDefaults.standard.integer(forKey: "syncHeight")
            url += "&width=\(width)&height=\(height)"
        }

        if UserDefaults.standard.bool(forKey: "disablePointerPrecision") {
            url += "&mouse_acceleration=0"
        }
        
        if let url = URL(string: url) {
            Self.makeRequest(url)
        }
    }

    @objc static public func resetResolution(for host: String) {
        if disableResolutionSync {
            return
        }
        
        Self.makeRequest(URL(string: "http://\(host):\(port)/reset")!)
    }

    
    // MARK: - Controller
    
    @objc static public func setupController(for host: String) {
        if disableResolutionSync || UserDefaults.standard.integer(forKey: "controllerMethod") == 0 {
            return
        }
        
        Self.makeRequest(URL(string: "http://\(host):\(port)/setup_controller")!)
    }

    @objc static public func teardownController(for host: String) {
        if disableResolutionSync || UserDefaults.standard.integer(forKey: "controllerMethod") == 0 {
            return
        }
        
        Self.makeRequest(URL(string: "http://\(host):\(port)/teardown_controller")!)
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
#endif
