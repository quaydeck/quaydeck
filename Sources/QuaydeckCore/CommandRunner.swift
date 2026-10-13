import Foundation

/// The single seam between Quaydeck and the outside world.
///
/// Every `lsof`, `ps`, `git` and `kill` invocation in the core goes through this
/// protocol. Production uses `ShellRunner`; tests use `FixtureRunner` and drive the
/// entire scan pipeline from recorded output, so a bug report that arrives as a paste
/// of someone's `lsof` output becomes a failing test instead of a guess.
public protocol CommandRunner: Sendable {
    /// Run `executable` with `arguments` and return its stdout. stderr is discarded.
    /// Returns an empty string if the process cannot be launched.
    func run(_ executable: String, _ arguments: [String]) -> String

    /// The same, but gives up after `timeout` seconds and returns whatever arrived.
    /// For tools that talk to a daemon, such as `docker`, which can block forever
    /// when the daemon is wedged and would otherwise stall every scan behind it.
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> String
}

extension CommandRunner {
    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> String {
        run(executable, arguments)
    }
}

/// Runs real processes. Never goes through a shell, so no argument needs quoting and
/// no project path can be interpreted as shell syntax.
public struct ShellRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) -> String {
        execute(executable, arguments, timeout: nil)
    }

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> String {
        execute(executable, arguments, timeout: timeout)
    }

    private func execute(_ executable: String, _ arguments: [String], timeout: TimeInterval?) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { return "" }

        // Terminating the process closes its end of the pipe, which is what releases
        // the read below.
        var watchdog: DispatchWorkItem?
        if let timeout {
            let item = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: item)
            watchdog = item
        }

        // Read before waiting: a process that fills the 64KB pipe buffer would
        // otherwise block forever waiting for us to drain it.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog?.cancel()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Serves canned output. Keys are matched by "executable + first matching argument
/// fragment", which keeps test setup readable without pinning exact argument order.
public struct FixtureRunner: CommandRunner {
    /// Ordered list of (executable suffix, argument fragment, output).
    /// The first entry whose executable and fragment both match wins.
    private let entries: [(exe: String, fragment: String, output: String)]

    public init(_ entries: [(exe: String, fragment: String, output: String)]) {
        self.entries = entries
    }

    public func run(_ executable: String, _ arguments: [String]) -> String {
        let joined = arguments.joined(separator: " ")
        for entry in entries where executable.hasSuffix(entry.exe) {
            if entry.fragment.isEmpty || joined.contains(entry.fragment) {
                return entry.output
            }
        }
        return ""
    }
}
