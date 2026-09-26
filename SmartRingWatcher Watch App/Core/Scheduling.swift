import Foundation

/// A pending timer. Cancelling is idempotent.
@MainActor
protocol Cancellable: AnyObject {
    func cancel()
}

/// The clock and timers used by the engine, the store and the transport. Injected so tests
/// can move time forward by hand instead of waiting.
@MainActor
protocol Scheduling: AnyObject {
    var now: Date { get }
    /// Runs `action` once, `delay` seconds from now.
    @discardableResult
    func after(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any Cancellable
    /// Runs `action` every `interval` seconds until cancelled.
    @discardableResult
    func every(_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any Cancellable
}

/// Real time, on the main actor.
///
/// Uses tasks rather than `Timer`: a `Timer` scheduled in the default run-loop mode stops
/// firing while the user scrolls with the Digital Crown, which delayed polls and timeouts.
@MainActor
final class SystemScheduler: Scheduling {
    static let shared = SystemScheduler()

    var now: Date { Date() }

    @discardableResult
    func after(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any Cancellable {
        TaskCancellable(Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            guard !Task.isCancelled else { return }
            action()
        })
    }

    @discardableResult
    func every(_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any Cancellable {
        TaskCancellable(Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(0.1, interval)))
                guard !Task.isCancelled else { return }
                action()
            }
        })
    }
}

@MainActor
private final class TaskCancellable: Cancellable {
    private let task: Task<Void, Never>

    init(_ task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}
