//
//  AppState.swift
//  BetterSwitch
//
//  Created by zhangyuanyuan on 2026/3/16.
//

import Foundation
import SwiftUI
import CoreGraphics

/// Observable app state for runtime data
@Observable
final class AppState {
    /// Currently connected Bluetooth keyboard (if any)
    var connectedKeyboard: BluetoothKeyboard?
    
    /// Whether automatic input switching is enabled
    var isEnabled: Bool = true
    
    /// Available input sources for quick switching
    var availableInputs: [InputSource] = InputSource.commonInputs
    
    /// Detected monitors (for display in UI)
    var detectedMonitors: [Monitor] = []
    
    /// Last error message (if any)
    var lastError: String?
    
    /// Reference to DDC
    /// manager for input switching
    weak var ddcManager: DDCManager?
    
    /// Switch to a specific input source on all detected monitors
    func switchToInput(_ code: UInt8) {
        guard let ddcManager = ddcManager else {
            lastError = "DDC Manager not available"
            return
        }
        
        // Use DDCManager's monitors directly (has the actual display IDs)
        let monitors = ddcManager.monitors
        
        if monitors.isEmpty {
            lastError = "No monitors detected"
            return
        }
        
        var anySuccess = false
        for monitor in monitors {
            if ddcManager.setInputSource(code, for: monitor.displayID) {
                anySuccess = true
            }
        }
        
        if anySuccess {
            lastError = nil
        } else {
            lastError = "Failed to switch input"
        }
    }
}

/// App settings stored in UserDefaults
final class AppSettings {
    static let shared = AppSettings()
    
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("isEnabled") var isEnabled: Bool = true
    @AppStorage("showMenuBarIcon") var showMenuBarIcon: Bool = true
    @AppStorage("switchDelay") var switchDelay: Double = 0.5
    @AppStorage("showNotifications") var showNotifications: Bool = true
    
    private init() {}
}
