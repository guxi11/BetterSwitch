//
//  LaunchAtLogin.swift
//  BetterSwitch
//
//  Created by zhangyuanyuan on 2026/3/16.
//

import Foundation
import ServiceManagement

/// Manages the "Launch at Login" functionality using SMAppService (macOS 13+)
enum LaunchAtLogin {
    /// Check if launch at login is currently enabled
    static var isEnabled: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            } else {
                // Fallback for older macOS versions
                return UserDefaults.standard.bool(forKey: "launchAtLoginLegacy")
            }
        }
        set {
            if #available(macOS 13.0, *) {
                setEnabledModern(newValue)
            } else {
                setEnabledLegacy(newValue)
            }
        }
    }
    
    /// Get the current status as a human-readable string
    static var statusDescription: String {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .notRegistered:
                return "Not Registered"
            case .enabled:
                return "Enabled"
            case .requiresApproval:
                return "Requires Approval"
            case .notFound:
                return "Not Found"
            @unknown default:
                return "Unknown"
            }
        } else {
            return isEnabled ? "Enabled (Legacy)" : "Disabled"
        }
    }
    
    // MARK: - Modern Implementation (macOS 13+)
    
    @available(macOS 13.0, *)
    private static func setEnabledModern(_ enabled: Bool) {
        do {
            if enabled {
                // Register app as login item
                if SMAppService.mainApp.status == .enabled {
                    // Already enabled
                    return
                }
                try SMAppService.mainApp.register()
            } else {
                // Unregister app as login item
                if SMAppService.mainApp.status != .enabled {
                    // Already disabled
                    return
                }
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to \(enabled ? "enable" : "disable") launch at login: \(error)")
        }
    }
    
    // MARK: - Legacy Implementation (macOS 12 and earlier)
    
    private static func setEnabledLegacy(_ enabled: Bool) {
        // For macOS 12 and earlier, we use the deprecated SMLoginItemSetEnabled
        // This requires a helper app in the bundle, which we won't implement here
        // Just store the preference for UI purposes
        UserDefaults.standard.set(enabled, forKey: "launchAtLoginLegacy")
        
        #if DEBUG
        print("Legacy launch at login: \(enabled) (not fully implemented)")
        #endif
    }
}

// MARK: - SwiftUI Helper

import SwiftUI

/// SwiftUI view modifier for launch at login toggle
struct LaunchAtLoginToggle: View {
    @State private var isEnabled = LaunchAtLogin.isEnabled
    
    var body: some View {
        Toggle("Launch at Login", isOn: $isEnabled)
            .onChange(of: isEnabled) { _, newValue in
                LaunchAtLogin.isEnabled = newValue
            }
            .onAppear {
                isEnabled = LaunchAtLogin.isEnabled
            }
    }
}
