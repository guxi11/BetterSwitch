//
//  InputSwitchService.swift
//  BetterSwitch
//
//  Created by zhangyuanyuan on 2026/3/16.
//

import Foundation
import SwiftData
import IOBluetooth
import Combine

/// Orchestrates automatic input switching based on keyboard connections
@Observable
final class InputSwitchService {
    /// Whether automatic switching is enabled
    var isEnabled: Bool = true
    
    /// Last switch action performed
    private(set) var lastAction: SwitchAction?
    
    /// Last error message
    private(set) var lastError: String?
    
    // MARK: - Private Properties
    
    private let bluetoothMonitor: BluetoothMonitor
    private let ddcManager: DDCManager
    private let modelContext: ModelContext
    private let logger = AppLogger.shared
    
    private var cancellables = Set<AnyCancellable>()
    
    /// Represents a switch action
    struct SwitchAction {
        let keyboard: String
        let monitor: String
        let input: String
        let timestamp: Date
        let success: Bool
    }
    
    // MARK: - Initialization
    
    init(bluetoothMonitor: BluetoothMonitor, ddcManager: DDCManager, modelContext: ModelContext) {
        self.bluetoothMonitor = bluetoothMonitor
        self.ddcManager = ddcManager
        self.modelContext = modelContext
        
        logger.info("Switch", "InputSwitchService initialized")
        setupSubscriptions()
    }
    
    // MARK: - Public Methods
    
    /// Start the input switch service
    func start() {
        bluetoothMonitor.startMonitoring()
        ddcManager.enumerateDisplays()
        loadSettings()
    }
    
    /// Stop the input switch service
    func stop() {
        bluetoothMonitor.stopMonitoring()
    }
    
    /// Manually trigger input switch for a keyboard
    func triggerSwitch(for keyboardIdentifier: String) {
        Task { @MainActor in
            await performSwitch(for: keyboardIdentifier)
        }
    }
    
    // MARK: - Private Methods
    
    private func setupSubscriptions() {
        // Subscribe to keyboard activity events (when user types on a keyboard)
        bluetoothMonitor.keyboardBecameActivePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] keyboard in
                self?.handleKeyboardBecameActive(keyboard)
            }
            .store(in: &cancellables)
        
        // Subscribe to keyboard connection events
        bluetoothMonitor.keyboardConnectedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] keyboard in
                self?.handleKeyboardConnected(keyboard)
            }
            .store(in: &cancellables)
        
        // Subscribe to keyboard disconnection events
        bluetoothMonitor.keyboardDisconnectedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] keyboard in
                self?.handleKeyboardDisconnected(keyboard)
            }
            .store(in: &cancellables)
    }
    
    private func loadSettings() {
        isEnabled = AppSettings.shared.isEnabled
    }
    
    private func handleKeyboardBecameActive(_ keyboard: BluetoothKeyboardInfo) {
        logger.info("Switch", "Keyboard became active: \(keyboard.name) (id: \(keyboard.id))")
        
        guard isEnabled else {
            logger.warning("Switch", "Service disabled, skipping switch")
            return
        }
        
        // Perform switch immediately (no delay)
        Task { @MainActor in
            await performSwitch(for: keyboard.id)
        }
    }
    
    private func handleKeyboardConnected(_ keyboard: BluetoothKeyboardInfo) {
        // Connection events are handled but activity-based switching is preferred
    }
    
    private func handleKeyboardDisconnected(_ keyboard: BluetoothKeyboardInfo) {
        // Optionally: could implement "switch back" on disconnect
    }
    
    @MainActor
    private func performSwitch(for keyboardIdentifier: String) async {
        logger.info("Switch", "Performing switch for keyboard: \(keyboardIdentifier)")
        
        // Load simple mapping from UserDefaults
        guard let mapping = loadSimpleMapping() else {
            lastError = "未配置映射"
            logger.error("Switch", "No mapping configured")
            return
        }
        
        logger.debug("Switch", "Mapping loaded: port code \(mapping.portCode)")
        
        // Check if the active keyboard matches the registered keyboard
        guard let registeredKeyboard = fetchRegisteredKeyboard() else {
            logger.warning("Switch", "No registered keyboard found")
            return
        }
        
        logger.debug("Switch", "Registered keyboard: \(registeredKeyboard.name) (id: \(registeredKeyboard.identifier))")
        
        guard registeredKeyboard.identifier == keyboardIdentifier else {
            logger.info("Switch", "Keyboard ID mismatch: registered=\(registeredKeyboard.identifier), active=\(keyboardIdentifier)")
            return
        }
        
        // Get all monitors
        let monitors = ddcManager.monitors
        guard !monitors.isEmpty else {
            lastError = "未检测到显示器"
            logger.error("Switch", "No monitors detected")
            return
        }
        
        logger.info("Switch", "Switching \(monitors.count) monitor(s) to input \(mapping.portCode)")
        
        var anySuccess = false
        
        for monitor in monitors {
            let success = ddcManager.setInputSource(mapping.portCode, for: monitor.displayID)
            
            // Record switch attempt
            AppLogger.shared.recordSwitchAttempt(success: success)
            
            let inputName = InputSource.allInputs.first { $0.code == mapping.portCode }?.name ?? "Input \(mapping.portCode)"
            
            lastAction = SwitchAction(
                keyboard: registeredKeyboard.name,
                monitor: monitor.name,
                input: inputName,
                timestamp: Date(),
                success: success
            )
            
            if success {
                anySuccess = true
                lastError = nil
                logger.info("Switch", "Successfully switched \(monitor.name) to \(inputName)")
                
                // Post notification for UI updates
                NotificationCenter.default.post(
                    name: .inputSwitchPerformed,
                    object: self,
                    userInfo: [
                        "keyboard": registeredKeyboard.name,
                        "monitor": monitor.name,
                        "input": inputName
                    ]
                )
                
                // Show user notification if enabled
                if AppSettings.shared.showNotifications {
                    showNotification(
                        title: "Input Switched",
                        body: "\(monitor.name) switched to \(inputName)"
                    )
                }
            } else {
                lastError = "Failed to switch \(monitor.name) to \(inputName)"
                logger.error("Switch", "Failed to switch \(monitor.name) to \(inputName)")
            }
        }
        
        if !anySuccess {
            lastError = "所有显示器切换失败"
            logger.error("Switch", "All monitor switches failed")
        }
    }
    
    private func loadSimpleMapping() -> SimpleMapping? {
        guard let data = UserDefaults.standard.data(forKey: "simpleMapping"),
              let mapping = try? JSONDecoder().decode(SimpleMapping.self, from: data) else {
            return nil
        }
        return mapping
    }
    
    private func fetchRegisteredKeyboard() -> BluetoothKeyboard? {
        let descriptor = FetchDescriptor<BluetoothKeyboard>()
        return try? modelContext.fetch(descriptor).first
    }
    
    private func showNotification(title: String, body: String) {
        // Use UserNotifications framework for system notifications
        // This is a simplified implementation
        #if DEBUG
        print("Notification: \(title) - \(body)")
        #endif
    }
    
    /// Register a new keyboard from BluetoothKeyboardInfo
    func registerKeyboard(_ info: BluetoothKeyboardInfo) -> BluetoothKeyboard {
        // Check if keyboard already exists
        let identifier = info.id
        let descriptor = FetchDescriptor<BluetoothKeyboard>(
            predicate: #Predicate { $0.identifier == identifier }
        )
        
        if let existing = try? modelContext.fetch(descriptor).first {
            // Update last seen
            existing.lastSeen = Date()
            return existing
        }
        
        // Create new keyboard entry
        let keyboard = BluetoothKeyboard(
            identifier: identifier,
            name: info.name,
            isTracked: true,
            lastSeen: Date()
        )
        modelContext.insert(keyboard)
        
        return keyboard
    }
}

// MARK: - Simple Mapping Structure

struct SimpleMapping: Codable {
    let portCode: UInt8
}

// MARK: - Notification Names

extension Notification.Name {
    static let inputSwitchPerformed = Notification.Name("inputSwitchPerformed")
}
