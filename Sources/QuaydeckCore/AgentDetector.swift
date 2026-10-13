import Foundation

/// A coding agent that can start servers on your behalf.
public enum CodingAgent: String, CaseIterable, Hashable, Sendable {
    case claude, codex, cursor, copilot, aider

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .copilot: return "Copilot"
        case .aider: return "Aider"
        }
    }
}

/// Which agent started a server, and which of its sessions did.
public struct AgentAttribution: Hashable, Sendable {
    public let agent: CodingAgent
    /// Claude Code's session id or Codex's thread id, when the agent left one behind.
    public let sessionID: String?
    /// The agent's own data directory, when the process names one
    /// (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`). Nil means the default.
    public let dataDirectory: String?
    /// The agent is no longer anywhere in the process's parent chain: the chat or
    /// command that started it has ended, and only its environment remembers.
    public let detached: Bool

    public init(agent: CodingAgent, sessionID: String? = nil, dataDirectory: String? = nil,
                detached: Bool = false) {
        self.agent = agent
        self.sessionID = sessionID
        self.dataDirectory = dataDirectory
        self.detached = detached
    }
}

/// Works out whether a coding agent started a process.
///
/// Two signals, nearest first. The parent chain says exactly who launched a process
/// while the agent is still running. The environment markers agents set on every
/// command still say it after the agent has exited, when the chain ends at launchd.
public struct AgentDetector: Sendable {

    /// Executable names, matched exactly against argv[0]'s basename. Exact matching is
    /// the point: a project that merely lives in a folder called "Codex", or a path
    /// containing "claude", must not be credited to an agent.
    static let executables: [String: CodingAgent] = [
        "claude": .claude,
        "codex": .codex,
        "cursor": .cursor,
        "aider": .aider,
        "copilot": .copilot,
        "copilot-language-server": .copilot,
    ]

    /// Runtimes that wrap an agent installed as a script, e.g. `node …/bin/claude`.
    static let wrappers: Set<String> = ["node", "bun", "deno", "python", "python3"]

    public init() {}

    /// `ancestry` holds argument vectors, the process itself first, then its parents.
    public func attribute(environment: [String: String], ancestry: [String]) -> AgentAttribution? {
        for args in ancestry {
            if let agent = agent(launchedBy: args) {
                return attribution(for: agent, environment: environment, detached: false)
            }
        }

        let aiAgent = environment["AI_AGENT"]?.lowercased() ?? ""
        let claude = environment["CLAUDECODE"] != nil
            || environment["CLAUDE_CODE_ENTRYPOINT"] != nil
            || environment["CLAUDE_CODE_SESSION_ID"] != nil
            || aiAgent.hasPrefix("claude")
        let codex = environment["CODEX_THREAD_ID"] != nil
            || environment["CODEX_SHELL"] != nil
            || environment["CODEX_SANDBOX"] != nil
            || environment["CODEX_CI"] != nil
            || aiAgent.hasPrefix("codex")

        // Both sets of markers means one agent ran the other, and the environment
        // cannot say which is innermost. Codex driven from a Claude session is the
        // common arrangement, and its markers are set by the inner command.
        if codex { return attribution(for: .codex, environment: environment, detached: true) }
        if claude { return attribution(for: .claude, environment: environment, detached: true) }
        return nil
    }

    func agent(launchedBy args: String) -> CodingAgent? {
        let tokens = args.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = tokens.first else { return nil }
        let executable = Self.basename(first)
        if let agent = Self.executables[executable] { return agent }
        // An editor's helper processes carry the app name: "Cursor Helper (Plugin)".
        if args.contains("/Cursor.app/") { return .cursor }
        if Self.wrappers.contains(executable), tokens.count > 1 {
            let script = String(tokens[1])
            if script.contains("@anthropic-ai/claude-code") { return .claude }
            if script.contains("@openai/codex") { return .codex }
            return Self.executables[Self.basename(tokens[1])]
        }
        return nil
    }

    private func attribution(for agent: CodingAgent, environment: [String: String],
                             detached: Bool) -> AgentAttribution {
        switch agent {
        case .claude:
            return AgentAttribution(agent: agent,
                                    sessionID: environment["CLAUDE_CODE_SESSION_ID"],
                                    dataDirectory: environment["CLAUDE_CONFIG_DIR"],
                                    detached: detached)
        case .codex:
            return AgentAttribution(agent: agent,
                                    sessionID: environment["CODEX_THREAD_ID"],
                                    dataDirectory: environment["CODEX_HOME"],
                                    detached: detached)
        case .cursor, .copilot, .aider:
            return AgentAttribution(agent: agent, detached: detached)
        }
    }

    private static func basename<S: StringProtocol>(_ path: S) -> String {
        let text = String(path)
        return String(text.split(separator: "/").last ?? Substring(text)).lowercased()
    }
}

/// Turns an agent session id into the title you see in that agent: the Codex chat
/// name, or the Claude Code session title.
///
/// Reads only local files the agents already keep, and only the title out of them.
/// Results are cached, so a menu refreshing every few seconds reads each file at most
/// once a minute.
public final class SessionTitles: @unchecked Sendable {
    private let fileSystem: FileSystemProbe
    private let home: String
    private let lifetime: TimeInterval

    private let lock = NSLock()
    private var codexIndex: [String: (titles: [String: String], read: Date)] = [:]
    private var claudeTitles: [String: (title: String?, read: Date)] = [:]
    private var claudeDirectories: [String: String] = [:]
    private var claudePaths: [String: String] = [:]

    /// Enough of a transcript's end to contain its latest title line.
    private static let transcriptTail = 512 * 1024

    public init(fileSystem: FileSystemProbe = RealFileSystem(),
                home: String = NSHomeDirectory(),
                lifetime: TimeInterval = 60) {
        self.fileSystem = fileSystem
        self.home = home
        self.lifetime = lifetime
    }

    public func title(for attribution: AgentAttribution, now: Date = Date()) -> String? {
        guard let session = attribution.sessionID, !session.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        switch attribution.agent {
        case .codex:
            return codexTitle(session, directory: attribution.dataDirectory ?? home + "/.codex", now: now)
        case .claude:
            return claudeTitle(session, directory: attribution.dataDirectory ?? home + "/.claude", now: now)
        case .cursor, .copilot, .aider:
            return nil
        }
    }

    // MARK: - Codex

    /// Codex appends `{"id", "thread_name", "updated_at"}` to session_index.jsonl
    /// whenever a chat is named or renamed. The last line for an id is its name now.
    private func codexTitle(_ thread: String, directory: String, now: Date) -> String? {
        let path = directory + "/session_index.jsonl"
        if let cached = codexIndex[path], now.timeIntervalSince(cached.read) < lifetime {
            return cached.titles[thread]
        }
        var titles: [String: String] = [:]
        if let data = fileSystem.contents(at: path) {
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let id = json["id"] as? String,
                      let name = json["thread_name"] as? String else { continue }
                let cleaned = Self.clean(name)
                if !cleaned.isEmpty { titles[id] = cleaned }
            }
        }
        codexIndex[path] = (titles, now)
        return titles[thread]
    }

    // MARK: - Claude

    /// Claude Code keeps one transcript per session at
    /// `<config>/projects/<encoded cwd>/<session id>.jsonl`, and writes its title into
    /// it as it goes: `custom-title` when you renamed the session, `ai-title` when it
    /// named itself, `summary` in older versions.
    private func claudeTitle(_ session: String, directory: String, now: Date) -> String? {
        if let cached = claudeTitles[session], now.timeIntervalSince(cached.read) < lifetime {
            return cached.title
        }
        var title: String?
        if let path = claudeTranscript(session, directory: directory),
           let data = fileSystem.tail(at: path, maxBytes: Self.transcriptTail) {
            title = Self.latestClaudeTitle(in: data)
            if let folder = Self.latestClaudeDirectory(in: data) { claudeDirectories[session] = folder }
        }
        claudeTitles[session] = (title, now)
        return title
    }

    private func claudeTranscript(_ session: String, directory: String) -> String? {
        if let known = claudePaths[session] { return known }
        let projects = directory + "/projects"
        let file = session + ".jsonl"
        for folder in fileSystem.contentsOfDirectory(at: projects) {
            let candidate = projects + "/" + folder + "/" + file
            if fileSystem.fileExists(at: candidate) {
                claudePaths[session] = candidate
                return candidate
            }
        }
        return nil
    }

    /// The folder a Claude session runs in, which `claude --resume` has to be started
    /// from. Only meaningful after `title(for:)` has read the transcript.
    public func directory(for attribution: AgentAttribution) -> String? {
        guard attribution.agent == .claude, let session = attribution.sessionID else { return nil }
        lock.lock(); defer { lock.unlock() }
        return claudeDirectories[session]
    }

    /// The last `"cwd":"…"` in the transcript's tail: every message records it.
    static func latestClaudeDirectory(in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard let range = line.range(of: #""cwd":"[^"\\]+""#, options: .regularExpression) else { continue }
            return String(line[range].dropFirst(#""cwd":""#.count).dropLast())
        }
        return nil
    }

    static func latestClaudeTitle(in data: Data) -> String? {
        var custom: String?
        var generated: String?
        var summary: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            // Cheap filter first: most lines are messages, and parsing them is waste.
            guard line.count < 4_000,
                  let text = String(data: Data(line), encoding: .utf8),
                  text.contains("\"custom-title\"") || text.contains("\"ai-title\"")
                    || text.contains("\"summary\""),
                  let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = json["type"] as? String else { continue }
            switch type {
            case "custom-title": custom = (json["customTitle"] as? String) ?? custom
            case "ai-title": generated = (json["aiTitle"] as? String) ?? generated
            case "summary": summary = (json["summary"] as? String) ?? summary
            default: break
            }
        }
        let title = clean(custom ?? generated ?? summary ?? "")
        return title.isEmpty ? nil : title
    }

    /// Titles reach a one-line row, so no newlines and no runs of spaces.
    static func clean(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}
