//
//  SettingsView.swift
//  BetterSwitch
//
//  Created by zhangyuanyuan on 2026/3/16.
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    var body: some View {
        TabView {
            MappingsTab()
                .tabItem { Label("Mappings", systemImage: "arrow.triangle.swap") }
            
            KeyboardsTab()
                .tabItem { Label("Keyboards", systemImage: "keyboard") }
            
            MonitorsTab()
                .tabItem { Label("Monitors", systemImage: "display") }
            
            GeneralTab()
                .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 550, height: 400)
    }
}

// MARK: - Mappings Tab

struct MappingsTab: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var mappings: [InputMapping]
    @Query private var keyboards: [BluetoothKeyboard]
    @Query private var monitors: [Monitor]
    
    @State private var showingAddMapping = false
    
    var body: some View {
        Form {
            Section("Active Mappings") {
                if mappings.isEmpty {
                    Text("No mappings configured")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mappings) { mapping in
                        MappingRow(mapping: mapping)
                    }
                    .onDelete(perform: deleteMappings)
                }
            }
            
            Section {
                Button("Add Mapping") {
                    showingAddMapping = true
                }
                .disabled(keyboards.isEmpty || monitors.isEmpty)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAddMapping) {
            AddMappingSheet()
        }
    }
    
    private func deleteMappings(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(mappings[index])
        }
    }
}

struct MappingRow: View {
    @Bindable var mapping: InputMapping
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(mapping.keyboard?.name ?? "Unknown Keyboard")
                    .font(.headline)
                HStack {
                    Image(systemName: "arrow.right")
                    Text(mapping.monitor?.name ?? "Unknown Monitor")
                    Text(":")
                    Text(mapping.inputSource?.name ?? "Input \(mapping.inputSourceCode)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Toggle("", isOn: $mapping.isEnabled)
                .labelsHidden()
        }
    }
}

struct AddMappingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var keyboards: [BluetoothKeyboard]
    @Query private var monitors: [Monitor]
    
    @State private var selectedKeyboard: BluetoothKeyboard?
    @State private var selectedMonitor: Monitor?
    @State private var selectedInput: InputSource = .hdmi1
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Add Input Mapping")
                .font(.headline)
            
            Form {
                Picker("Keyboard", selection: $selectedKeyboard) {
                    Text("Select Keyboard").tag(nil as BluetoothKeyboard?)
                    ForEach(keyboards) { keyboard in
                        Text(keyboard.name).tag(keyboard as BluetoothKeyboard?)
                    }
                }
                
                Picker("Monitor", selection: $selectedMonitor) {
                    Text("Select Monitor").tag(nil as Monitor?)
                    ForEach(monitors) { monitor in
                        Text(monitor.name).tag(monitor as Monitor?)
                    }
                }
                
                Picker("Input Source", selection: $selectedInput) {
                    ForEach(InputSource.commonInputs) { input in
                        Text(input.name).tag(input)
                    }
                }
            }
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Add") {
                    addMapping()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedKeyboard == nil || selectedMonitor == nil)
            }
            .padding()
        }
        .frame(width: 400, height: 300)
        .padding()
    }
    
    private func addMapping() {
        let mapping = InputMapping(
            keyboard: selectedKeyboard,
            monitor: selectedMonitor,
            inputSourceCode: selectedInput.code
        )
        modelContext.insert(mapping)
        dismiss()
    }
}

// MARK: - Keyboards Tab

struct KeyboardsTab: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var bluetoothMonitor: BluetoothMonitor
    @Query private var keyboards: [BluetoothKeyboard]
    
    var body: some View {
        Form {
            Section("Registered Keyboards") {
                if keyboards.isEmpty {
                    VStack(spacing: 10) {
                        Text("No keyboards registered")
                            .foregroundStyle(.secondary)
                        Text("Click 'Scan for Keyboards' to detect")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    ForEach(keyboards) { keyboard in
                        KeyboardRow(keyboard: keyboard)
                    }
                    .onDelete(perform: deleteKeyboards)
                }
            }
            
            Section("Detected Keyboards") {
                if bluetoothMonitor.isScanning {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Scanning...")
                            .foregroundStyle(.secondary)
                    }
                } else if bluetoothMonitor.pairedKeyboards.isEmpty {
                    Text("No keyboards detected")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(bluetoothMonitor.pairedKeyboards) { keyboard in
                        DetectedKeyboardRow(
                            keyboard: keyboard,
                            isRegistered: keyboards.contains { $0.identifier == keyboard.id },
                            onAdd: { addKeyboard(keyboard) }
                        )
                    }
                }
            }
            
            Section {
                Button("Scan for Keyboards") {
                    bluetoothMonitor.scanForKeyboards()
                }
                .disabled(bluetoothMonitor.isScanning)
            }
        }
        .formStyle(.grouped)
    }
    
    private func deleteKeyboards(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(keyboards[index])
        }
    }
    
    private func addKeyboard(_ info: BluetoothKeyboardInfo) {
        let keyboard = BluetoothKeyboard(
            identifier: info.id,
            name: info.name,
            isTracked: true,
            lastSeen: Date()
        )
        modelContext.insert(keyboard)
    }
}

struct DetectedKeyboardRow: View {
    let keyboard: BluetoothKeyboardInfo
    let isRegistered: Bool
    let onAdd: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                HStack {
                    Text(keyboard.name)
                        .font(.headline)
                    if keyboard.isConnected {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 8))
                    }
                }
                Text(keyboard.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if isRegistered {
                Text("Added")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                Button("Add") {
                    onAdd()
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

struct KeyboardRow: View {
    @Bindable var keyboard: BluetoothKeyboard
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(keyboard.name)
                    .font(.headline)
                Text(keyboard.identifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Toggle("Track", isOn: $keyboard.isTracked)
                .labelsHidden()
        }
    }
}

// MARK: - Monitors Tab

struct MonitorsTab: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(DDCManager.self) private var ddcManager
    @Query private var monitors: [Monitor]
    
    var body: some View {
        Form {
            Section("Detected Monitors") {
                if monitors.isEmpty {
                    VStack(spacing: 10) {
                        Text("No monitors detected")
                            .foregroundStyle(.secondary)
                        Text("Click 'Detect Monitors' to scan")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    ForEach(monitors) { monitor in
                        MonitorRow(monitor: monitor)
                    }
                }
            }
            
            Section("Test DDC/CI") {
                HStack {
                    Text("Quick Switch:")
                    ForEach(InputSource.commonInputs) { input in
                        Button(input.name) {
                            testSwitchInput(input)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            
            Section {
                Button("Detect Monitors") {
                    detectMonitors()
                }
            }
        }
        .formStyle(.grouped)
    }
    
    private func detectMonitors() {
        ddcManager.enumerateDisplays()
        // Sync to SwiftData
        for displayInfo in ddcManager.monitors {
            let existingMonitor = monitors.first { $0.displayID == displayInfo.displayID }
            if existingMonitor == nil {
                let monitor = Monitor(
                    displayID: displayInfo.displayID,
                    name: displayInfo.name,
                    supportsDDC: true
                )
                modelContext.insert(monitor)
            }
        }
    }
    
    private func testSwitchInput(_ input: InputSource) {
        for monitor in ddcManager.monitors {
            _ = ddcManager.setInputSource(input.code, for: monitor.displayID)
        }
    }
}

struct MonitorRow: View {
    let monitor: Monitor
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(monitor.name)
                    .font(.headline)
                HStack {
                    Text("DDC: \(monitor.supportsDDC ? "Supported" : "Not Supported")")
                    Text("ID: \(monitor.displayID)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Image(systemName: monitor.supportsDDC ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(monitor.supportsDDC ? .green : .red)
        }
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @AppStorage("switchDelay") private var switchDelay = 0.5
    @AppStorage("showNotifications") private var showNotifications = true
    
    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LaunchAtLogin.isEnabled = newValue
                    }
                    .onAppear {
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                
                Text("Status: \(LaunchAtLogin.statusDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Section("Behavior") {
                HStack {
                    Text("Switch Delay:")
                    Slider(value: $switchDelay, in: 0...2, step: 0.1)
                    Text("\(switchDelay, specifier: "%.1f")s")
                        .monospacedDigit()
                        .frame(width: 40)
                }
                
                Toggle("Show Notifications", isOn: $showNotifications)
            }
            
            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
        .environment(DDCManager())
        .environmentObject(BluetoothMonitor())
        .modelContainer(for: [BluetoothKeyboard.self, Monitor.self, InputMapping.self], inMemory: true)
}
