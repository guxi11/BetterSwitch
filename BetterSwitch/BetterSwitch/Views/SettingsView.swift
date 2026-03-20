//
//  SettingsView.swift
//  BetterSwitch
//
//  Created by zhangyuanyuan on 2026/3/16.
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(DDCManager.self) private var ddcManager
    @EnvironmentObject private var bluetoothMonitor: BluetoothMonitor
    
    @Query private var keyboards: [BluetoothKeyboard]
    @Query private var monitors: [Monitor]
    
    // 选中的端口
    @State private var selectedPortCode: UInt8? = nil
    // 正在编辑 DDC ID 的端口
    @State private var editingPort: InputSource? = nil
    @State private var editingDDCValue: String = ""
    
    // 自定义端口列表（可编辑DDC ID）
    @AppStorage("customPorts") private var customPortsData: Data = Data()
    
    @State private var customPorts: [EditablePort] = []
    
    var body: some View {
        VStack(spacing: 0) {
            // 主内容
            VStack(spacing: 24) {
                // 显示器区域
                MonitorSection(
                    monitors: ddcManager.monitors,
                    onDetect: detectMonitors
                )
                
                // 连接线
                ConnectionLine()
                
                // 端口区域
                PortsSection(
                    ports: customPorts,
                    selectedPortCode: $selectedPortCode,
                    onSelect: selectPort,
                    onDoubleClick: switchToPort,
                    onEditDDC: { port in
                        editingPort = InputSource(code: port.code, name: port.name)
                        editingDDCValue = String(port.code)
                    }
                )
                
                // 连接线
                ConnectionLine()
                
                // 键盘区域
                KeyboardSection(
                    keyboard: keyboards.first,
                    detectedKeyboards: bluetoothMonitor.pairedKeyboards,
                    isScanning: bluetoothMonitor.isScanning,
                    onScan: { bluetoothMonitor.scanForKeyboards() },
                    onSelect: selectKeyboard
                )
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 24)
            
            Spacer(minLength: 0)
            
            // 底部状态栏
            HStack {
                if let keyboard = keyboards.first {
                    Image(systemName: "keyboard")
                        .foregroundStyle(.green)
                    Text(keyboard.name)
                        .font(.caption)
                } else {
                    Image(systemName: "keyboard")
                        .foregroundStyle(.secondary)
                    Text("未选择键盘")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                if let portCode = selectedPortCode,
                   let port = customPorts.first(where: { $0.code == portCode }) {
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(port.name)
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 400, height: 480)
        .onAppear {
            loadCustomPorts()
            // 加载已保存的选择
            if let mapping = loadMapping() {
                selectedPortCode = mapping.portCode
            }
            // 将窗口置于最前面
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .sheet(item: $editingPort) { port in
            EditDDCSheet(
                portName: port.name,
                currentCode: port.code,
                onSave: { newCode in
                    updatePortCode(oldCode: port.code, newCode: newCode)
                }
            )
        }
    }
    
    // MARK: - Actions
    
    private func detectMonitors() {
        ddcManager.enumerateDisplays()
        // 同步到 SwiftData
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
    
    private func selectPort(_ code: UInt8) {
        selectedPortCode = code
        saveMapping()
    }
    
    private func switchToPort(_ code: UInt8) {
        for monitor in ddcManager.monitors {
            _ = ddcManager.setInputSource(code, for: monitor.displayID)
        }
    }
    
    private func selectKeyboard(_ info: BluetoothKeyboardInfo) {
        // 先删除所有已有键盘
        for keyboard in keyboards {
            modelContext.delete(keyboard)
        }
        // 添加新选择的键盘
        let keyboard = BluetoothKeyboard(
            identifier: info.id,
            name: info.name,
            isTracked: true,
            lastSeen: Date()
        )
        modelContext.insert(keyboard)
        saveMapping()
    }
    
    // MARK: - Persistence
    
    private func loadCustomPorts() {
        if let decoded = try? JSONDecoder().decode([EditablePort].self, from: customPortsData),
           !decoded.isEmpty {
            customPorts = decoded
        } else {
            // 默认端口
            customPorts = InputSource.commonInputs.map { EditablePort(code: $0.code, name: $0.name) }
        }
    }
    
    private func saveCustomPorts() {
        if let encoded = try? JSONEncoder().encode(customPorts) {
            customPortsData = encoded
        }
    }
    
    private func updatePortCode(oldCode: UInt8, newCode: UInt8) {
        if let index = customPorts.firstIndex(where: { $0.code == oldCode }) {
            customPorts[index].code = newCode
            saveCustomPorts()
            // 如果选中的是这个端口，更新选中状态
            if selectedPortCode == oldCode {
                selectedPortCode = newCode
                saveMapping()
            }
        }
    }
    
    private func saveMapping() {
        guard let portCode = selectedPortCode else { return }
        let mapping = SimpleMapping(portCode: portCode)
        if let encoded = try? JSONEncoder().encode(mapping) {
            UserDefaults.standard.set(encoded, forKey: "simpleMapping")
        }
    }
    
    private func loadMapping() -> SimpleMapping? {
        guard let data = UserDefaults.standard.data(forKey: "simpleMapping"),
              let mapping = try? JSONDecoder().decode(SimpleMapping.self, from: data) else {
            return nil
        }
        return mapping
    }
}

// MARK: - Editable Port

struct EditablePort: Codable, Identifiable {
    var id: UInt8 { code }
    var code: UInt8
    var name: String
}

// MARK: - Monitor Section

struct MonitorSection: View {
    let monitors: [DDCManager.DisplayInfo]
    let onDetect: () -> Void
    
    var body: some View {
        VStack(spacing: 8) {
            // 显示器图标
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 120, height: 80)
                    .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                
                RoundedRectangle(cornerRadius: 4)
                    .fill(monitors.isEmpty ? Color(nsColor: .quaternaryLabelColor) : Color.blue.opacity(0.3))
                    .frame(width: 100, height: 60)
                
                if monitors.isEmpty {
                    Image(systemName: "display")
                        .font(.title)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: "display")
                            .font(.title2)
                        Text(monitors.first?.name ?? "Display")
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.primary)
                }
            }
            .onTapGesture {
                if monitors.isEmpty {
                    onDetect()
                }
            }
            
            // 标签
            if monitors.isEmpty {
                VStack(spacing: 4) {
                    Text("未检测到显示器")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("点击检测")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            } else {
                Text(monitors.first?.name ?? "External Display")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
        }
    }
}

// MARK: - Connection Line

struct ConnectionLine: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 2, height: 20)
    }
}

// MARK: - Ports Section

struct PortsSection: View {
    let ports: [EditablePort]
    @Binding var selectedPortCode: UInt8?
    let onSelect: (UInt8) -> Void
    let onDoubleClick: (UInt8) -> Void
    let onEditDDC: (EditablePort) -> Void
    
    var body: some View {
        VStack(spacing: 8) {
            Text("输入端口")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            HStack(spacing: 8) {
                ForEach(ports) { port in
                    PortButton(
                        port: port,
                        isSelected: selectedPortCode == port.code,
                        onSelect: { onSelect(port.code) },
                        onDoubleClick: { onDoubleClick(port.code) },
                        onEditDDC: { onEditDDC(port) }
                    )
                }
            }
            
            Text("单击选择 · 双击切换 · 右键编辑")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

struct PortButton: View {
    let port: EditablePort
    let isSelected: Bool
    let onSelect: () -> Void
    let onDoubleClick: () -> Void
    let onEditDDC: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        VStack(spacing: 4) {
            // 端口图标
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.blue : Color(nsColor: .controlBackgroundColor))
                    .frame(width: 50, height: 36)
                    .shadow(color: isSelected ? .blue.opacity(0.3) : .black.opacity(0.1), radius: isSelected ? 4 : 2, y: 1)
                
                // 端口外观
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(isSelected ? Color.white.opacity(0.8) : Color(nsColor: .tertiaryLabelColor))
                            .frame(width: 4, height: 8)
                    }
                }
            }
            .scaleEffect(isHovering ? 1.05 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
            .onTapGesture(count: 2) {
                onDoubleClick()
            }
            .onTapGesture(count: 1) {
                onSelect()
            }
            .contextMenu {
                Button("编辑 DDC ID (\(port.code))") {
                    onEditDDC()
                }
            }
            
            // 标签
            Text(port.name)
                .font(.caption2)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
    }
}

// MARK: - Edit DDC Sheet

struct EditDDCSheet: View {
    let portName: String
    let currentCode: UInt8
    let onSave: (UInt8) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var codeString: String = ""
    
    var body: some View {
        VStack(spacing: 16) {
            Text("编辑 \(portName) 的 DDC ID")
                .font(.headline)
            
            TextField("DDC ID", text: $codeString)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                .multilineTextAlignment(.center)
            
            Text("常用: HDMI-1=17, HDMI-2=18, DP-1=15, DP-2=16, USB-C=27")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            HStack(spacing: 12) {
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("保存") {
                    if let code = UInt8(codeString) {
                        onSave(code)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(UInt8(codeString) == nil)
            }
        }
        .padding(24)
        .frame(width: 300)
        .onAppear {
            codeString = String(currentCode)
        }
    }
}

// MARK: - Keyboard Section

struct KeyboardSection: View {
    let keyboard: BluetoothKeyboard?
    let detectedKeyboards: [BluetoothKeyboardInfo]
    let isScanning: Bool
    let onScan: () -> Void
    let onSelect: (BluetoothKeyboardInfo) -> Void
    
    @State private var showKeyboardPicker = false
    
    var body: some View {
        VStack(spacing: 12) {
            // 键盘图标
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 140, height: 50)
                    .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                
                if keyboard == nil {
                    // 未选择状态
                    HStack(spacing: 8) {
                        Image(systemName: "keyboard")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        
                        if isScanning {
                            ProgressView()
                                .scaleEffect(0.6)
                        }
                    }
                } else {
                    // 已选择状态
                    HStack(spacing: 4) {
                        // 模拟键盘按键
                        ForEach(0..<6, id: \.self) { row in
                            VStack(spacing: 2) {
                                ForEach(0..<3, id: \.self) { _ in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color(nsColor: .tertiaryLabelColor))
                                        .frame(width: 8, height: 8)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            .onTapGesture {
                if keyboard == nil {
                    if detectedKeyboards.isEmpty {
                        onScan()
                    } else {
                        showKeyboardPicker = true
                    }
                } else {
                    showKeyboardPicker = true
                }
            }
            
            // 标签
            if let keyboard = keyboard {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text(keyboard.name)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
            } else {
                VStack(spacing: 4) {
                    Text("未选择键盘")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("点击检测或选择")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }
        }
        .popover(isPresented: $showKeyboardPicker) {
            KeyboardPickerPopover(
                detectedKeyboards: detectedKeyboards,
                isScanning: isScanning,
                onScan: onScan,
                onSelect: { info in
                    onSelect(info)
                    showKeyboardPicker = false
                }
            )
        }
    }
}

struct KeyboardPickerPopover: View {
    let detectedKeyboards: [BluetoothKeyboardInfo]
    let isScanning: Bool
    let onScan: () -> Void
    let onSelect: (BluetoothKeyboardInfo) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("选择键盘")
                    .font(.headline)
                Spacer()
                Button(action: onScan) {
                    if isScanning {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .disabled(isScanning)
            }
            
            Divider()
            
            if detectedKeyboards.isEmpty {
                Text("未检测到蓝牙键盘")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(detectedKeyboards) { keyboard in
                    Button(action: { onSelect(keyboard) }) {
                        HStack {
                            Image(systemName: "keyboard")
                            VStack(alignment: .leading) {
                                Text(keyboard.name)
                                    .font(.body)
                                Text(keyboard.address)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if keyboard.isConnected {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
            }
            
            Text("仅能选择一个键盘")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(width: 250)
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
        .environment(DDCManager())
        .environmentObject(BluetoothMonitor())
        .modelContainer(for: [BluetoothKeyboard.self, Monitor.self, InputMapping.self], inMemory: true)
}
