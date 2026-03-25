//
//  BluetoothMonitor.swift
//  BetterSwitch
//
//  Created by zhangyuanyuan on 2026/3/16.
//

import Foundation
import Combine
import AppKit

/// Simple struct to hold keyboard info (thread-safe)
struct BluetoothKeyboardInfo: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    
    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Monitors global keyboard activity
final class BluetoothMonitor: ObservableObject {
    
    /// Last active keyboard (most recently used)
    @Published private(set) var lastActiveKeyboard: BluetoothKeyboardInfo?
    
    /// Last error message
    @Published private(set) var lastError: String?
    
    /// Whether monitoring is active
    @Published private(set) var isMonitoring: Bool = false
    
    // MARK: - Publishers
    
    let keyboardBecameActivePublisher = PassthroughSubject<BluetoothKeyboardInfo, Never>()
    
    // Global event monitor (CGEventTap)
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
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
    
    // Workspace and display observers
    private var workspaceObserver: NSObjectProtocol?
    private var screenParamsObserver: NSObjectProtocol?
    
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
    
    private var restartWorkItem: DispatchWorkItem?
    
    // MARK: - Workspace Observers (Sleep/Wake handling)
    
    private func setupWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.logger.info("System", "Mac woke from sleep. Restarting HID monitoring...")
            self?.restartHIDMonitoringWithDelay()
        }
        
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.logger.info("System", "Screen parameters changed (e.g. Monitor switched input). Restarting HID monitoring...")
            self?.restartHIDMonitoringWithDelay()
        }
    }
    
    private func restartHIDMonitoringWithDelay() {
        if isMonitoring {
            // Cancel any pending restart
            restartWorkItem?.cancel()
            
            stopHIDMonitoring()
            
            // Create a new work item with a longer delay
            let workItem = DispatchWorkItem { [weak self] in
                self?.startHIDMonitoring()
            }
            restartWorkItem = workItem
            
            // 5 seconds delay to allow DDC/CI switch to complete and system to settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)
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
            
            // Start Global Keyboard monitoring
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
    
    // MARK: - Global Keyboard Monitoring (CGEventTap)
    
    private func startHIDMonitoring() {
        logger.info("HID", "Starting Global Keyboard monitoring via CGEventTap...")
        
        // Stop existing monitor if any
        stopHIDMonitoring()
        
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        
        // Use an unmanaged reference to pass self into the C-callback
        let context = Unmanaged.passUnretained(self).toOpaque()
        
        // The callback function must not capture any context
        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            if let refcon = refcon {
                let mySelf = Unmanaged<BluetoothMonitor>.fromOpaque(refcon).takeUnretainedValue()
                
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    mySelf.logger.warning("HID", "CGEventTap disabled by system, attempting to re-enable...")
                    if let tap = mySelf.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                } else if type == .keyDown {
                    mySelf.handleGlobalKeyEvent()
                }
            }
            return Unmanaged.passRetained(event)
        }
        
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: context
        )
        
        guard let tap = eventTap else {
            logger.error("HID", "Failed to create CGEventTap. Ensure Accessibility permissions are granted.")
            return
        }
        
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            logger.info("HID", "CGEventTap started successfully. Waiting for keystrokes...")
        } else {
            logger.error("HID", "Failed to create CFRunLoopSource for CGEventTap.")
        }
    }
    
    private func stopHIDMonitoring() {
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let tap = eventTap {
            logger.info("HID", "Stopping Global Keyboard monitoring (CGEventTap)...")
            CGEvent.tapEnable(tap: tap, enable: false)
            self.eventTap = nil
            logger.info("HID", "Global Keyboard monitoring stopped")
        }
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
        
        logger.debug("HID", "Health check: last activity \(Int(timeSinceLastActivity))s ago, monitor: \(eventTap != nil ? "active" : "nil")")
        
        // Check if event monitor is still valid
        if eventTap == nil {
            logger.warning("HID", "Health check: Event tap is nil, restarting...")
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
    
    private func handleGlobalKeyEvent() {
        // Update last activity for health check
        lastHIDActivity = Date()
        
        // Record event for statistics
        AppLogger.shared.recordHIDEvent()
        
        let now = Date()
        
        // Since we can't identify the hardware source with NSEvent, 
        // we treat all keyboard input as coming from a generic "Active Keyboard"
        let deviceName = "Global Keyboard"
        
        let lastActivity = lastKeyboardActivity[deviceName] ?? Date.distantPast
        let timeSinceLastActivity = now.timeIntervalSince(lastActivity)
        
        // Debounce: only process if more than 0.5 second since last activity
        guard timeSinceLastActivity > 0.5 else {
            return
        }
        
        lastKeyboardActivity[deviceName] = now
        logger.debug("HID", "Keystroke detected")
        
        // We simulate a generic keyboard since we don't know the exact device
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
