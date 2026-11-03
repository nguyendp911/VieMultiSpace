import SwiftUI
import Combine

// MARK: - Log Level

enum LogLevel: Int, Codable, CaseIterable, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .warning: return "WARN"
        case .error:   return "LỖI"
        }
    }

    var symbol: String {
        switch self {
        case .debug:   return "text.magnifyingglass"
        case .info:    return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .debug:   return .secondary
        case .info:    return .blue
        case .warning: return .orange
        case .error:   return .red
        }
    }
}

// MARK: - Log Entry

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let tag: String
    let message: String
    let detail: String?

    var formattedTime: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: timestamp)
    }

    var plainText: String {
        var lines = "[\(formattedTime)] [\(level.label)] [\(tag)] \(message)"
        if let d = detail, !d.isEmpty { lines += "\n  → \(d)" }
        return lines
    }
}

// MARK: - AppLogger Singleton

@MainActor
final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    private init() {}

    @Published private(set) var entries: [LogEntry] = []
    @Published private(set) var errorCount: Int = 0

    private let maxEntries = 500

    // MARK: Log

    nonisolated func log(
        _ level: LogLevel,
        tag: String,
        _ message: String,
        detail: String? = nil
    ) {
        let entry = LogEntry(
            timestamp: Date(),
            level: level,
            tag: tag,
            message: message,
            detail: detail
        )
        Task { @MainActor in
            self.entries.insert(entry, at: 0)
            if self.entries.count > self.maxEntries {
                self.entries.removeLast(self.entries.count - self.maxEntries)
            }
            if level == .error {
                self.errorCount += 1
            }
        }
    }

    // MARK: Convenience

    nonisolated func debug(_ tag: String, _ message: String, detail: String? = nil) {
        log(.debug, tag: tag, message, detail: detail)
    }
    nonisolated func info(_ tag: String, _ message: String, detail: String? = nil) {
        log(.info, tag: tag, message, detail: detail)
    }
    nonisolated func warning(_ tag: String, _ message: String, detail: String? = nil) {
        log(.warning, tag: tag, message, detail: detail)
    }
    nonisolated func error(_ tag: String, _ message: String, detail: String? = nil) {
        log(.error, tag: tag, message, detail: detail)
    }

    // MARK: Clear

    func clear() {
        entries.removeAll()
        errorCount = 0
    }

    func clearErrorBadge() {
        errorCount = 0
    }

    // MARK: Export

    func allAsText() -> String {
        entries.reversed().map(\.plainText).joined(separator: "\n")
    }
}

