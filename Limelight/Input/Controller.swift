//
//  Controller.swift
//  Moonlight
//
//  Created by David Aghassi on 4/11/16.
//  Copyright © 2016 Moonlight Stream. All rights reserved.
//

import Foundation

@objcMembers
/**
 Defines a controller layout
 */
class Controller: NSObject, NSCopying {
  // Swift requires initial properties
  var playerIndex: CInt = 0           // Controller number (e.g. 1, 2 ,3 etc)
  var lastButtonFlags: CInt = 0
  var emulatingButtonFlags: CInt = 0
  var lastLeftTrigger: CChar = 0      // Last left trigger pressed
  var lastRightTrigger: CChar = 0     // Last right trigger pressed
  var lastLeftStickX: CShort = 0      // Last X direction the left joystick went
  var lastLeftStickY: CShort = 0      // Last Y direction the left joystick went
  var lastRightStickX: CShort = 0     // Last X direction the right joystick went
  var lastRightStickY: CShort = 0     // Last Y direction the right joystick went
    
    override init() {
    }
    
    init(playerIndex: CInt, lastButtonFlags: CInt, emulatingButtonFlags: CInt, lastLeftTrigger: CChar, lastRightTrigger: CChar, lastLeftStickX: CShort, lastLeftStickY: CShort, lastRightStickX: CShort, lastRightStickY: CShort) {
        self.playerIndex = playerIndex
        self.lastButtonFlags = lastButtonFlags
        self.emulatingButtonFlags = emulatingButtonFlags
        self.lastLeftTrigger = lastLeftTrigger
        self.lastRightTrigger = lastRightTrigger
        self.lastLeftStickX = lastLeftStickX
        self.lastLeftStickY = lastLeftStickY
        self.lastRightStickX = lastRightStickX
        self.lastRightStickY = lastRightStickY
    }
    
    func copy(with zone: NSZone? = nil) -> Any {
        let copy = Controller(playerIndex: playerIndex, lastButtonFlags: lastButtonFlags, emulatingButtonFlags: emulatingButtonFlags, lastLeftTrigger: lastLeftTrigger, lastRightTrigger: lastRightTrigger, lastLeftStickX: lastLeftStickX, lastLeftStickY: lastLeftStickY, lastRightStickX: lastRightStickX, lastRightStickY: lastRightStickY)
        return copy
    }
    
    override func isEqual(_ object: Any?) -> Bool {
        guard let rhs = object as? Controller else { return false }
        
        return playerIndex == rhs.playerIndex
            && lastButtonFlags == rhs.lastButtonFlags
            && emulatingButtonFlags == rhs.emulatingButtonFlags
            && abs(Int(lastLeftTrigger) - Int(rhs.lastLeftTrigger)) <= 2
            && abs(Int(lastRightTrigger) - Int(rhs.lastRightTrigger)) <= 2
            && abs(Int(lastLeftStickX) - Int(rhs.lastLeftStickX)) <= 512
            && abs(Int(lastLeftStickY) - Int(rhs.lastLeftStickY)) <= 512
            && abs(Int(lastRightStickX) - Int(rhs.lastRightStickX)) <= 512
            && abs(Int(lastRightStickY) - Int(rhs.lastRightStickY)) <= 512
    }
}
