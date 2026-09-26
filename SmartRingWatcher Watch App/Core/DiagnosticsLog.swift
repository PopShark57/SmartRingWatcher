import Foundation
import Observation
import os

/// `os.Logger` categories. Visible in Console.app while the watch is attached to a Mac.
enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "SmartRingWatcher"
    static let ble = Logger(subsystem: subsystem, category: "ble")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let store = Logger(subsystem: subsystem, category: "store")
}

/// The event log under Settings → Diagnostics: a small ring buffer that is also mirrored to
/// `os.Logger`, so a bug report can include it (see the share button).
@MainActor
@Observable
final class DiagnosticsLog {
    enum Category: String, Sendable {
        case ble, sync, store
        /// Raw frames, only recorded while "Record raw frames" is on.
        case frame
    }

    struct Entry: Identifiable, Hashable, Sendable {
        /// Stable across trimming, unlike an array offset.
        let id: Int
        let date: Date
        let category: Category
        let message: String
        let isError: Bool
    }

    private(set) var entries: [Entry] = []
    /// Also log every frame sent and received, as hex.
    var recordsFrames = false

    @ObservationIgnored private let capacity: Int
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var nextID = 0

    init(capacity: Int = 250, clock: @escaping () -> Date = { Date() }) {
        self.capacity = capacity
        self.clock = clock
    }

    func add(_ message: String, category: Category = .sync, isError: Bool = false) {
        let logger: Logger
        switch category {
        case .ble, .frame: logger = Log.ble
        case .sync: logger = Log.sync
        case .store: logger = Log.store
        }
        if isError {
            logger.error("\(message, privacy: .public)")
        } else {
            logger.log("\(message, privacy: .public)")
        }
        append(Entry(id: nextID, date: clock(), category: category, message: message, isError: isError))
    }

    /// Records a frame when raw-frame logging is on. `outgoing` is watch → ring.
    func frame(_ data: Data, outgoing: Bool) {
        guard recordsFrames else { return }
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        append(Entry(id: nextID, date: clock(), category: .frame, message: (outgoing ? "→ " : "← ") + hex, isError: false))
    }

    func clear() {
        entries.removeAll()
    }

    /// Plain text for the share sheet, oldest first.
    var exportText: String {
        let style = Date.ISO8601FormatStyle(includingFractionalSeconds: false, timeZone: .current)
        return entries.map { "\($0.date.formatted(style)) [\($0.category.rawValue)] \($0.message)" }
            .joined(separator: "\n")
    }

    private func append(_ entry: Entry) {
        nextID += 1
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }
}
