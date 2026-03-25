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

// App Delegate to handle app lifecycle
class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState!
    var ddcManager: DDCManager!
    var bluetoothMonitor: BluetoothMonitor!
    var inputSwitchService: InputSwitchService!
    var modelContainer: ModelContainer!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 测试日志系统
        print("=== App launching, testing logger ===")
        print("Logger entries count before: \(AppLogger.shared.entries.count)")
        
        AppLogger.shared.info("App", "=== BetterSwitch Starting ===")
        AppLogger.shared.info("App", "Test log 1")
        AppLogger.shared.info("App", "Test log 2")
        AppLogger.shared.debug("App", "Debug test")
        
        print("Logger entries count after: \(AppLogger.shared.entries.count)")
        for entry in AppLogger.shared.entries {
            print("  Entry: [\(entry.category)] \(entry.message)")
        }
        
        initializeServices()
    }
    
    @MainActor func initializeServices() {
        AppLogger.shared.info("App", "Initializing services...")
        
        // Create model container
        let schema = Schema([
            BluetoothKeyboard.self,
            Monitor.self,
            InputMapping.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
            AppLogger.shared.info("App", "Model container created")
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
        
        // Initialize managers
        appState = AppState()
        ddcManager = DDCManager()
        bluetoothMonitor = BluetoothMonitor()
        
        AppLogger.shared.info("App", "Managers initialized")
        
        // Wire up AppState to DDCManager
        appState.ddcManager = ddcManager
        
        // Enumerate displays
        ddcManager.enumerateDisplays()
        AppLogger.shared.info("App", "Found \(ddcManager.monitors.count) monitor(s)")
        
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
        let context = modelContainer.mainContext
        inputSwitchService = InputSwitchService(
            bluetoothMonitor: bluetoothMonitor,
            ddcManager: ddcManager,
            modelContext: context
        )
        
        // Start the input switch service (this also starts bluetooth monitoring)
        inputSwitchService.start()
        
        AppLogger.shared.info("App", "Services started successfully")
        print("[BetterSwitch] Started with \(ddcManager.monitors.count) monitor(s)")
    }
}

@main
struct BetterSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar app - primary interface
        MenuBarExtra("BetterSwitch", systemImage: "keyboard.badge.ellipsis") {
            MenuBarView()
                .environment(appDelegate.appState ?? AppState())
                .environment(appDelegate.ddcManager ?? DDCManager())
                .modelContainer(appDelegate.modelContainer ?? createFallbackContainer())
        }
        .menuBarExtraStyle(.menu)
        
        // Settings window - opens from menu bar
        Settings {
            SettingsView()
                .environment(appDelegate.appState ?? AppState())
                .environment(appDelegate.ddcManager ?? DDCManager())
                .environmentObject(appDelegate.bluetoothMonitor ?? BluetoothMonitor())
                .modelContainer(appDelegate.modelContainer ?? createFallbackContainer())
        }
    }
    
    private func createFallbackContainer() -> ModelContainer {
        let schema = Schema([
            BluetoothKeyboard.self,
            Monitor.self,
            InputMapping.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: [modelConfiguration])
    }
}
