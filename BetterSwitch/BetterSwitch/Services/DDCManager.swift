//
//  DDCManager.swift
//  BetterSwitch
//
//  Created by zhangyuanyuan on 2026/3/16.
//

import Foundation
import IOKit
import IOKit.i2c
import CoreGraphics
import AppKit

/// Manages DDC/CI communication with monitors for input source switching
@Observable
final class DDCManager {
    /// Detected displays with DDC/CI support info
    private(set) var monitors: [DisplayInfo] = []
    
    /// Last error encountered
    private(set) var lastError: String?
    
    /// Display information structure
    struct DisplayInfo: Identifiable {
        let id: CGDirectDisplayID
        var displayID: CGDirectDisplayID { id }
        let name: String
        var servicePort: io_service_t
        var displayIndex: Int
        var currentInput: UInt8?
        var supportsDDC: Bool = true
    }
    
    // MARK: - Public Methods
    
    /// Enumerate all connected displays
    func enumerateDisplays() {
        monitors.removeAll()
        lastError = nil
        
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        
        let result = CGGetActiveDisplayList(16, &displayIDs, &displayCount)
        guard result == .success else {
            lastError = "Failed to get display list"
            return
        }
        
        print("[DDCManager] Found \(displayCount) display(s)")
        
        var externalIndex = 1
        
        for i in 0..<Int(displayCount) {
            let displayID = displayIDs[i]
            
            if CGDisplayIsBuiltin(displayID) != 0 {
                continue
            }
            
            let name = getDisplayName(for: displayID) ?? "External Display \(displayID)"
            let servicePort = CGDisplayIOServicePort(displayID)
            
            let info = DisplayInfo(
                id: displayID,
                name: name,
                servicePort: servicePort,
                displayIndex: externalIndex,
                currentInput: nil,
                supportsDDC: true
            )
            monitors.append(info)
            
            print("[DDCManager] Added: \(name) (index=\(externalIndex))")
            externalIndex += 1
        }
        
        if monitors.isEmpty {
            lastError = "No external monitors detected"
        }
    }
    
    /// Set the input source for a display
    /// Input codes: HDMI1=17, HDMI2=18, DP1=15, DP2=16, USBC=27
    func setInputSource(_ inputCode: UInt8, for displayID: CGDirectDisplayID) -> Bool {
        print("[DDCManager] setInputSource called with displayID: \(displayID), inputCode: \(inputCode)")
        print("[DDCManager] Available monitors: \(monitors.map { "\($0.name): \($0.displayID)" })")
        
        guard let monitorIndex = monitors.firstIndex(where: { $0.displayID == displayID }) else {
            lastError = "Display not found (ID: \(displayID))"
            print("[DDCManager] ERROR: Display not found with ID \(displayID)")
            return false
        }
        
        let monitor = monitors[monitorIndex]
        
        // Check current input first to avoid unnecessary switching
        // Retry up to 3 times if read fails
        var currentInput: UInt8? = nil
        for attempt in 1...3 {
            currentInput = getCurrentInputSource(for: monitor.displayIndex)
            if currentInput != nil {
                break
            }
            print("[DDCManager] Read attempt \(attempt) failed, retrying...")
            Thread.sleep(forTimeInterval: 0.1)  // Brief delay before retry
        }
        
        guard let confirmedInput = currentInput else {
            print("[DDCManager] Failed to read current input after 3 attempts, aborting switch")
            lastError = "Cannot read current input"
            return false
        }
        
        print("[DDCManager] Current input for \(monitor.name): \(confirmedInput), target: \(inputCode)")
        if confirmedInput == inputCode {
            print("[DDCManager] Already on target input \(inputCode), skipping switch")
            return true
        }
        
        print("[DDCManager] INPUT MISMATCH - current: \(confirmedInput), target: \(inputCode). Will switch \(monitor.name)")
        
        var success = false
        
        // Method 1: Use AppleScript to run m1ddc (bypasses Hardened Runtime restrictions)
        success = runM1DDCViaAppleScript(displayIndex: monitor.displayIndex, inputCode: inputCode)
        print("[DDCManager] AppleScript result: \(success)")
        
        // Method 2: Native I2C (fallback)
        if !success && monitor.servicePort != 0 {
            success = sendDDCViaNative(service: monitor.servicePort, inputCode: inputCode)
            print("[DDCManager] Native I2C result: \(success)")
        }
        
        if success {
            monitors[monitorIndex].currentInput = inputCode
            lastError = nil
        } else {
            lastError = "DDC failed. Ensure m1ddc is installed: brew install m1ddc"
        }
        
        return success
    }
    
    /// Get the current input source for a display
    func getCurrentInputSource(for displayIndex: Int) -> UInt8? {
        print("[DDCManager] GET input for display \(displayIndex)...")
        let script = """
        do shell script "/opt/homebrew/bin/m1ddc get input -d \(displayIndex)"
        """
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            
            if error != nil {
                print("[DDCManager] GET input failed, trying alt path...")
                // Try alternative path
                return getCurrentInputSourceAlt(for: displayIndex)
            }
            
            if let output = result.stringValue,
               let inputValue = UInt8(output.trimmingCharacters(in: .whitespacesAndNewlines)) {
                print("[DDCManager] GET input returned: \(inputValue)")
                return inputValue
            }
        }
        
        print("[DDCManager] GET input returned nil")
        return nil
    }
    
    private func getCurrentInputSourceAlt(for displayIndex: Int) -> UInt8? {
        let script = """
        do shell script "export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; m1ddc get input -d \(displayIndex)"
        """
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            
            if error != nil {
                return nil
            }
            
            if let output = result.stringValue,
               let inputValue = UInt8(output.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return inputValue
            }
        }
        
        return nil
    }
    
    // MARK: - m1ddc via AppleScript
    
    private func runM1DDCViaAppleScript(displayIndex: Int, inputCode: UInt8) -> Bool {
        // Use AppleScript's "do shell script" which runs in a different security context
        let script = """
        do shell script "/opt/homebrew/bin/m1ddc set input \(inputCode) -d \(displayIndex)"
        """
        
        print("[DDCManager] Running AppleScript: \(script)")
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            
            if let error = error {
                print("[DDCManager] AppleScript error: \(error)")
                
                // Try alternative path
                return runM1DDCViaAppleScriptAlt(displayIndex: displayIndex, inputCode: inputCode)
            }
            
            print("[DDCManager] AppleScript result: \(result.stringValue ?? "ok")")
            return true
        }
        
        return false
    }
    
    private func runM1DDCViaAppleScriptAlt(displayIndex: Int, inputCode: UInt8) -> Bool {
        // Try with explicit PATH
        let script = """
        do shell script "export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; m1ddc set input \(inputCode) -d \(displayIndex)"
        """
        
        print("[DDCManager] Running AppleScript (alt): \(script)")
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            
            if let error = error {
                print("[DDCManager] AppleScript (alt) error: \(error)")
                return false
            }
            
            print("[DDCManager] AppleScript (alt) result: \(result.stringValue ?? "ok")")
            return true
        }
        
        return false
    }
    
    // MARK: - Native I2C (Fallback)
    
    private func sendDDCViaNative(service: io_service_t, inputCode: UInt8) -> Bool {
        if let i2c = findI2CInterface(for: service) {
            defer { IOObjectRelease(i2c) }
            return sendDDCCommand(service: i2c, inputCode: inputCode)
        }
        return sendDDCCommand(service: service, inputCode: inputCode)
    }
    
    private func findI2CInterface(for service: io_service_t) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        
        while case let child = IOIteratorNext(iterator), child != 0 {
            var className = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(child, &className)
            if String(cString: className).contains("I2C") {
                return child
            }
            if let found = findI2CInterface(for: child) {
                IOObjectRelease(child)
                return found
            }
            IOObjectRelease(child)
        }
        return nil
    }
    
    private func sendDDCCommand(service: io_service_t, inputCode: UInt8) -> Bool {
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connect) == KERN_SUCCESS else {
            return false
        }
        defer { IOServiceClose(connect) }
        
        var data: [UInt8] = [0x51, 0x84, 0x03, 0x60, 0x00, inputCode]
        var checksum: UInt8 = 0x6E
        for b in data { checksum ^= b }
        data.append(checksum)
        
        return data.withUnsafeBytes { ptr -> Bool in
            var request = IOI2CRequest()
            request.sendAddress = 0x6E
            request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
            request.sendBuffer = vm_address_t(bitPattern: ptr.baseAddress)
            request.sendBytes = UInt32(data.count)
            request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
            
            var size = MemoryLayout<IOI2CRequest>.size
            let result = withUnsafeMutableBytes(of: &request) { reqPtr in
                IOConnectCallStructMethod(connect, 0, reqPtr.baseAddress, size, reqPtr.baseAddress, &size)
            }
            return result == KERN_SUCCESS
        }
    }
    
    private func getDisplayName(for displayID: CGDirectDisplayID) -> String? {
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               num == displayID {
                return screen.localizedName
            }
        }
        return nil
    }
    
    deinit {
        for m in monitors where m.servicePort != 0 {
            IOObjectRelease(m.servicePort)
        }
    }
}

@_silgen_name("CGDisplayIOServicePort")
func CGDisplayIOServicePort(_ display: CGDirectDisplayID) -> io_service_t
