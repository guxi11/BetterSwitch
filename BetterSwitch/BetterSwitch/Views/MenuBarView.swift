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
    
    @State private var showLogWindow = false
    
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
        
        Button("View Logs...") {
            openLogWindow()
        }
        .keyboardShortcut("l", modifiers: .command)
        
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
    
    private func openLogWindow() {
        // Create a new window for logs
        let logWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        logWindow.title = "BetterSwitch Logs"
        logWindow.center()
        logWindow.isReleasedWhenClosed = false
        
        // Render the extremely simple LogView directly without complex environment injections
        logWindow.contentView = NSHostingView(rootView: LogView())
        
        logWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

#Preview {
    MenuBarView()
        .environment(AppState())
        .environment(DDCManager())
}
