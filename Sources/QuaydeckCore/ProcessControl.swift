import Foundation

/// Stopping processes. Behind a protocol so tests can assert what *would* have been
/// killed without a test run ever signalling a real process.
public protocol ProcessControlling: Sendable {
    /// Send SIGTERM (or SIGKILL when `force`) to a pid.
    func terminate(pid: Int32, force: Bool)
}

public struct ProcessControl: ProcessControlling {
    private let runner: CommandRunner

    public init(runner: CommandRunner) {
        self.runner = runner
    }

    public func terminate(pid: Int32, force: Bool) {
        guard pid > 1 else { return }   // never signal init or an unset pid
        _ = runner.run("/bin/kill", [force ? "-KILL" : "-TERM", "\(pid)"])
    }
}

/// Records requests instead of carrying them out.
public final class RecordingProcessControl: ProcessControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(pid: Int32, force: Bool)] = []

    public init() {}

    public var requests: [(pid: Int32, force: Bool)] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    public func terminate(pid: Int32, force: Bool) {
        lock.lock(); defer { lock.unlock() }
        _requests.append((pid, force))
    }
}
