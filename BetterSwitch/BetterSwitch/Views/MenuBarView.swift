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
    
    var body: some View {
        // Quick switch buttons
        ForEach(InputSource.commonInputs) { input in
            Button(input.name) {
                switchToInput(input.code)
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
