import Foundation

/// The way back from a server to the agent session that started it.
///
/// Session and thread ids come out of another process's environment, and the
/// commands built here end up in a shell. Anything that is not a plain id is
/// refused, and every path is quoted.
public enum SessionLinks {

    /// Claude Code and Codex ids are UUIDs; a little slack, nothing a shell could read.
    static func isPlainID(_ id: String) -> Bool {
        (8...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// `cd '<folder>' && claude --resume <id>`, with the session's own config folder
    /// when it is not the default (people with two Claude accounts).
    public static func claudeResumeCommand(for server: LocalServer) -> String? {
        guard server.agent == .claude, let id = server.agentSessionID, isPlainID(id) else { return nil }
        var command = ""
        if let folder = server.agentSessionDirectory ?? server.projectPath {
            command += "cd \(quote(folder)) && "
        }
        if let home = server.agentHome, !home.isEmpty {
            command += "CLAUDE_CONFIG_DIR=\(quote(home)) "
        }
        return command + "claude --resume \(id)"
    }

    /// Opens the chat in the Codex app.
    public static func codexThreadURL(for server: LocalServer) -> URL? {
        guard server.agent == .codex, let id = server.agentSessionID, isPlainID(id) else { return nil }
        return URL(string: "codex://threads/\(id)")
    }

    /// The same chat from a terminal.
    public static func codexResumeCommand(for server: LocalServer) -> String? {
        guard server.agent == .codex, let id = server.agentSessionID, isPlainID(id) else { return nil }
        return "codex resume \(id)"
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
