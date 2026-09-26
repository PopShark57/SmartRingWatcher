import Foundation
@testable import RingCore

/// Time that only moves when a test says so. Timers fire in order as it advances.
@MainActor
final class ManualScheduler: Scheduling {
    private(set) var now: Date
    private var nextID = 0
    private var tasks: [Int: (due: Date, interval: TimeInterval?, action: @MainActor () -> Void)] = [:]

    init(now: Date) {
        self.now = now
    }

    func after(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any Cancellable {
        add(due: now.addingTimeInterval(delay), interval: nil, action)
    }

    func every(_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any Cancellable {
        add(due: now.addingTimeInterval(interval), interval: interval, action)
    }

    /// Moves time forward, firing every timer that falls due on the way.
    func advance(by seconds: TimeInterval) {
        let end = now.addingTimeInterval(seconds)
        while let (id, task) = tasks.filter({ $0.value.due <= end })
            .min(by: { ($0.value.due, $0.key) < ($1.value.due, $1.key) }) {
            now = task.due
            if let interval = task.interval {
                tasks[id]?.due = task.due.addingTimeInterval(interval)
            } else {
                tasks[id] = nil
            }
            task.action()
        }
        now = end
    }

    private func add(due: Date, interval: TimeInterval?, _ action: @escaping @MainActor () -> Void) -> any Cancellable {
        nextID += 1
        tasks[nextID] = (due, interval, action)
        return Handle(scheduler: self, id: nextID)
    }

    fileprivate func cancel(_ id: Int) {
        tasks[id] = nil
    }

    private final class Handle: Cancellable {
        weak var scheduler: ManualScheduler?
        let id: Int

        init(scheduler: ManualScheduler, id: Int) {
            self.scheduler = scheduler
            self.id = id
        }

        func cancel() {
            scheduler?.cancel(id)
        }
    }
}

/// A ring link that records what the engine writes; tests play the ring's part.
@MainActor
final class FakeTransport: RingTransport {
    weak var delegate: (any RingTransportDelegate)?
    var state: RingConnectionState = .idle
    var hasProtocolChannel = true
    var protocolName: String? = "YC (test)"
    var connectedRingID: UUID? = UUID(uuidString: "00000000-0000-0000-0000-00000000A11E")
    var maximumWriteLength: Int? = 20
    var isSuspended = false
    private(set) var connectCalls = 0
    private(set) var batteryReads = 0
    private(set) var written: [YCFrame] = []

    func write(_ data: Data) {
        if let frame = YCFrame.decode([UInt8](data))?.frame { written.append(frame) }
    }

    func connectSavedRing() { connectCalls += 1 }
    func readBattery() { batteryReads += 1 }

    func becomeReady() {
        state = .ready
        delegate?.transportDidBecomeReady(self)
    }

    func drop() {
        state = .idle
        delegate?.transportDidDisconnect(self)
    }

    func receive(_ frame: YCFrame) {
        delegate?.transport(self, didReceive: frame.data)
    }

    func clearWritten() { written.removeAll() }
}

/// 10:00 local time on 8 July 2025, so "today" and "last night" are unambiguous.
let referenceDate = Calendar.current.date(from: DateComponents(year: 2025, month: 7, day: 8, hour: 10))!

/// A fresh `UserDefaults` for one test.
func makeDefaults() -> UserDefaults {
    let name = "RingCoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// An engine wired to a fake transport, in-memory stores and a manual clock, with a
/// scripted ring that answers every request.
@MainActor
final class EngineHarness {
    let scheduler = ManualScheduler(now: referenceDate)
    let transport = FakeTransport()
    let defaults = makeDefaults()
    let settings: AppSettings
    let log = DiagnosticsLog()
    let realStore: HealthDataStore
    let demoStore: HealthDataStore
    let engine: RingSyncEngine
    /// Reply for a request type; return nil to stay silent (a timeout).
    var reply: (YCDataType) -> [UInt8]? = EngineHarness.defaultReply
    private var answered = 0

    init(demoMode: Bool = false) {
        settings = AppSettings(defaults: defaults)
        settings.demoMode = demoMode
        realStore = HealthDataStore(fileName: nil, scheduler: scheduler, observesDayChanges: false)
        demoStore = HealthDataStore(fileName: nil, scheduler: scheduler, observesDayChanges: false)
        engine = RingSyncEngine(transport: transport, realStore: realStore, demoStore: demoStore, settings: settings,
                                log: log, scheduler: scheduler, defaults: defaults, observesSystemTime: false)
    }

    nonisolated static func defaultReply(_ type: YCDataType) -> [UInt8]? {
        switch type {
        case .getAllRealData:
            // HR 70, 120/80, SpO2 98, resp 16, 36.5 °C, 1000 steps, 40 kcal, 700 m.
            return [70, 120, 80, 98, 16, 36, 5, 0xE8, 0x03, 0x00, 40, 0, 0xBC, 0x02]
        case .getDeviceInfo:
            return [0x34, 0x12, 0x05, 0x01, 0x00, 0x50, 0x01, 0x00]
        default:
            if type.group == YCGroup.health { return [0x00, 0x00] } // nothing stored
            return [0x00]
        }
    }

    /// Requests the engine has sent (not counting acknowledgements).
    var requests: [YCDataType] {
        transport.written.map(\.dataType).filter { $0 != .historyBlock && $0.group != YCGroup.deviceControl }
    }

    var historyRequests: Set<YCDataType> {
        Set(requests.filter { $0.group == YCGroup.health })
    }

    /// Runs the clock forward in small steps, answering each request like a ring would.
    func run(for seconds: TimeInterval, step: TimeInterval = 0.25) {
        var elapsed = 0.0
        repeat {
            answerPending()
            scheduler.advance(by: step)
            elapsed += step
        } while elapsed < seconds
        answerPending()
    }

    func connect() {
        transport.becomeReady()
        run(for: 5)
    }

    func clear() {
        transport.clearWritten()
        answered = 0
    }

    private func answerPending() {
        while answered < transport.written.count {
            let frame = transport.written[answered]
            answered += 1
            // Acknowledgements (transfer OK, ring events) aren't requests; a ring doesn't answer them.
            guard frame.dataType != .historyBlock, frame.dataType.group != YCGroup.deviceControl,
                  let payload = reply(frame.dataType) else { continue }
            transport.receive(YCFrame(frame.dataType, payload))
        }
    }
}
