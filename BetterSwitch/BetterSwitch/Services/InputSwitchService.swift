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
    
    /// Manually trigger input switch (ignores keyboard ID)
    func triggerSwitch(for keyboardIdentifier: String? = nil) {
        Task { @MainActor in
            await performSwitch()
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
    }
    
    private func loadSettings() {
        isEnabled = AppSettings.shared.isEnabled
    }
    
    private func handleKeyboardBecameActive(_ keyboard: BluetoothKeyboardInfo) {
        logger.info("Switch", "Keyboard became active (Global Input detected)")
        
        guard isEnabled else {
            logger.warning("Switch", "Service disabled, skipping switch")
            return
        }
        
        // Perform switch immediately (no delay)
        Task { @MainActor in
            await performSwitch()
        }
    }
    
    @MainActor
    private func performSwitch() async {
        // Enumerate displays just in case they changed
        ddcManager.enumerateDisplays()
        
        // Load simple mapping from UserDefaults
        guard let mapping = loadSimpleMapping() else {
            lastError = "未配置映射"
            logger.error("Switch", "No mapping configured")
            return
        }
        
        logger.debug("Switch", "Mapping loaded: port code \(mapping.portCode)")
        
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
                keyboard: "Active Keyboard",
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
                        "keyboard": "Active Keyboard",
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
    
    private func showNotification(title: String, body: String) {
        // Use UserNotifications framework for system notifications
        // This is a simplified implementation
        #if DEBUG
        print("Notification: \(title) - \(body)")
        #endif
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
