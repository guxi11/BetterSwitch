//
//  MenuBarView.swift
//  BetterSwitch
//
//  Created by zhangyuanyuan on 2026/3/16.
//

import SwiftUI
import SwiftData

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(DDCManager.self) private var ddcManager
    @Environment(\.modelContext) private var modelContext
    @Query private var mappings: [InputMapping]
    @Query private var keyboards: [BluetoothKeyboard]
    
    var body: some View {
        // Status section
        Section {
            if ddcManager.monitors.isEmpty {
                Label("No monitors detected", systemImage: "display")
                    .foregroundStyle(.secondary)
            } else {
                Label("\(ddcManager.monitors.count) monitor(s)", systemImage: "display")
            }
            
            if let error = appState.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        
        Divider()
        
        // Switch by Keyboard - shows keyboards with mappings
        if !keyboardsWithMappings.isEmpty {
            Section("Switch by Keyboard") {
                ForEach(keyboardsWithMappings, id: \.identifier) { keyboard in
                    Button {
                        switchForKeyboard(keyboard)
                    } label: {
                        Label(keyboard.name, systemImage: "keyboard")
                    }
                }
            }
            
            Divider()
        }
        
        // Quick switch buttons
        Section("Quick Switch Input") {
            ForEach(InputSource.commonInputs) { input in
                Button {
                    switchToInput(input.code)
                } label: {
                    Text(input.name)
                }
            }
        }
        
        Divider()
        
        // App controls
        Section {
            @Bindable var state = appState
            Toggle("Enable Auto-Switch", isOn: $state.isEnabled)
            
            Button("Detect Monitors") {
                ddcManager.enumerateDisplays()
            }
            
            SettingsLink {
                Label("Settings...", systemImage: "gear")
            }
            .keyboardShortcut(",", modifiers: .command)
            
            Divider()
            
            Button("Quit BetterSwitch") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
    
    // Get keyboards that have at least one mapping
    private var keyboardsWithMappings: [BluetoothKeyboard] {
        let keyboardIDs = Set(mappings.compactMap { $0.keyboard?.identifier })
        return keyboards.filter { keyboardIDs.contains($0.identifier) }
    }
    
    private func switchForKeyboard(_ keyboard: BluetoothKeyboard) {
        // Find all mappings for this keyboard
        let keyboardMappings = mappings.filter { $0.keyboard?.identifier == keyboard.identifier && $0.isEnabled }
        
        if keyboardMappings.isEmpty {
            appState.lastError = "No mappings for \(keyboard.name)"
            return
        }
        
        var anySuccess = false
        for mapping in keyboardMappings {
            guard let monitor = mapping.monitor else { continue }
            
            if ddcManager.setInputSource(mapping.inputSourceCode, for: monitor.displayID) {
                anySuccess = true
                let inputName = InputSource.allInputs.first { $0.code == mapping.inputSourceCode }?.name ?? "Input \(mapping.inputSourceCode)"
                print("[MenuBar] Switched \(monitor.name) to \(inputName) for \(keyboard.name)")
            }
        }
        
        if anySuccess {
            appState.lastError = nil
        } else {
            appState.lastError = "Failed to switch for \(keyboard.name)"
        }
    }
    
    private func switchToInput(_ code: UInt8) {
        let monitors = ddcManager.monitors
        
        if monitors.isEmpty {
            appState.lastError = "No monitors detected. Click 'Detect Monitors' first."
            return
        }
        
        var anySuccess = false
        for monitor in monitors {
            if ddcManager.setInputSource(code, for: monitor.displayID) {
                anySuccess = true
            }
        }
        
        if anySuccess {
            appState.lastError = nil
        } else {
            appState.lastError = ddcManager.lastError ?? "Failed to switch input"
        }
    }
}

#Preview {
    MenuBarView()
        .environment(AppState())
        .environment(DDCManager())
        .modelContainer(for: [BluetoothKeyboard.self, Monitor.self, InputMapping.self], inMemory: true)
}
