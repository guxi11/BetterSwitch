//
//  Monitor.swift
//  BetterSwitch
//
//  Created by zhangyuanyuan on 2026/3/16.
//

import Foundation
import SwiftData

/// Represents a physical monitor/display
@Model
final class Monitor {
    @Attribute(.unique) var displayID: UInt32
    var name: String
    var vendorID: UInt32?
    var productID: UInt32?
    var serialNumber: String?
    var supportsDDC: Bool
    var availableInputs: [InputSource]
    
    @Relationship(deleteRule: .cascade, inverse: \InputMapping.monitor)
    var mappings: [InputMapping]?
    
    init(displayID: UInt32, name: String, vendorID: UInt32? = nil, productID: UInt32? = nil, serialNumber: String? = nil, supportsDDC: Bool = true, availableInputs: [InputSource] = InputSource.commonInputs) {
        self.displayID = displayID
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.supportsDDC = supportsDDC
        self.availableInputs = availableInputs
    }
}

/// DDC/CI input source definition
struct InputSource: Codable, Hashable, Identifiable {
    var id: UInt8 { code }
    var code: UInt8
    var name: String
    
    // Common DDC/CI VCP 0x60 input source codes
    static let vga1 = InputSource(code: 0x01, name: "VGA-1")
    static let vga2 = InputSource(code: 0x02, name: "VGA-2")
    static let dvi1 = InputSource(code: 0x03, name: "DVI-1")
    static let dvi2 = InputSource(code: 0x04, name: "DVI-2")
    static let composite1 = InputSource(code: 0x05, name: "Composite-1")
    static let composite2 = InputSource(code: 0x06, name: "Composite-2")
    static let sVideo1 = InputSource(code: 0x07, name: "S-Video-1")
    static let sVideo2 = InputSource(code: 0x08, name: "S-Video-2")
    static let tuner1 = InputSource(code: 0x09, name: "Tuner-1")
    static let tuner2 = InputSource(code: 0x0A, name: "Tuner-2")
    static let tuner3 = InputSource(code: 0x0B, name: "Tuner-3")
    static let component1 = InputSource(code: 0x0C, name: "Component-1")
    static let component2 = InputSource(code: 0x0D, name: "Component-2")
    static let component3 = InputSource(code: 0x0E, name: "Component-3")
    static let displayPort1 = InputSource(code: 0x0F, name: "DisplayPort-1")
    static let displayPort2 = InputSource(code: 0x10, name: "DisplayPort-2")
    static let hdmi1 = InputSource(code: 0x11, name: "HDMI-1")
    static let hdmi2 = InputSource(code: 0x12, name: "HDMI-2")
    static let usbC = InputSource(code: 0x1B, name: "USB-C")  // 0x1B = 27
    
    /// Common inputs for most modern monitors
    static let commonInputs: [InputSource] = [
        .hdmi1, .hdmi2, .displayPort1, .displayPort2, .usbC
    ]
    
    /// All known input sources
    static let allInputs: [InputSource] = [
        .vga1, .vga2, .dvi1, .dvi2,
        .displayPort1, .displayPort2,
        .hdmi1, .hdmi2, .usbC
    ]
}
