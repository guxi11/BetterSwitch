//
//  BetterSwitchApp.swift
//  BetterSwitch
//
//  Created by zhangyuanyuan on 2026/3/16.
//

import SwiftUI
import SwiftData
import Combine
import IOBluetooth

@main
struct BetterSwitchApp: App {
    @State private var appState = AppState()
    @State private var ddcManager = DDCManager()
    @StateObject private var bluetoothMonitor = BluetoothMonitor()
    @State private var inputSwitchService: InputSwitchService?
    @State private var isInitialized = false
    
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            BluetoothKeyboard.self,
            Monitor.self,
            InputMapping.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        // Menu bar app - primary interface
        MenuBarExtra("BetterSwitch", systemImage: "keyboard.badge.ellipsis") {
            MenuBarView()
                .environment(appState)
                .environment(ddcManager)
                .modelContainer(sharedModelContainer)
                .task {
                    await initializeServicesIfNeeded()
                }
        }
        .menuBarExtraStyle(.menu)
        
        // Settings window - opens from menu bar
        Settings {
            SettingsView()
                .environment(appState)
                .environment(ddcManager)
                .environmentObject(bluetoothMonitor)
                .modelContainer(sharedModelContainer)
        }
    }
    
    @MainActor
    private func initializeServicesIfNeeded() async {
        guard !isInitialized else { return }
        isInitialized = true
        
        // Wire up AppState to DDCManager
        appState.ddcManager = ddcManager
        
        // Enumerate displays
        ddcManager.enumerateDisplays()
        
        // Update app state with detected monitors
        for displayInfo in ddcManager.monitors {
            let monitor = Monitor(
                displayID: displayInfo.displayID,
                name: displayInfo.name,
                supportsDDC: displayInfo.supportsDDC
            )
            appState.detectedMonitors.append(monitor)
        }
        
        // Create InputSwitchService with model context
        let context = sharedModelContainer.mainContext
        let service = InputSwitchService(
            bluetoothMonitor: bluetoothMonitor,
            ddcManager: ddcManager,
            modelContext: context
        )
        inputSwitchService = service
        
        // Start the input switch service (this also starts bluetooth monitoring)
        service.start()
        
        print("[BetterSwitchApp] Services initialized and started")
    }
}
