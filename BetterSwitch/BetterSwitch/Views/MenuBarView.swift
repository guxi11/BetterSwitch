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
    
    // Use customPorts from AppStorage to match Settings page
    @AppStorage("customPorts") private var customPortsData: Data = Data()
    
    private var ports: [EditablePort] {
        if let decoded = try? JSONDecoder().decode([EditablePort].self, from: customPortsData),
           !decoded.isEmpty {
            return decoded
        }
        // Fallback to default ports
        return InputSource.commonInputs.map { EditablePort(code: $0.code, name: $0.name) }
    }
    
    var body: some View {
        // Quick switch buttons
        ForEach(ports) { port in
            Button(port.name) {
                switchToInput(port.code)
            }
        }
        
        Divider()
        
        SettingsLink {
            Text("Settings...")
        }
        .keyboardShortcut(",", modifiers: .command)
        
        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
    
    private func switchToInput(_ code: UInt8) {
        let monitors = ddcManager.monitors
        
        if monitors.isEmpty {
            ddcManager.enumerateDisplays()
        }
        
        for monitor in ddcManager.monitors {
            _ = ddcManager.setInputSource(code, for: monitor.displayID)
        }
    }
}

#Preview {
    MenuBarView()
        .environment(AppState())
        .environment(DDCManager())
}
