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

/// Monitors global keyboard activity using NSEvent global monitor
/// This approach only requires Input Monitoring permission, NOT Accessibility.
final class BluetoothMonitor: ObservableObject {
    
    /// Last active keyboard (most recently used)
    @Published private(set) var lastActiveKeyboard: BluetoothKeyboardInfo?
    
    /// Last error message
    @Published private(set) var lastError: String?
    
    /// Whether monitoring is active
    @Published private(set) var isMonitoring: Bool = false
    
    // MARK: - Publishers
    
    let keyboardBecameActivePublisher = PassthroughSubject<BluetoothKeyboardInfo, Never>()
    
    // NSEvent global monitor handle
    private var globalMonitor: Any?
    private var lastKeyboardActivity: [String: Date] = [:]
    
    // Track when we last sent a switch event for each keyboard
    private var lastSwitchEventTime: [String: Date] = [:]
    
    // Health check timer
    private var healthCheckTimer: Timer?
    private var lastHIDActivity: Date = Date()
    
    private let switchEventCooldown: TimeInterval = 30.0
    private let logger = AppLogger.shared
    
    // Workspace and display observers
    private var workspaceObserver: NSObjectProtocol?
    private var screenParamsObserver: NSObjectProtocol?
    private var restartWorkItem: DispatchWorkItem?
    
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
    
    // MARK: - Workspace Observers (Sleep/Wake handling)
    
    private func setupWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.logger.info("System", "Mac woke from sleep. Restarting monitoring...")
            self?.restartMonitoringWithDelay()
        }
        
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.logger.info("System", "Screen parameters changed. Restarting monitoring...")
            self?.restartMonitoringWithDelay()
        }
    }
    
    private func restartMonitoringWithDelay() {
        guard isMonitoring else { return }
        
        // Cancel any pending restart
        restartWorkItem?.cancel()
        
        stopGlobalMonitor()
        
        let workItem = DispatchWorkItem { [weak self] in
            self?.startGlobalMonitor()
        }
        restartWorkItem = workItem
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)
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
        
        startGlobalMonitor()
        startHealthCheckTimer()
        
        logger.info("BT", "Monitoring started successfully")
    }
    
    func stopMonitoring() {
        logger.info("BT", "Stopping monitoring...")
        
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        restartWorkItem?.cancel()
        restartWorkItem = nil
        stopGlobalMonitor()
        isMonitoring = false
        
        logger.info("BT", "Monitoring stopped")
    }
    
    // MARK: - NSEvent Global Monitor (no Accessibility permission needed)
    
    private func startGlobalMonitor() {
        // Stop existing monitor if any
        stopGlobalMonitor()
        
        logger.info("HID", "Starting keyboard monitoring via NSEvent.addGlobalMonitorForEvents...")
        
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleGlobalKeyEvent()
        }
        
        if globalMonitor != nil {
            logger.info("HID", "NSEvent global monitor started successfully. Waiting for keystrokes...")
        } else {
            logger.error("HID", "Failed to create NSEvent global monitor. Check Input Monitoring permission in System Settings > Privacy & Security > Input Monitoring.")
            lastError = "Failed to start keyboard monitoring. Grant Input Monitoring permission."
        }
    }
    
    private func stopGlobalMonitor() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
            logger.info("HID", "NSEvent global monitor stopped")
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
        
        logger.debug("HID", "Health check: last activity \(Int(timeSinceLastActivity))s ago, monitor: \(globalMonitor != nil ? "active" : "nil")")
        
        if globalMonitor == nil {
            logger.warning("HID", "Health check: Global monitor is nil, restarting...")
            startGlobalMonitor()
            return
        }
        
        // If no activity for 5 minutes, restart monitoring
        if timeSinceLastActivity > 300 {
            logger.warning("HID", "Health check: No activity for \(Int(timeSinceLastActivity))s, restarting...")
            stopGlobalMonitor()
            startGlobalMonitor()
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
        
        // Debounce: only process if more than 0.5 second since last activity
        guard timeSinceLastActivity > 0.5 else {
            return
        }
        
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
