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

    private let reader: ProcArgsReader

    public init() {
        self.reader = ProcArgsReader()
    }

    init(reader: ProcArgsReader) {
        self.reader = reader
    }

    public func markers(of pid: Int32) -> [String: String] {
        guard pid > 1 else { return [:] }
        return reader.withProcArgs(of: pid) { ProcArgs.environment(in: $0, wanted: Self.wanted) } ?? [:]
    }

    static func parse(procargs bytes: [UInt8], wanted: Set<String>) -> [String: String] {
        ProcArgs.environment(in: bytes[...], wanted: wanted)
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
