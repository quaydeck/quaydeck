import Foundation

/// One line of `lsof` output: a process holding a listening TCP socket.
public struct Listener: Hashable, Sendable {
    public let port: Int
    public let pid: Int32
    public let command: String
    /// Bound to something other than loopback, so reachable from the local network.
    public let exposed: Bool
}

/// Reads listening TCP sockets and process working directories out of `lsof`.
///
/// We ask for field output (`-F`) rather than the human table, because the table
/// format breaks on any binary path containing a space, and macOS is full of those
/// ("/Applications/Google Drive.app/...").
public struct ListenerSource: Sendable {
    private let runner: CommandRunner?
    private let kernel: KernelSource?

    /// `lsof` lives in /usr/sbin on macOS, but is on PATH in some environments.
    private static let candidatePaths = ["/usr/sbin/lsof", "/usr/bin/lsof", "/opt/homebrew/bin/lsof"]

    /// Reads recorded or real `lsof` output. The path fixtures take.
    public init(runner: CommandRunner) {
        self.runner = runner
        self.kernel = nil
    }

    /// Asks the kernel directly. The path the app takes.
    public init(kernel: KernelSource) {
        self.runner = nil
        self.kernel = kernel
    }

    /// Every listening TCP socket on the machine. IPv4 and IPv6 rows for the same
    /// server both appear; `PortInventory` collapses them.
    public func listeners() -> [Listener] {
        if let kernel { return kernel.listeners() }
        let output = firstNonEmpty(arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-FpcPn"])
        return Self.parseListeners(output)
    }

    /// Working directory per pid. This is what tells us which project a server belongs to.
    public func workingDirectories(for pids: Set<Int32>) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        if let kernel {
            var map: [Int32: String] = [:]
            for pid in pids { map[pid] = kernel.workingDirectory(of: pid) }
            return map
        }
        let list = pids.map(String.init).sorted().joined(separator: ",")
        let output = firstNonEmpty(arguments: ["-a", "-d", "cwd", "-p", list, "-Fpn"])
        return Self.parseWorkingDirectories(output)
    }

    private func firstNonEmpty(arguments: [String]) -> String {
        guard let runner else { return "" }
        for path in Self.candidatePaths {
            let output = runner.run(path, arguments)
            if !output.isEmpty { return output }
        }
        return ""
    }

    // MARK: - Parsing

    /// `lsof -F` emits one field per line, tagged by its first character. Fields
    /// accumulate against the most recent `p` (pid) and `c` (command) seen.
    static func parseListeners(_ output: String) -> [Listener] {
        var result: [Listener] = []
        var pid: Int32 = 0
        var command = ""

        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "n":
                if pid != 0, let binding = parseBinding(value) {
                    result.append(Listener(port: binding.port, pid: pid,
                                           command: command, exposed: binding.exposed))
                }
            default: break
            }
        }
        return result
    }

    /// "127.0.0.1:4321", "*:4646", "[::1]:4321", "[fe80::1%en0]:8080" -> (port, exposed).
    /// Exposed means bound to something other than loopback.
    static func parseBinding(_ name: String) -> (port: Int, exposed: Bool)? {
        guard let colon = name.lastIndex(of: ":"),
              let port = Int(name[name.index(after: colon)...]) else { return nil }
        let address = String(name[..<colon])
        let loopback = address == "127.0.0.1"
            || address == "[::1]"
            || address == "localhost"
            || address.hasPrefix("127.")
        return (port, !loopback)
    }

    static func parseWorkingDirectories(_ output: String) -> [Int32: String] {
        var map: [Int32: String] = [:]
        var pid: Int32 = 0
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            if tag == "p" {
                pid = Int32(value) ?? 0
            } else if tag == "n", pid != 0 {
                map[pid] = value
            }
        }
        return map
    }
}
