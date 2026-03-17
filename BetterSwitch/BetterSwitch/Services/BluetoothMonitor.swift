//
//  BluetoothMonitor.swift
//  BetterSwitch
//
//  Created by zhangyuanyuan on 2026/3/16.
//

import Foundation
import IOBluetooth
import Combine
import IOKit
import IOKit.hid

/// Simple struct to hold keyboard info (thread-safe)
struct BluetoothKeyboardInfo: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let address: String
    let isConnected: Bool
    let isBLE: Bool
    
    init(id: String, name: String, address: String, isConnected: Bool, isBLE: Bool = false) {
        self.id = id
        self.name = name
        self.address = address
        self.isConnected = isConnected
        self.isBLE = isBLE
    }
}

/// Monitors Bluetooth keyboard connections and activity
/// Supports both Classic Bluetooth and BLE keyboards
final class BluetoothMonitor: ObservableObject {
    /// Currently connected keyboards
    @Published private(set) var connectedKeyboards: [BluetoothKeyboardInfo] = []
    
    /// All paired keyboards
    @Published private(set) var pairedKeyboards: [BluetoothKeyboardInfo] = []
    
    /// Last active keyboard (most recently used)
    @Published private(set) var lastActiveKeyboard: BluetoothKeyboardInfo?
    
    /// Last error message
    @Published private(set) var lastError: String?
    
    /// Whether monitoring is active
    @Published private(set) var isMonitoring: Bool = false
    
    /// Whether a scan is in progress
    @Published private(set) var isScanning: Bool = false
    
    // MARK: - Publishers
    
    let keyboardConnectedPublisher = PassthroughSubject<BluetoothKeyboardInfo, Never>()
    let keyboardDisconnectedPublisher = PassthroughSubject<BluetoothKeyboardInfo, Never>()
    let keyboardBecameActivePublisher = PassthroughSubject<BluetoothKeyboardInfo, Never>()
    
    // MARK: - Bluetooth Device Class Constants (Classic)
    
    private let kPeripheralMajorClass: UInt32 = 0x05
    private let kKeyboardMinorClass: UInt32 = 0x40
    
    // Known keyboard name patterns
    private let keyboardNamePatterns = ["keyboard", "kbd", "crkbd", "corne", "keeb", "ergodox", "planck", "preonic", "lily58", "sofle", "kyria"]
    
    // HID Manager for keyboard activity monitoring
    private var hidManager: IOHIDManager?
    private var lastKeyboardActivity: [String: Date] = [:]
    
    init() {}
    
    deinit {
        stopMonitoring()
    }
    
    // MARK: - Public Methods
    
    func startMonitoring() {
        guard !isMonitoring else { return }
        
        print("[BluetoothMonitor] Starting keyboard activity monitoring...")
        
        DispatchQueue.main.async {
            self.isMonitoring = true
            self.lastError = nil
            
            // Initial scan
            self.scanForKeyboards()
            
            // Start HID monitoring
            self.startHIDMonitoring()
        }
    }
    
    func stopMonitoring() {
        print("[BluetoothMonitor] Stopping keyboard activity monitoring...")
        
        DispatchQueue.main.async {
            self.stopHIDMonitoring()
            self.isMonitoring = false
        }
    }
    
    /// Scan for paired keyboards (both Classic and BLE)
    func scanForKeyboards() {
        DispatchQueue.main.async {
            self.isScanning = true
            self.lastError = nil
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            var foundKeyboards: [BluetoothKeyboardInfo] = []
            
            // Method 1: Classic Bluetooth via IOBluetooth
            print("[BluetoothMonitor] Scanning Classic Bluetooth...")
            if let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
                print("[BluetoothMonitor] Found \(devices.count) classic paired devices")
                for device in devices {
                    let name = device.name ?? "Unknown"
                    let majorClass = device.deviceClassMajor
                    let minorClass = device.deviceClassMinor
                    
                    let isKeyboardByClass = majorClass == self.kPeripheralMajorClass && (minorClass & self.kKeyboardMinorClass) != 0
                    let isKeyboardByName = self.isKeyboardByName(name)
                    
                    if isKeyboardByClass || isKeyboardByName {
                        let info = BluetoothKeyboardInfo(
                            id: device.addressString ?? UUID().uuidString,
                            name: name,
                            address: device.addressString ?? "",
                            isConnected: device.isConnected(),
                            isBLE: false
                        )
                        foundKeyboards.append(info)
                        print("[BluetoothMonitor] Added keyboard: \(name)")
                    }
                }
            }
            
            // Method 2: BLE keyboards via system_profiler
            print("[BluetoothMonitor] Scanning BLE devices via system_profiler...")
            let bleKeyboards = self.scanBLEKeyboardsViaSystemProfiler()
            
            for bleKeyboard in bleKeyboards {
                if !foundKeyboards.contains(where: { $0.address == bleKeyboard.address || $0.name == bleKeyboard.name }) {
                    foundKeyboards.append(bleKeyboard)
                }
            }
            
            print("[BluetoothMonitor] Total keyboards found: \(foundKeyboards.count)")
            for kb in foundKeyboards {
                print("[BluetoothMonitor]   - \(kb.name) (\(kb.address)) connected: \(kb.isConnected)")
            }
            
            DispatchQueue.main.async {
                self.pairedKeyboards = foundKeyboards
                self.connectedKeyboards = foundKeyboards.filter { $0.isConnected }
                self.isScanning = false
                
                if foundKeyboards.isEmpty {
                    self.lastError = "No keyboards found"
                }
            }
        }
    }
    
    // MARK: - HID Monitoring
    
    private func startHIDMonitoring() {
        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        
        guard let manager = hidManager else {
            print("[BluetoothMonitor] Failed to create HID manager")
            return
        }
        
        // Match keyboard devices
        let matchingDict: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard
        ]
        
        IOHIDManagerSetDeviceMatching(manager, matchingDict as CFDictionary)
        
        // Set up callbacks
        let context = Unmanaged.passUnretained(self).toOpaque()
        
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, sender, value in
            guard let context = context else { return }
            let monitor = Unmanaged<BluetoothMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handleHIDInput(value)
        }, context)
        
        // Use commonModes instead of defaultMode to ensure callbacks work even when
        // the app is in background or during UI tracking (e.g., menu bar interactions)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result == kIOReturnSuccess {
            print("[BluetoothMonitor] HID monitoring started successfully")
        } else {
            print("[BluetoothMonitor] Failed to open HID manager: \(result)")
        }
    }
    
    private func stopHIDMonitoring() {
        guard let manager = hidManager else { return }
        
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = nil
        
        print("[BluetoothMonitor] HID monitoring stopped")
    }
    
    private func handleHIDInput(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        
        guard let deviceName = getHIDDeviceProperty(device, key: kIOHIDProductKey) as? String else { return }
        
        // Check if this is a keyboard we're tracking
        guard isKeyboardByName(deviceName) else { return }
        
        let now = Date()
        let lastActivity = lastKeyboardActivity[deviceName] ?? Date.distantPast
        let timeSinceLastActivity = now.timeIntervalSince(lastActivity)
        
        // Debounce: only process if more than 0.5 second since last activity for this keyboard
        guard timeSinceLastActivity > 0.5 else { return }
        
        lastKeyboardActivity[deviceName] = now
        
        // Find matching keyboard in paired list
        guard let keyboard = findMatchingKeyboard(deviceName) else { return }
        
        // Trigger if:
        // 1. Different keyboard than last active, OR
        // 2. Same keyboard but it's been more than 5 seconds (potential reactivation after switching away)
        //
        // Note: DDCManager will check the current input source before switching,
        // so even if we trigger here, no actual switch will happen if already on target input.
        let isDifferentKeyboard = lastActiveKeyboard?.id != keyboard.id
        let isReactivation = timeSinceLastActivity > 5.0
        
        if isDifferentKeyboard || isReactivation {
            print("[BluetoothMonitor] KEYBOARD ACTIVE: \(keyboard.name) (different: \(isDifferentKeyboard), reactivation: \(isReactivation))")
            
            DispatchQueue.main.async {
                self.lastActiveKeyboard = keyboard
                self.keyboardBecameActivePublisher.send(keyboard)
                
                NotificationCenter.default.post(
                    name: .bluetoothKeyboardBecameActive,
                    object: self,
                    userInfo: ["keyboard": keyboard]
                )
            }
        }
    }
    
    private func findMatchingKeyboard(_ deviceName: String) -> BluetoothKeyboardInfo? {
        let lowercaseDeviceName = deviceName.lowercased()
        
        // Try exact match first
        if let keyboard = pairedKeyboards.first(where: { $0.name.lowercased() == lowercaseDeviceName }) {
            return keyboard
        }
        
        // Try partial match
        if let keyboard = pairedKeyboards.first(where: { 
            lowercaseDeviceName.contains($0.name.lowercased()) || 
            $0.name.lowercased().contains(lowercaseDeviceName) 
        }) {
            return keyboard
        }
        
        return nil
    }
    
    private func getHIDDeviceProperty(_ device: IOHIDDevice, key: String) -> Any? {
        return IOHIDDeviceGetProperty(device, key as CFString)
    }
    
    // MARK: - Private Methods
    
    private func isKeyboardByName(_ name: String) -> Bool {
        let lowercaseName = name.lowercased()
        return keyboardNamePatterns.contains { lowercaseName.contains($0) }
    }
    
    private func scanBLEKeyboardsViaSystemProfiler() -> [BluetoothKeyboardInfo] {
        var keyboards: [BluetoothKeyboardInfo] = []
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-xml"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            
            if let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] {
                keyboards = parseBluetoothPlist(plist)
            }
        } catch {
            print("[BluetoothMonitor] system_profiler error: \(error)")
        }
        
        return keyboards
    }
    
    private func parseBluetoothPlist(_ plist: [[String: Any]]) -> [BluetoothKeyboardInfo] {
        var keyboards: [BluetoothKeyboardInfo] = []
        
        for item in plist {
            guard let items = item["_items"] as? [[String: Any]] else { continue }
            
            for controller in items {
                if let connected = controller["device_connected"] as? [[String: Any]] {
                    for device in connected {
                        if let keyboard = parseBluetoothDevice(device, isConnected: true) {
                            keyboards.append(keyboard)
                        }
                    }
                }
                
                if let notConnected = controller["device_not_connected"] as? [[String: Any]] {
                    for device in notConnected {
                        if let keyboard = parseBluetoothDevice(device, isConnected: false) {
                            keyboards.append(keyboard)
                        }
                    }
                }
            }
        }
        
        return keyboards
    }
    
    private func parseBluetoothDevice(_ device: [String: Any], isConnected: Bool) -> BluetoothKeyboardInfo? {
        guard let name = device["_name"] as? String else { return nil }
        
        let minorType = device["device_minorType"] as? String ?? ""
        let isKeyboardByType = minorType.lowercased().contains("keyboard")
        let isKeyboardByName = self.isKeyboardByName(name)
        
        guard isKeyboardByType || isKeyboardByName else { return nil }
        
        let address = device["device_address"] as? String ?? UUID().uuidString
        let services = device["device_services"] as? String ?? ""
        let isBLE = services.contains("BLE")
        
        return BluetoothKeyboardInfo(
            id: address,
            name: name,
            address: address,
            isConnected: isConnected,
            isBLE: isBLE
        )
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let bluetoothKeyboardConnected = Notification.Name("bluetoothKeyboardConnected")
    static let bluetoothKeyboardDisconnected = Notification.Name("bluetoothKeyboardDisconnected")
    static let bluetoothKeyboardBecameActive = Notification.Name("bluetoothKeyboardBecameActive")
}
