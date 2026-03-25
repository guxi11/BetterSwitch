//
//  LogView.swift
//  BetterSwitch
//
//  Created by zhangyuanyuan on 2026/3/24.
//

import SwiftUI
import Combine

struct LogView: View {
    // Absolutely NO @Environment or @EnvironmentObject dependencies to prevent crashes
    
    @State private var logsCount: Int = 0
    @State private var debugText: String = "Initializing..."
    @State private var autoScroll: Bool = true
    
    // Timer to poll for updates
    let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 0) {
            
            // Debug Header
            HStack {
                VStack(alignment: .leading) {
                    Text("BetterSwitch Logs")
                        .font(.headline)
                    Text(debugText)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                
                Spacer()
                
                Text("Total: \(logsCount)")
                    .font(.subheadline)
                    .padding(.trailing, 10)
                
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                    .padding(.trailing, 10)
                
                Button("Clear") {
                    AppLogger.shared.clear()
                    updateLogs()
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // List of Logs
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(AppLogger.shared.entries, id: \.id) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(timeString(entry.timestamp))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                                
                                Text("[\(entry.category)]")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(colorForCategory(entry.category))
                                
                                Text(entry.message)
                                    .font(.system(.caption, design: .monospaced))
                                
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .id(entry.id)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: AppLogger.shared.entries.count) { _, _ in
                    if autoScroll, let last = AppLogger.shared.entries.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .background(Color(NSColor.textBackgroundColor))
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            NSApplication.shared.activate(ignoringOtherApps: true)
            self.debugText = "Window Loaded Successfully"
            updateLogs()
        }
        .onReceive(timer) { _ in
            updateLogs()
        }
    }
    
    private func updateLogs() {
        self.logsCount = AppLogger.shared.entries.count
        self.debugText = "Refreshed at: \(timeString(Date()))"
    }
    
    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
    
    private func colorForCategory(_ category: String) -> Color {
        switch category {
        case "HID": return .blue
        case "Switch": return .green
        case "BT": return .cyan
        case "App": return .purple
        default: return .secondary
        }
    }
}
