//
//  BluetoothKeyboard.swift
//  BetterSwitch
//
//  Created by zhangyuanyuan on 2026/3/16.
//

import Foundation
import SwiftData

@Model
final class BluetoothKeyboard {
    @Attribute(.unique) var identifier: String
    var name: String
    var isTracked: Bool
    var lastSeen: Date?
    
    @Relationship(deleteRule: .cascade, inverse: \InputMapping.keyboard)
    var mappings: [InputMapping]?
    
    init(identifier: String, name: String, isTracked: Bool = true, lastSeen: Date? = nil) {
        self.identifier = identifier
        self.name = name
        self.isTracked = isTracked
        self.lastSeen = lastSeen
    }
}
