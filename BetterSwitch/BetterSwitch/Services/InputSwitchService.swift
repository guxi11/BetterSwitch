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
    
    /// Delay before switching (allows for keyboard reconnection settling)
    var switchDelay: TimeInterval = 0.5
    
    /// Last switch action performed
    private(set) var lastAction: SwitchAction?
    
    /// Last error message
    private(set) var lastError: String?
    
    // MARK: - Private Properties
    
    private let bluetoothMonitor: BluetoothMonitor
    private let ddcManager: DDCManager
    private let modelContext: ModelContext
    
    private var cancellables = Set<AnyCancellable>()
    private var pendingSwitchTask: Task<Void, Never>?
    
    /// Track the last keyboard that triggered a successful switch (to avoid redundant switches)
    private var lastSwitchedKeyboardId: String?
    
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
        
        setupSubscriptions()
    }
    
    deinit {
        pendingSwitchTask?.cancel()
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
        pendingSwitchTask?.cancel()
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
        switchDelay = AppSettings.shared.switchDelay
    }
    
    private func handleKeyboardBecameActive(_ keyboard: BluetoothKeyboardInfo) {
        guard isEnabled else { return }
        
        let identifier = keyboard.id
        
        // Skip if this keyboard already triggered the last successful switch
        if lastSwitchedKeyboardId == identifier {
            print("[InputSwitchService] Keyboard \(keyboard.name) already active, skipping redundant switch")
            return
        }
        
        print("[InputSwitchService] Keyboard became active: \(keyboard.name)")
        
        // Cancel any pending switch
        pendingSwitchTask?.cancel()
        
        // Schedule switch with delay
        pendingSwitchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(switchDelay * 1_000_000_000))
            
            guard !Task.isCancelled else { return }
            
            await performSwitch(for: identifier)
        }
    }
    
    private func handleKeyboardConnected(_ keyboard: BluetoothKeyboardInfo) {
        print("[InputSwitchService] Keyboard connected: \(keyboard.name)")
        // Connection events are handled but activity-based switching is preferred
    }
    
    private func handleKeyboardDisconnected(_ keyboard: BluetoothKeyboardInfo) {
        // Cancel any pending switch for this keyboard
        pendingSwitchTask?.cancel()
        
        // Optionally: could implement "switch back" on disconnect
    }
    
    @MainActor
    private func performSwitch(for keyboardIdentifier: String) async {
        // Find mapping for this keyboard
        let descriptor = FetchDescriptor<InputMapping>(
            predicate: #Predicate { mapping in
                mapping.keyboard?.identifier == keyboardIdentifier &&
                mapping.isEnabled == true
            }
        )
        
        do {
            let mappings = try modelContext.fetch(descriptor)
            
            guard !mappings.isEmpty else {
                // No mapping configured for this keyboard
                lastError = "No mapping found for keyboard"
                return
            }
            
            for mapping in mappings {
                guard let monitor = mapping.monitor else { continue }
                
                // Find the actual display by name (displayID may change between sessions)
                guard let actualDisplay = ddcManager.monitors.first(where: { $0.name == monitor.name }) else {
                    print("[InputSwitchService] Monitor not found: \(monitor.name)")
                    lastError = "Monitor not found: \(monitor.name)"
                    continue
                }
                
                // Perform the switch using the current displayID
                let success = ddcManager.setInputSource(mapping.inputSourceCode, for: actualDisplay.displayID)
                
                let inputName = InputSource.allInputs.first { $0.code == mapping.inputSourceCode }?.name ?? "Input \(mapping.inputSourceCode)"
                
                lastAction = SwitchAction(
                    keyboard: mapping.keyboard?.name ?? "Unknown",
                    monitor: monitor.name,
                    input: inputName,
                    timestamp: Date(),
                    success: success
                )
                
                if success {
                    lastError = nil
                    
                    // Track this keyboard as the last one that triggered a switch
                    lastSwitchedKeyboardId = keyboardIdentifier
                    
                    // Post notification for UI updates
                    NotificationCenter.default.post(
                        name: .inputSwitchPerformed,
                        object: self,
                        userInfo: [
                            "keyboard": mapping.keyboard?.name ?? "Unknown",
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
                }
            }
        } catch {
            lastError = "Failed to fetch mappings: \(error.localizedDescription)"
        }
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

// MARK: - Notification Names

extension Notification.Name {
    static let inputSwitchPerformed = Notification.Name("inputSwitchPerformed")
}
