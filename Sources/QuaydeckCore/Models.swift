import Foundation

/// How a listener is categorised once the classifier has looked at it.
public enum ListenerKind: String, Hashable, Sendable {
    /// An interpreter or runtime serving a project you are working on.
    case devServer
    /// Recognised local dev infrastructure: Postgres, Redis, Docker, and friends.
    case service
    /// A port a Docker container publishes, held on the Mac by the runtime's proxy.
    case container
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
    /// The coding agent that started this server, or this unrecognised listener; nil
    /// when you did, or when nothing says who did.
    public var agent: CodingAgent?
    /// The title of the agent session that started it: the Codex chat name or the
    /// Claude Code session title.
    public var agentSession: String?
    /// Claude Code's session id or Codex's thread id.
    public var agentSessionID: String?
    /// Where that agent keeps its data, when not the default (CLAUDE_CONFIG_DIR).
    public var agentHome: String?
    /// The folder the Claude session runs in.
    public var agentSessionDirectory: String?
    /// The session that started it has ended; the server kept running.
    public var agentDetached: Bool = false

    /// Still running 30 minutes after the session that started it ended: almost always
    /// a preview nobody is looking at any more.
    public var leftBehind: Bool {
        isDevServer && agent != nil && agentDetached && (uptimeSeconds ?? 0) > 1_800
    }
    /// For a server with no project manifest: the folder it serves, so the row still
    /// says something more useful than "Python".
    public var folder: String?
    /// The container behind a published port, for `.container` listeners.
    public var container: ContainerInfo?
    /// The port inside that container.
    public var containerPort: Int?
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
    public var isContainer: Bool { kind == .container }
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

    /// Container ports that speak a database or broker protocol. Never sent an HTTP
    /// probe: some servers count a garbled handshake as a failed login, and a probe
    /// every few seconds would eventually get the Mac's address blocked.
    static let nonHTTPContainerPorts: Set<Int> = [
        1433, 1521, 2181, 3306, 4222, 5432, 5672, 6379, 7687, 9042, 9092, 11211, 26257, 27017,
    ]

    /// Whether the health probe should ask this port for a page.
    public var probeable: Bool {
        switch kind {
        case .devServer: return true
        case .container:
            guard let containerPort else { return false }
            return !Self.nonHTTPContainerPorts.contains(containerPort) && containerPort != 443
        case .service, .system, .unrecognised: return false
        }
    }

    /// First line for a dev server, e.g. "acme-site · Astro".
    public var headline: String {
        var bits: [String] = []
        if let project, !project.isEmpty {
            bits.append(project)
        } else if let folder, !folder.isEmpty {
            bits.append(folder)
        }
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
        if let folder, folder.lowercased().contains(query) { return true }
        if let agent, agent.displayName.lowercased().contains(query) { return true }
        if let agentSession, agentSession.lowercased().contains(query) { return true }
        if let container {
            if container.name.lowercased().contains(query) { return true }
            if container.image.lowercased().contains(query) { return true }
            if let compose = container.composeProject, compose.lowercased().contains(query) { return true }
            if "docker".contains(query) { return true }
        }
        return false
    }
}

/// Dev servers that share an origin: the ones you started, or the ones one agent did.
public struct ServerGroup: Identifiable, Hashable, Sendable {
    /// Nil for servers you started yourself.
    public let agent: CodingAgent?
    public let servers: [LocalServer]

    public var id: String { agent?.rawValue ?? "you" }
}

/// Every published port of one container, shown as one row.
public struct ContainerGroup: Identifiable, Hashable, Sendable {
    public let container: ContainerInfo
    /// Sorted by host port.
    public let ports: [LocalServer]

    public var id: String { container.id }

    /// The project the compose file lives in, when Quaydeck could trace it.
    public var project: String? { ports.lazy.compactMap(\.project).first }
    public var projectPath: String? { ports.lazy.compactMap(\.projectPath).first }

    /// "papendorp-community", falling back to the compose project, then the
    /// container name.
    public var title: String {
        project ?? container.composeProject ?? container.name
    }

    /// The compose service, when it says something the title does not.
    public var service: String? {
        guard let service = container.composeService, service != title else { return nil }
        return service
    }

    /// The port a click should open: the first that answers HTTP, else the first
    /// that could, else the first.
    public var primary: LocalServer {
        ports.first(where: \.respondsHTTP)
            ?? ports.first(where: { $0.containerPort == 80 || $0.containerPort == 8080 })
            ?? ports.first(where: \.probeable)
            ?? ports[0]
    }

    public var exposed: Bool { ports.contains(where: \.exposed) }

    /// The address to open: the site's own hostname when it has one (DDEV), else the
    /// primary port.
    public var openURL: String { container.siteURL?.absoluteString ?? primary.url }

    /// ":58610→80  :58609→443"
    public var portsText: String {
        ports.map { port in
            guard let inside = port.containerPort, inside != port.port else { return ":\(port.port)" }
            return ":\(port.port)→\(inside)"
        }.joined(separator: "  ")
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

    /// Dev servers split by who started them: yours first, then one group per agent.
    public var devServerGroups: [ServerGroup] {
        ServerGroup.grouping(devServers)
    }

    /// Published container ports, one entry per container, ordered by compose project
    /// so a stack's containers sit together.
    public var containers: [ContainerGroup] {
        ContainerGroup.grouping(servers.filter(\.isContainer))
    }

    /// Anything that is not a dev server or a container, with the things worth a
    /// second look on top: unrecognised first, then recognised services, then the
    /// rest by port.
    public var otherServers: [LocalServer] {
        servers.filter { !$0.isDevServer && !$0.isContainer }.sorted { a, b in
            (a.unrecognised ? 0 : 1, a.isService ? 0 : 1, a.port)
                < (b.unrecognised ? 0 : 1, b.isService ? 0 : 1, b.port)
        }
    }

    public var hasAlerts: Bool { servers.contains(where: \.unrecognised) }
}

extension ServerGroup {
    /// Keeps the order it is given within each group.
    public static func grouping(_ servers: [LocalServer]) -> [ServerGroup] {
        var groups: [ServerGroup] = []
        let yours = servers.filter { $0.agent == nil }
        if !yours.isEmpty { groups.append(ServerGroup(agent: nil, servers: yours)) }
        for agent in CodingAgent.allCases {
            let started = servers.filter { $0.agent == agent }
            if !started.isEmpty { groups.append(ServerGroup(agent: agent, servers: started)) }
        }
        return groups
    }
}

extension ContainerGroup {
    public static func grouping(_ servers: [LocalServer]) -> [ContainerGroup] {
        var byID: [String: (container: ContainerInfo, ports: [LocalServer])] = [:]
        for server in servers {
            guard let container = server.container else { continue }
            byID[container.id, default: (container, [])].ports.append(server)
        }
        return byID.values
            .map { ContainerGroup(container: $0.container, ports: $0.ports.sorted { $0.port < $1.port }) }
            .sorted { ($0.container.composeProject ?? $0.title, $0.title, $0.ports[0].port)
                    < ($1.container.composeProject ?? $1.title, $1.title, $1.ports[0].port) }
    }
}
