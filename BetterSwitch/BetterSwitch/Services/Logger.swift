//
//  Logger.swift
//  BetterSwitch
//
//  Created by zhangyuanyuan on 2026/3/24.
//

import Foundation
import SwiftUI
import Combine

/// Log entry for debugging
struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let category: String
    let message: String
    
    enum LogLevel: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        
        var emoji: String {
            switch self {
            case .debug: return "🔍"
            case .info: return "ℹ️"
            case .warning: return "⚠️"
            case .error: return "❌"
            }
        }
    }
}

/// Global logger for debugging - strictly uses ObservableObject for SwiftUI 100% reliability
final class AppLogger: ObservableObject {
    static let shared = AppLogger()
    
    @Published var entries: [LogEntry] = []
    @Published var hidEventCount: Int = 0
    @Published var lastHIDEventTime: Date?
    @Published var switchAttemptCount: Int = 0
    @Published var switchSuccessCount: Int = 0
    
    private let maxEntries = 500
    
    private init() {
        print("[AppLogger] Initialized")
    }
    
    func log(_ level: LogEntry.LogLevel, category: String, _ message: String) {
        let entry = LogEntry(timestamp: Date(), level: level, category: category, message: message)
        
        // Print to Xcode console immediately
        print("[\(category)] \(level.rawValue): \(message)")
        
        // Safely update the observable arrays on MainActor
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }
    
    func debug(_ category: String, _ message: String) {
        log(.debug, category: category, message)
    }
    
    func info(_ category: String, _ message: String) {
        log(.info, category: category, message)
    }
    
    func warning(_ category: String, _ message: String) {
        log(.warning, category: category, message)
    }
    
    func error(_ category: String, _ message: String) {
        log(.error, category: category, message)
    }
    
    func recordHIDEvent() {
        DispatchQueue.main.async { [weak self] in
            self?.hidEventCount += 1
            self?.lastHIDEventTime = Date()
        }
    }
    
    func recordSwitchAttempt(success: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.switchAttemptCount += 1
            if success { self?.switchSuccessCount += 1 }
        }
    }
    
    func clear() {
        DispatchQueue.main.async { [weak self] in
            self?.entries.removeAll()
            self?.hidEventCount = 0
            self?.switchAttemptCount = 0
            self?.switchSuccessCount = 0
        }
    }
}
