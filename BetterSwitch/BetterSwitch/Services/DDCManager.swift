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
    
    // MARK: - Valid Input Source Codes
    
    /// Known invalid values that indicate DDC/CI communication errors
    /// - 0: Read timeout or no response
    /// - 0x6E (110): DDC/CI I2C write address leaked into response
    /// - 0x6F (111): DDC/CI I2C read address leaked into response
    /// - 0xFF (255): Common error/invalid marker
    private static let knownInvalidCodes: Set<UInt8> = [0, 0x6E, 0x6F, 0xFF]
    
    /// Check if an input code is a valid DDC/CI input source
    /// Valid MCCS input codes are in range 1-27 (standard) with some vendor extensions up to ~30
    private func isValidInputCode(_ code: UInt8) -> Bool {
        // Reject known error codes
        if Self.knownInvalidCodes.contains(code) {
            return false
        }
        // Valid input codes are generally 1-27 per VESA MCCS standard
        // Some vendors use codes up to ~30 for USB-C variants
        // Anything above 30 is almost certainly an error
        return code >= 1 && code <= 30
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
        guard let monitorIndex = monitors.firstIndex(where: { $0.displayID == displayID }) else {
            lastError = "Display not found (ID: \(displayID))"
            return false
        }
        
        let monitor = monitors[monitorIndex]
        
        // Try to read current input with retries
        // DDC/CI can occasionally return invalid values (0, 110, etc.) due to timing issues
        var currentInput: UInt8? = nil
        for attempt in 1...3 {
            currentInput = getCurrentInputSource(for: monitor.displayIndex)
            if currentInput != nil {
                break
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        
        if let confirmedInput = currentInput {
            if confirmedInput == inputCode {
                print("[DDCManager] \(monitor.name): already on input \(inputCode), skipping")
                return true
            }
            print("[DDCManager] \(monitor.name): switching from \(confirmedInput) to \(inputCode)")
        } else {
            print("[DDCManager] \(monitor.name): switching to input \(inputCode)")
        }
        
        var success = false
        
        // Method 1: Use AppleScript to run m1ddc (bypasses Hardened Runtime restrictions)
        success = runM1DDCViaAppleScript(displayIndex: monitor.displayIndex, inputCode: inputCode)
        
        // Method 2: Native I2C (fallback)
        if !success && monitor.servicePort != 0 {
            success = sendDDCViaNative(service: monitor.servicePort, inputCode: inputCode)
        }
        
        if success {
            lastError = nil
            print("[DDCManager] \(monitor.name): switch successful")
        } else {
            lastError = "DDC failed. Ensure m1ddc is installed: brew install m1ddc"
            print("[DDCManager] \(monitor.name): switch failed")
        }
        
        return success
    }
    
    /// Get the current input source for a display
    func getCurrentInputSource(for displayIndex: Int) -> UInt8? {
        // Use Process directly instead of AppleScript for more reliable execution
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/m1ddc")
        process.arguments = ["get", "input", "-d", "\(displayIndex)"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                
                if let inputValue = UInt8(trimmed) {
                    // Validate input code - reject invalid values like 0, 110, etc.
                    if !isValidInputCode(inputValue) {
                        return nil
                    }
                    return inputValue
                }
            }
        } catch {
            // Try AppleScript as fallback
            return getCurrentInputSourceViaAppleScript(for: displayIndex)
        }
        
        return nil
    }
    
    private func getCurrentInputSourceViaAppleScript(for displayIndex: Int) -> UInt8? {
        let script = """
        do shell script "/opt/homebrew/bin/m1ddc get input -d \(displayIndex)"
        """
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            
            if error != nil {
                return nil
            }
            
            if let output = result.stringValue {
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if let inputValue = UInt8(trimmed) {
                    // Validate input code
                    if !isValidInputCode(inputValue) {
                        return nil
                    }
                    return inputValue
                }
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
