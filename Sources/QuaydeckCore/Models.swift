import Foundation

/// How a listener is categorised once the classifier has looked at it.
public enum ListenerKind: String, Hashable, Sendable {
    /// An interpreter or runtime serving a project you are working on.
    case devServer
    /// Recognised local dev infrastructure: Postgres, Redis, Docker, and friends.
    case service
    /// A known piece of macOS or an installed app. Background noise.
    case system
    /// Something listening from a location we do not trust. Worth a look.
    case unrecognised
}

/// One listening TCP port on this machine, with everything we could resolve about it.
public struct LocalServer: Identifiable, Hashable, Sendable {
    public var id: Int { port }

    public let port: Int
    public let pid: Int32
    /// Short command name, e.g. "node".
    public let command: String
    /// Full argument vector as reported by `ps`.
    public let args: String
    /// Process working directory.
    public let cwd: String

    // Resolved context
    public var kind: ListenerKind = .system
    public var project: String?
    public var projectPath: String?
    public var framework: String?
    public var title: String?
    /// Raw elapsed time from `ps`, e.g. "01:23:45" or "3-04:05:06".
    public var etime: String?
    public var branch: String?
    public var dirty: Bool = false
    public var startedByAgent: String?
    public var respondsHTTP: Bool = false
    public var pinned: Bool = false

    // Monitoring signals
    /// Bound to something other than loopback, so reachable from the local network.
    public var exposed: Bool = false
    /// Friendly name for a recognised non-dev listener.
    public var systemLabel: String?
    public var cpu: Double = 0
    public var memMB: Int = 0
    /// How many instances of this project are listening right now.
    public var duplicateCount: Int = 1
    public var httpStatus: Int?

    public init(port: Int, pid: Int32, command: String, args: String, cwd: String) {
        self.port = port
        self.pid = pid
        self.command = command
        self.args = args
        self.cwd = cwd
    }

    public var url: String { "http://localhost:\(port)" }

    public var isDevServer: Bool { kind == .devServer }
    public var isService: Bool { kind == .service }
    public var unrecognised: Bool { kind == .unrecognised }

    public var busy: Bool { cpu >= 80 }
    /// Answers HTTP but is throwing 5xx: running, but broken.
    public var erroring: Bool { respondsHTTP && (httpStatus ?? 0) >= 500 }
    public var healthText: String? { erroring ? "HTTP \(httpStatus ?? 500)" : nil }
    public var isDuplicate: Bool { duplicateCount > 1 }
    public var cpuText: String? { cpu >= 1 ? "\(Int(cpu.rounded()))%" : nil }
    public var memText: String? { memMB >= 1 ? "\(memMB)MB" : nil }

    /// Untrusted *and* reachable from the network: the genuinely suspicious combination.
    public var suspicious: Bool { unrecognised && exposed }

    /// First line for a dev server, e.g. "acme-site · Astro".
    public var headline: String {
        var bits: [String] = []
        if let project, !project.isEmpty { bits.append(project) }
        if let framework, !framework.isEmpty { bits.append(framework) }
        if bits.isEmpty { bits.append(command) }
        return bits.joined(separator: " · ")
    }

    /// First line for a non-dev listener.
    public var noiseTitle: String { systemLabel ?? command }

    public var gitText: String? { branch.map { "\($0)\(dirty ? " ✦" : "")" } }

    /// `ps` elapsed time parsed into seconds. Handles "ss", "mm:ss", "hh:mm:ss"
    /// and "dd-hh:mm:ss".
    public var uptimeSeconds: Int? {
        guard let etime, !etime.isEmpty else { return nil }
        var days = 0
        var rest = etime
        if let dash = etime.firstIndex(of: "-") {
            days = Int(etime[..<dash]) ?? 0
            rest = String(etime[etime.index(after: dash)...])
        }
        let parts = rest.split(separator: ":").map { Int($0) ?? 0 }
        var hours = 0, minutes = 0, seconds = 0
        switch parts.count {
        case 3: hours = parts[0]; minutes = parts[1]; seconds = parts[2]
        case 2: minutes = parts[0]; seconds = parts[1]
        case 1: seconds = parts[0]
        default: return nil
        }
        return ((days * 24 + hours) * 60 + minutes) * 60 + seconds
    }

    public var uptimeText: String? {
        guard let total = uptimeSeconds else { return nil }
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total % 60)s"
    }

    public var isNew: Bool { (uptimeSeconds ?? 999) < 45 }

    /// Second line for a dev server row.
    public var subtitle: String? {
        var parts: [String] = []
        if let healthText { parts.append(healthText) }
        if let title, !title.isEmpty { parts.append("“\(title)”") }
        if let gitText { parts.append(gitText) }
        if let uptimeText { parts.append(uptimeText) }
        if let cpuText { parts.append(cpuText) }
        if let memText { parts.append(memText) }
        if let startedByAgent { parts.append(startedByAgent) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Matches an already-lowercased search query against the useful fields.
    public func matches(_ query: String) -> Bool {
        if query.isEmpty { return true }
        if "\(port)".contains(query) { return true }
        if command.lowercased().contains(query) { return true }
        if let project, project.lowercased().contains(query) { return true }
        if let title, title.lowercased().contains(query) { return true }
        if let framework, framework.lowercased().contains(query) { return true }
        if let systemLabel, systemLabel.lowercased().contains(query) { return true }
        return false
    }
}

/// A dev-runtime process burning resources with no listening port: a hung `tsc --watch`,
/// a stuck build, an orphaned node. The things you want to find and kill.
public struct BusyProcess: Identifiable, Hashable, Sendable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let command: String
    public let project: String?
    public let projectPath: String?
    /// Instantaneous percentage, can exceed 100 across cores.
    public let cpu: Int
    public let memMB: Int

    public init(pid: Int32, command: String, project: String?, projectPath: String?, cpu: Int, memMB: Int) {
        self.pid = pid
        self.command = command
        self.project = project
        self.projectPath = projectPath
        self.cpu = cpu
        self.memMB = memMB
    }
}

/// One complete look at the machine.
public struct Snapshot: Hashable, Sendable {
    public var servers: [LocalServer]
    public var busyProcesses: [BusyProcess]

    public init(servers: [LocalServer] = [], busyProcesses: [BusyProcess] = []) {
        self.servers = servers
        self.busyProcesses = busyProcesses
    }

    public var devServers: [LocalServer] {
        servers.filter(\.isDevServer)
            .sorted { ($0.pinned ? 0 : 1, $0.port) < ($1.pinned ? 0 : 1, $1.port) }
    }

    /// Anything that is not a dev server, with the things worth a second look on top:
    /// unrecognised first, then recognised services, then the rest by port.
    public var otherServers: [LocalServer] {
        servers.filter { !$0.isDevServer }.sorted { a, b in
            (a.unrecognised ? 0 : 1, a.isService ? 0 : 1, a.port)
                < (b.unrecognised ? 0 : 1, b.isService ? 0 : 1, b.port)
        }
    }

    public var hasAlerts: Bool { servers.contains(where: \.unrecognised) }
}
