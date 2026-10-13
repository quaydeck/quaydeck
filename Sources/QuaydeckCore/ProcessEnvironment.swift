import Darwin
import Foundation

/// Reads a small, fixed set of environment variables from another process.
///
/// Coding agents mark every command they run: Claude Code sets `CLAUDECODE`, Codex sets
/// `CODEX_THREAD_ID`. Those markers outlive the agent. A server started from a chat that
/// has since closed has been re-parented to launchd, so walking its parent chain finds
/// nothing, but its environment still says who started it.
///
/// An environment also holds tokens and keys. Only the names in `wanted` are kept;
/// every other entry is discarded while parsing and never stored or logged.
public protocol EnvironmentProbing: Sendable {
    func markers(of pid: Int32) -> [String: String]
}

public struct ProcessEnvironment: EnvironmentProbing {
    /// The only variables Quaydeck ever reads.
    public static let wanted: Set<String> = [
        "CLAUDECODE",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CONFIG_DIR",
        "CODEX_THREAD_ID",
        "CODEX_SHELL",
        "CODEX_SANDBOX",
        "CODEX_CI",
        "CODEX_HOME",
        "AI_AGENT",
    ]

    public init() {}

    public func markers(of pid: Int32) -> [String: String] {
        guard pid > 1, let buffer = Self.procargs(of: pid) else { return [:] }
        return Self.parse(procargs: buffer, wanted: Self.wanted)
    }

    /// The kernel's limit on argument plus environment size. Fixed for the life of
    /// the system, so asked once.
    private static let argmax: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return 0 }
        return Int(value)
    }()

    /// The raw KERN_PROCARGS2 block. macOS only hands it out for processes owned by the
    /// same user, which is every dev server worth looking at.
    static func procargs(of pid: Int32) -> [UInt8]? {
        let argmax = Self.argmax
        guard argmax > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: argmax)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argmax
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size
        else { return nil }
        return Array(buffer.prefix(size))
    }

    /// Layout: argc as a 32-bit int, the executable path, NUL padding, argc argument
    /// strings, then the environment as NUL-terminated `KEY=value` strings ending at an
    /// empty one.
    static func parse(procargs bytes: [UInt8], wanted: Set<String>) -> [String: String] {
        guard bytes.count > 4 else { return [:] }
        let argc = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        var index = 4

        // Executable path, then the padding after it.
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        var skipped = 0
        while index < bytes.count, skipped < argc {
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
            skipped += 1
        }

        var result: [String: String] = [:]
        while index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            if index == start { break }
            if let equals = bytes[start..<index].firstIndex(of: UInt8(ascii: "=")),
               let key = String(bytes: bytes[start..<equals], encoding: .utf8),
               wanted.contains(key) {
                result[key] = String(bytes: bytes[(equals + 1)..<index], encoding: .utf8) ?? ""
            }
            index += 1
        }
        return result
    }
}

/// Canned environments per pid, for tests.
public struct StubEnvironment: EnvironmentProbing {
    private let byPID: [Int32: [String: String]]

    public init(_ byPID: [Int32: [String: String]] = [:]) {
        self.byPID = byPID
    }

    public func markers(of pid: Int32) -> [String: String] { byPID[pid] ?? [:] }
}
