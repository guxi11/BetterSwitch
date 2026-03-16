//
//  InputMapping.swift
//  BetterSwitch
//
//  Created by zhangyuanyuan on 2026/3/16.
//

import Foundation
import SwiftData

/// Maps a Bluetooth keyboard connection to a specific monitor input
@Model
final class InputMapping {
    var keyboard: BluetoothKeyboard?
    var monitor: Monitor?
    var inputSourceCode: UInt8
    var isEnabled: Bool
    var createdAt: Date
    
    init(keyboard: BluetoothKeyboard? = nil, monitor: Monitor? = nil, inputSourceCode: UInt8, isEnabled: Bool = true) {
        self.keyboard = keyboard
        self.monitor = monitor
        self.inputSourceCode = inputSourceCode
        self.isEnabled = isEnabled
        self.createdAt = Date()
    }
    
    /// Get the InputSource for this mapping's code
    var inputSource: InputSource? {
        InputSource.allInputs.first { $0.code == inputSourceCode }
    }
}
