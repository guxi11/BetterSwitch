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
import AppKit

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
    
    // Track when we last sent a switch event for each keyboard
    // This prevents repeated triggering while using the same keyboard
    private var lastSwitchEventTime: [String: Date] = [:]
    
    // Health check timer to ensure HID monitoring stays active
    private var healthCheckTimer: Timer?
    private var lastHIDActivity: Date = Date()
    
    // Keep a strong reference to self for the callback context
    // This prevents the callback from accessing freed memory
    private var retainedSelf: BluetoothMonitor?
    
    // Minimum time between switch events for the same keyboard (in seconds)
    // This should be long enough that normal typing pauses don't trigger repeated switches,
    // but short enough that switching between devices still works quickly
    private let switchEventCooldown: TimeInterval = 30.0
    
    // Logger reference
    private let logger = AppLogger.shared
    
    // Workspace observers
    private var workspaceObserver: NSObjectProtocol?
    
    init() {
        logger.info("BT", "BluetoothMonitor initialized")
        setupWorkspaceObserver()
    }
    
    deinit {
        stopMonitoring()
        healthCheckTimer?.invalidate()
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        logger.info("BT", "BluetoothMonitor deinitialized")
    }
    
    // MARK: - Workspace Observers (Sleep/Wake handling)
    
    private func setupWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.logger.info("System", "Mac woke from sleep. Restarting HID monitoring...")
            // When Mac wakes up, Bluetooth devices take a moment to reconnect
            // We restart immediately, and the health check will handle any subsequent issues
            if self?.isMonitoring == true {
                self?.stopHIDMonitoring()
                // Small delay to let system settle
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self?.startHIDMonitoring()
                }
            }
        }
    }
    
    // MARK: - Public Methods
    
    func startMonitoring() {
        guard !isMonitoring else {
            logger.warning("BT", "Monitoring already active, skipping start")
            return
        }
        
        logger.info("BT", "Starting monitoring...")
        
        DispatchQueue.main.async {
            self.isMonitoring = true
            self.lastError = nil
            
            // Retain self to prevent deallocation while HID callback is active
            self.retainedSelf = self
            
            // Initial scan
            self.scanForKeyboards()
            
            // Start HID monitoring
            self.startHIDMonitoring()
            
            // Start health check timer
            self.startHealthCheckTimer()
            
            self.logger.info("BT", "Monitoring started successfully")
        }
    }
    
    func stopMonitoring() {
        logger.info("BT", "Stopping monitoring...")
        
        DispatchQueue.main.async {
            self.healthCheckTimer?.invalidate()
            self.healthCheckTimer = nil
            self.stopHIDMonitoring()
            self.isMonitoring = false
            
            // Release self reference
            self.retainedSelf = nil
            
            self.logger.info("BT", "Monitoring stopped")
        }
    }
    
    /// Scan for paired keyboards (both Classic and BLE)
    func scanForKeyboards() {
        logger.info("BT", "Scanning for keyboards...")
        
        DispatchQueue.main.async {
            self.isScanning = true
            self.lastError = nil
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            var foundKeyboards: [BluetoothKeyboardInfo] = []
            
            // Method 1: Classic Bluetooth via IOBluetooth
            if let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
                self.logger.debug("BT", "Found \(devices.count) paired Bluetooth devices")
                
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
                        self.logger.debug("BT", "Found keyboard: \(name) (connected: \(device.isConnected()))")
                    }
                }
            }
            
            // Method 2: BLE keyboards via system_profiler
            let bleKeyboards = self.scanBLEKeyboardsViaSystemProfiler()
            self.logger.debug("BT", "Found \(bleKeyboards.count) BLE keyboards")
            
            for bleKeyboard in bleKeyboards {
                if !foundKeyboards.contains(where: { $0.address == bleKeyboard.address || $0.name == bleKeyboard.name }) {
                    foundKeyboards.append(bleKeyboard)
                }
            }
            
            DispatchQueue.main.async {
                self.pairedKeyboards = foundKeyboards
                self.connectedKeyboards = foundKeyboards.filter { $0.isConnected }
                self.isScanning = false
                
                self.logger.info("BT", "Scan complete: \(foundKeyboards.count) keyboards found")
                
                if foundKeyboards.isEmpty {
                    self.lastError = "No keyboards found"
                    self.logger.warning("BT", "No keyboards found during scan")
                }
            }
        }
    }
    
    // MARK: - HID Monitoring
    
    private func startHIDMonitoring() {
        logger.info("HID", "Starting HID monitoring...")
        
        // Stop existing manager if any
        if hidManager != nil {
            stopHIDMonitoring()
        }
        
        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        
        guard let manager = hidManager else {
            logger.error("HID", "Failed to create HID manager - this should not happen")
            return
        }
        
        // Match ALL HID devices first to see what's available
        // Then filter in the callback
        IOHIDManagerSetDeviceMatching(manager, nil)
        
        // Set up callbacks using a static function to avoid retain cycle issues
        let context = Unmanaged.passUnretained(self).toOpaque()
        
        // Device added callback
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, sender, device in
            guard let context = context else { return }
            let monitor = Unmanaged<BluetoothMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handleDeviceAdded(device)
        }, context)
        
        // Device removed callback
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, result, sender, device in
            guard let context = context else { return }
            let monitor = Unmanaged<BluetoothMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handleDeviceRemoved(device)
        }, context)
        
        // Input value callback
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, sender, value in
            guard let context = context else { return }
            let monitor = Unmanaged<BluetoothMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handleHIDInput(value)
        }, context)
        
        // Use commonModes to ensure callbacks work during UI interactions
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result == kIOReturnSuccess {
            logger.info("HID", "HID manager opened successfully")
            
            // Log currently connected devices
            if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
                var keyboardCount = 0
                
                if devices.isEmpty {
                    logger.warning("HID", "No HID devices found - Input Monitoring permission may be required")
                    logger.warning("HID", "Go to: System Settings > Privacy & Security > Input Monitoring")
                }
                
                for device in devices {
                    if let name = getHIDDeviceProperty(device, key: kIOHIDProductKey) as? String {
                        let usagePage = getHIDDeviceProperty(device, key: kIOHIDPrimaryUsagePageKey) as? Int ?? 0
                        let usage = getHIDDeviceProperty(device, key: kIOHIDPrimaryUsageKey) as? Int ?? 0
                        
                        // Only log keyboards at startup to reduce noise
                        if usagePage == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Keyboard || isKeyboardByName(name) {
                            logger.info("HID", "Keyboard detected: \(name)")
                            keyboardCount += 1
                        }
                    }
                }
                logger.info("HID", "Monitoring \(keyboardCount) keyboard(s) out of \(devices.count) HID devices")
            }
        } else {
            // Map common error codes
            let errorDescription: String
            switch result {
            case kIOReturnNotPermitted:
                errorDescription = "Not permitted - Input Monitoring permission required"
            case kIOReturnExclusiveAccess:
                errorDescription = "Exclusive access denied - another app may be using HID"
            case kIOReturnNotPrivileged:
                errorDescription = "Not privileged - app needs elevated permissions"
            default:
                errorDescription = "Error code: \(result)"
            }
            logger.error("HID", "Failed to open HID manager: \(errorDescription)")
            logger.error("HID", "Please grant Input Monitoring permission in System Settings")
        }
    }
    
    private func stopHIDMonitoring() {
        guard let manager = hidManager else { return }
        
        logger.info("HID", "Stopping HID monitoring...")
        
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = nil
        
        logger.info("HID", "HID monitoring stopped")
    }
    
    // MARK: - Health Check
    
    private func startHealthCheckTimer() {
        healthCheckTimer?.invalidate()
        
        // Check every 30 seconds if HID monitoring is still working
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.performHealthCheck()
        }
        // Make sure timer fires even when menu is open
        if let timer = healthCheckTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
        
        logger.info("HID", "Health check timer started (30s interval)")
    }
    
    private func performHealthCheck() {
        guard isMonitoring else { return }
        
        let timeSinceLastActivity = Date().timeIntervalSince(lastHIDActivity)
        
        logger.debug("HID", "Health check: last activity \(Int(timeSinceLastActivity))s ago, manager: \(hidManager != nil ? "active" : "nil")")
        
        // Check if HID manager is still valid
        if hidManager == nil {
            logger.warning("HID", "Health check: HID manager is nil, restarting...")
            startHIDMonitoring()
            return
        }
        
        // If no activity for 5 minutes, restart HID monitoring
        if timeSinceLastActivity > 300 {
            logger.warning("HID", "Health check: No HID activity for \(Int(timeSinceLastActivity))s, restarting...")
            stopHIDMonitoring()
            startHIDMonitoring()
        }
    }
    
    // MARK: - HID Callbacks
    
    private func handleDeviceAdded(_ device: IOHIDDevice) {
        guard let name = getHIDDeviceProperty(device, key: kIOHIDProductKey) as? String else { return }
        
        let usagePage = getHIDDeviceProperty(device, key: kIOHIDPrimaryUsagePageKey) as? Int ?? 0
        let usage = getHIDDeviceProperty(device, key: kIOHIDPrimaryUsageKey) as? Int ?? 0
        let isKeyboardByUsage = (usagePage == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Keyboard)
        
        if isKeyboardByUsage || isKeyboardByName(name) {
            logger.info("HID", "Keyboard connected: \(name)")
        } else if !name.lowercased().contains("mouse") {
            logger.debug("HID", "Device connected: \(name)")
        }
    }
    
    private func handleDeviceRemoved(_ device: IOHIDDevice) {
        guard let name = getHIDDeviceProperty(device, key: kIOHIDProductKey) as? String else { return }
        
        let usagePage = getHIDDeviceProperty(device, key: kIOHIDPrimaryUsagePageKey) as? Int ?? 0
        let usage = getHIDDeviceProperty(device, key: kIOHIDPrimaryUsageKey) as? Int ?? 0
        let isKeyboardByUsage = (usagePage == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Keyboard)
        
        if isKeyboardByUsage || isKeyboardByName(name) {
            logger.info("HID", "Keyboard disconnected: \(name)")
        } else if !name.lowercased().contains("mouse") {
            logger.debug("HID", "Device disconnected: \(name)")
        }
    }
    
    private func handleHIDInput(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        
        // Update last HID activity for health check
        lastHIDActivity = Date()
        
        // Record HID event for statistics
        AppLogger.shared.recordHIDEvent()
        
        // Get device name
        guard let deviceName = getHIDDeviceProperty(device, key: kIOHIDProductKey) as? String else {
            return
        }
        
        // Check usage page to filter for keyboards
        let usagePage = getHIDDeviceProperty(device, key: kIOHIDPrimaryUsagePageKey) as? Int ?? 0
        let usage = getHIDDeviceProperty(device, key: kIOHIDPrimaryUsageKey) as? Int ?? 0
        
        // Log all input occasionally for debugging
        let now = Date()
        let debugKey = "__debug_\(deviceName)__"
        let lastLog = lastKeyboardActivity[debugKey] ?? Date.distantPast
        
        // Only log non-keyboard devices very infrequently (every 30s) to avoid spam
        // Log keyboards more frequently (every 5s)
        let isKeyboardByUsage = (usagePage == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Keyboard)
        let isKeyboardByNameMatch = isKeyboardByName(deviceName)
        let isProbablyKeyboard = isKeyboardByUsage || isKeyboardByNameMatch
        
        let logInterval: TimeInterval = isProbablyKeyboard ? 5.0 : 30.0
        
        if now.timeIntervalSince(lastLog) > logInterval {
            lastKeyboardActivity[debugKey] = now
            if isProbablyKeyboard {
                logger.debug("HID", "Keyboard input: \(deviceName)")
            } else {
                // Don't log mouse movements by default unless they look like keyboards
                if deviceName.lowercased().contains("mouse") {
                    // Skip logging mice entirely to reduce noise
                } else {
                    logger.debug("HID", "Other input: \(deviceName) (page:\(usagePage) usage:\(usage))")
                }
            }
        }
        
        guard isProbablyKeyboard else {
            return
        }
        
        let lastActivity = lastKeyboardActivity[deviceName] ?? Date.distantPast
        let timeSinceLastActivity = now.timeIntervalSince(lastActivity)
        
        // Debounce: only process if more than 0.5 second since last activity for this keyboard
        guard timeSinceLastActivity > 0.5 else {
            return
        }
        
        lastKeyboardActivity[deviceName] = now
        
        // Find matching keyboard in paired list or create temporary one
        guard let keyboard = findMatchingKeyboard(deviceName) else {
            logger.warning("HID", "Keyboard activity from '\(deviceName)' but no match found")
            return
        }
        
        // Determine if we should send a switch event
        let isDifferentKeyboard = lastActiveKeyboard?.id != keyboard.id
        let isReactivation = timeSinceLastActivity > 5.0
        
        var shouldTrigger = false
        var reason = ""
        
        if isDifferentKeyboard {
            shouldTrigger = true
            reason = "different keyboard"
        } else if isReactivation {
            let lastSwitchTime = lastSwitchEventTime[keyboard.id] ?? Date.distantPast
            let timeSinceLastSwitch = now.timeIntervalSince(lastSwitchTime)
            
            if timeSinceLastSwitch >= switchEventCooldown {
                shouldTrigger = true
                reason = "reactivation after \(Int(timeSinceLastActivity))s"
            } else {
                logger.debug("HID", "Keyboard \(keyboard.name) reactivation skipped (cooldown: \(Int(switchEventCooldown - timeSinceLastSwitch))s remaining)")
            }
        }
        
        if shouldTrigger {
            logger.info("HID", "Keyboard active: \(keyboard.name) (\(reason))")
            
            // Update last switch event time for this keyboard
            lastSwitchEventTime[keyboard.id] = now
            
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
        
        // If no match found in paired list, create a temporary keyboard info
        // This ensures HID-detected keyboards can still trigger switches
        if isKeyboardByName(deviceName) {
            logger.debug("HID", "Creating temporary keyboard info for: \(deviceName)")
            return BluetoothKeyboardInfo(
                id: deviceName,
                name: deviceName,
                address: "",
                isConnected: true,
                isBLE: false
            )
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
            logger.error("BT", "system_profiler error: \(error)")
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
