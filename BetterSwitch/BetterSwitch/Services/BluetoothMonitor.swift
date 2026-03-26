//
//  BluetoothMonitor.swift
//  BetterSwitch
//
//  Created by zhangyuanyuan on 2026/3/16.
//

import Foundation
import Combine
import AppKit
import IOKit
import IOKit.hid

/// Simple struct to hold keyboard info (thread-safe)
struct BluetoothKeyboardInfo: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    
    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Monitors global keyboard activity using IOKit HID Manager.
/// This does NOT require Accessibility permission, only Input Monitoring.
/// Works for menu bar apps (LSUIElement) without a front-end window.
final class BluetoothMonitor: ObservableObject {
    
    @Published private(set) var lastActiveKeyboard: BluetoothKeyboardInfo?
    @Published private(set) var lastError: String?
    @Published private(set) var isMonitoring: Bool = false
    
    let keyboardBecameActivePublisher = PassthroughSubject<BluetoothKeyboardInfo, Never>()
    
    // IOKit HID
    private var hidManager: IOHIDManager?
    private var lastKeyboardActivity: [String: Date] = [:]
    private var lastSwitchEventTime: [String: Date] = [:]
    
    private var healthCheckTimer: Timer?
    private var lastHIDActivity: Date = Date()
    
    private let switchEventCooldown: TimeInterval = 30.0
    private let logger = AppLogger.shared
    
    private var workspaceObserver: NSObjectProtocol?
    private var screenParamsObserver: NSObjectProtocol?
    private var restartWorkItem: DispatchWorkItem?
    private var isRestarting: Bool = false
    
    init() {
        logger.info("BT", "BluetoothMonitor initialized")
        setupWorkspaceObserver()
    }
    
    deinit {
        stopMonitoring()
        healthCheckTimer?.invalidate()
        if let wObserver = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wObserver)
        }
        if let sObserver = screenParamsObserver {
            NotificationCenter.default.removeObserver(sObserver)
        }
        logger.info("BT", "BluetoothMonitor deinitialized")
    }
    
    // MARK: - Workspace Observers
    
    private func setupWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.logger.info("System", "Mac woke from sleep. Restarting monitoring...")
            self?.restartMonitoringWithDelay()
        }
    }
    
    private func restartMonitoringWithDelay() {
        guard isMonitoring else { return }
        
        // Just debounce - don't stop the manager yet, let it keep running
        restartWorkItem?.cancel()
        isRestarting = true
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isMonitoring else { return }
            self.isRestarting = false
            // Only restart if actually needed
            self.stopHIDManager()
            self.startHIDManager()
        }
        restartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: workItem)
    }
    
    // MARK: - Public Methods
    
    func startMonitoring() {
        guard !isMonitoring else {
            logger.warning("BT", "Monitoring already active, skipping start")
            return
        }
        
        logger.info("BT", "Starting monitoring...")
        isMonitoring = true
        lastError = nil
        
        startHIDManager()
        startHealthCheckTimer()
        
        logger.info("BT", "Monitoring started successfully")
    }
    
    func stopMonitoring() {
        logger.info("BT", "Stopping monitoring...")
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        restartWorkItem?.cancel()
        restartWorkItem = nil
        stopHIDManager()
        isMonitoring = false
        logger.info("BT", "Monitoring stopped")
    }
    
    // MARK: - IOKit HID Manager
    
    private func startHIDManager() {
        stopHIDManager()
        
        logger.info("HID", "Starting keyboard monitoring via IOKit HID Manager...")
        
        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        
        guard let manager = hidManager else {
            logger.error("HID", "Failed to create IOHIDManager")
            lastError = "Failed to create HID Manager"
            return
        }
        
        // Match keyboard devices (usage page: Generic Desktop, usage: Keyboard)
        let matchingDict: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard
        ]
        IOHIDManagerSetDeviceMatching(manager, matchingDict as CFDictionary)
        
        // Register input value callback for key events
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, sender, value in
            guard let context = context else { return }
            let mySelf = Unmanaged<BluetoothMonitor>.fromOpaque(context).takeUnretainedValue()
            
            let element = IOHIDValueGetElement(value)
            let usagePage = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            let intValue = IOHIDValueGetIntegerValue(value)
            
            // Only react to key-down events on the Keyboard/Keypad usage page
            if usagePage == kHIDPage_KeyboardOrKeypad && usage >= 4 && usage <= 231 && intValue == 1 {
                mySelf.handleGlobalKeyEvent()
            }
        }, context)
        
        // Schedule on main run loop
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult == kIOReturnSuccess {
            logger.info("HID", "IOKit HID Manager started successfully. Waiting for keystrokes...")
        } else {
            logger.error("HID", "Failed to open IOHIDManager (code: \(openResult)). Grant Input Monitoring permission in System Settings > Privacy & Security > Input Monitoring.")
            lastError = "Failed to open HID Manager. Grant Input Monitoring permission."
            hidManager = nil
        }
    }
    
    private func stopHIDManager() {
        if let manager = hidManager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            hidManager = nil
            logger.info("HID", "IOKit HID Manager stopped")
        }
    }
    
    // MARK: - Health Check
    
    private func startHealthCheckTimer() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.performHealthCheck()
        }
        if let timer = healthCheckTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
        logger.info("HID", "Health check timer started (30s interval)")
    }
    
    private func performHealthCheck() {
        guard isMonitoring else { return }
        let timeSinceLastActivity = Date().timeIntervalSince(lastHIDActivity)
        logger.debug("HID", "Health check: last activity \(Int(timeSinceLastActivity))s ago, manager: \(hidManager != nil ? "active" : "nil")")
        
        if hidManager == nil {
            logger.warning("HID", "Health check: HID Manager is nil, restarting...")
            startHIDManager()
            return
        }
        
        if timeSinceLastActivity > 300 {
            logger.warning("HID", "Health check: No activity for \(Int(timeSinceLastActivity))s, restarting...")
            stopHIDManager()
            startHIDManager()
        }
    }
    
    // MARK: - Event Handling
    
    private func handleGlobalKeyEvent() {
        lastHIDActivity = Date()
        AppLogger.shared.recordHIDEvent()
        
        let now = Date()
        let deviceName = "Global Keyboard"
        
        let lastActivity = lastKeyboardActivity[deviceName] ?? Date.distantPast
        let timeSinceLastActivity = now.timeIntervalSince(lastActivity)
        
        guard timeSinceLastActivity > 0.5 else { return }
        
        lastKeyboardActivity[deviceName] = now
        logger.debug("HID", "Keystroke detected")
        
        let simulatedKeyboard = BluetoothKeyboardInfo(
            id: "global_keyboard",
            name: "Active Keyboard"
        )
        
        let isReactivation = timeSinceLastActivity > 5.0
        var shouldTrigger = false
        var reason = ""
        
        if lastActiveKeyboard?.id != simulatedKeyboard.id {
            shouldTrigger = true
            reason = "initial keyboard activation"
        } else if isReactivation {
            let lastSwitchTime = lastSwitchEventTime[simulatedKeyboard.id] ?? Date.distantPast
            let timeSinceLastSwitch = now.timeIntervalSince(lastSwitchTime)
            
            if timeSinceLastSwitch >= switchEventCooldown {
                shouldTrigger = true
                reason = "reactivation after \(Int(timeSinceLastActivity))s"
            } else {
                logger.debug("HID", "Keyboard reactivation skipped (cooldown: \(Int(switchEventCooldown - timeSinceLastSwitch))s remaining)")
            }
        }
        
        if shouldTrigger {
            logger.info("HID", "Keyboard active: \(simulatedKeyboard.name) (\(reason))")
            lastSwitchEventTime[simulatedKeyboard.id] = now
            
            DispatchQueue.main.async {
                self.lastActiveKeyboard = simulatedKeyboard
                self.keyboardBecameActivePublisher.send(simulatedKeyboard)
                
                NotificationCenter.default.post(
                    name: .bluetoothKeyboardBecameActive,
                    object: self,
                    userInfo: ["keyboard": simulatedKeyboard]
                )
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let bluetoothKeyboardBecameActive = Notification.Name("bluetoothKeyboardBecameActive")
}
