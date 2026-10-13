import Foundation

/// The one thing the app asks for: a complete picture of what is listening.
///
/// Everything below this type is an implementation detail. Give it a `CommandRunner`
/// and a `FileSystemProbe` and it will answer the same way whether those are real or
/// recorded, which is what makes the whole pipeline testable.
public final class PortInventory: @unchecked Sendable {
    private let listenerSource: ListenerSource
    private let processSource: ProcessSource
    private let resolver: ProjectResolver
    private let frameworks: FrameworkDetector
    private let git: GitInspector
    private let classifier: Classifier
    private let busyDetector: BusyProcessDetector
    private let environment: EnvironmentProbing
    private let agents = AgentDetector()
    private let sessionTitles: SessionTitles
    private let docker: DockerSource

    public init(runner: CommandRunner = ShellRunner(),
                fileSystem: FileSystemProbe = RealFileSystem(),
                environment: EnvironmentProbing = ProcessEnvironment(),
                home: String = NSHomeDirectory(),
                userRoots: [String] = []) {
        self.environment = environment
        self.sessionTitles = SessionTitles(fileSystem: fileSystem, home: home)
        self.docker = DockerSource(runner: runner, fileSystem: fileSystem, home: home)
        self.listenerSource = ListenerSource(runner: runner)
        self.processSource = ProcessSource(runner: runner)
        self.resolver = ProjectResolver(fileSystem: fileSystem, home: home, userRoots: userRoots)
        self.frameworks = FrameworkDetector(fileSystem: fileSystem)
        self.git = GitInspector(runner: runner)
        self.classifier = Classifier(home: home)
        self.busyDetector = BusyProcessDetector(processes: processSource, resolver: resolver)
    }

    /// One complete look at the machine. Safe to call off the main thread; it forks
    /// several short-lived processes and should never be called on it.
    public func snapshot(now: Date = Date(), includeBusyProcesses: Bool = true) -> Snapshot {
        let listeners = listenerSource.listeners()
        guard !listeners.isEmpty else { return Snapshot() }

        // An IPv4 and an IPv6 binding for the same server are two rows from lsof and
        // one server to a human. Collapse them, and treat the merged row as exposed if
        // any single binding was.
        var byPort: [Int: (pid: Int32, command: String, exposed: Bool)] = [:]
        for listener in listeners {
            if let existing = byPort[listener.port] {
                byPort[listener.port] = (existing.pid, existing.command,
                                         existing.exposed || listener.exposed)
            } else {
                byPort[listener.port] = (listener.pid, listener.command, listener.exposed)
            }
        }

        let pids = Set(byPort.values.map(\.pid))
        let processInfo = processSource.info(for: pids)
        let workingDirectories = listenerSource.workingDirectories(for: pids)

        // Only ask Docker when its proxy is actually holding a port.
        let published = byPort.values.contains { DockerSource.isContainerRuntime(command: $0.command) }
            ? docker.publishedPorts()
            : [:]

        var servers = byPort.map { port, holder -> LocalServer in
            let info = processInfo[holder.pid]
            var server = LocalServer(
                port: port,
                pid: holder.pid,
                // lsof's command name survives spaces in binary paths; an argv[0]
                // split does not.
                command: holder.command.isEmpty ? (info?.command ?? "") : holder.command,
                args: info?.args ?? "",
                cwd: workingDirectories[holder.pid] ?? "/"
            )
            server.etime = info?.etime
            server.cpu = info?.cpu ?? 0
            server.memMB = (info?.rssKB ?? 0) / 1024
            server.exposed = holder.exposed
            if let mapping = published[port], DockerSource.isContainerRuntime(command: server.command) {
                resolveContainer(&server, mapping)
            } else {
                resolveContext(&server, processInfo: processInfo, now: now)
            }
            return server
        }

        applyDuplicateCounts(&servers)
        servers.sort { ($0.isDevServer ? 0 : 1, $0.port) < ($1.isDevServer ? 0 : 1, $1.port) }

        let busy = includeBusyProcesses
            ? busyDetector.detect(excluding: pids, now: now)
            : []

        return Snapshot(servers: servers, busyProcesses: busy)
    }

    // MARK: - Context

    private func resolveContext(_ server: inout LocalServer,
                                processInfo: [Int32: ProcInfo],
                                now: Date) {
        let project = resolver.resolve(cwd: server.cwd, args: server.args)
        server.projectPath = project?.path
        server.project = project?.name
        server.framework = frameworks.detect(args: server.args,
                                             command: server.command,
                                             projectPath: project?.path)

        var (kind, label) = classifier.classify(command: server.command,
                                                args: server.args,
                                                hasProject: project != nil)

        // Who started it. Asked for dev servers; for project-less runtimes, which are
        // exactly the previews agents leave in chat folders; and for unrecognised
        // listeners, so an alert can say "started by Claude". That stays an alert:
        // markers are only environment variables, which anything can set, so they
        // explain a listener but never vouch for one.
        var attribution: AgentAttribution?
        let projectless = project == nil && kind != .service
            && classifier.mightBeProjectlessServer(command: server.command, args: server.args, cwd: server.cwd)
        if kind == .devServer || projectless || kind == .unrecognised {
            attribution = agents.attribute(
                environment: environment.markers(of: server.pid),
                ancestry: ancestry(of: server.pid, processInfo: processInfo)
            )
        }
        if projectless, classifier.isProjectlessServer(command: server.command, args: server.args,
                                                       cwd: server.cwd, startedByAgent: attribution != nil) {
            kind = .devServer
            label = nil
            server.folder = Self.folderName(servedBy: server.args, cwd: server.cwd)
        }
        server.kind = kind

        switch kind {
        case .devServer:
            if let root = project?.gitRoot ?? project?.path {
                let status = git.status(at: root, now: now)
                server.branch = status.branch
                server.dirty = status.dirty
            }
            if let attribution {
                server.agent = attribution.agent
                server.agentSession = sessionTitles.title(for: attribution, now: now)
            }
        case .unrecognised:
            server.systemLabel = label
            server.agent = attribution?.agent
        case .service, .system, .container:
            server.systemLabel = label
        }
    }

    /// A published container port. The process holding it is the runtime's proxy, so
    /// its CPU, memory and uptime describe Docker, not this container, and are dropped.
    private func resolveContainer(_ server: inout LocalServer, _ mapping: PublishedPort) {
        server.kind = .container
        server.container = mapping.container
        server.containerPort = mapping.containerPort
        server.systemLabel = mapping.container.imageLabel
        server.cpu = 0
        server.memMB = 0
        server.etime = nil
        if let directory = mapping.container.composeDirectory,
           let project = resolver.resolve(cwd: directory, args: "") {
            server.project = project.name
            server.projectPath = project.path
        }
    }

    /// Folders that say nothing on their own; the one above them names the work.
    static let genericFolders: Set<String> = [
        "outputs", "output", "out", "dist", "build", "public", "site", "www", "static",
        "scratchpad", "tmp", "temp", "preview", "previews",
    ]

    /// The folder a project-less server is serving: `--directory X` when given,
    /// otherwise its working directory. Named by its last meaningful component.
    static func folderName(servedBy args: String, cwd: String) -> String? {
        var directory = cwd
        let tokens = args.split(separator: " ").map(String.init)
        if let flag = tokens.firstIndex(where: { $0 == "--directory" || $0 == "-d" }), flag + 1 < tokens.count {
            let value = tokens[flag + 1]
            directory = value.hasPrefix("/") ? value : cwd + "/" + value
        } else if let inline = tokens.first(where: { $0.hasPrefix("--directory=") }) {
            let value = String(inline.dropFirst("--directory=".count))
            directory = value.hasPrefix("/") ? value : cwd + "/" + value
        }
        var components = directory.split(separator: "/").map(String.init)
        while components.last == "." { components.removeLast() }
        guard let last = components.last else { return nil }
        if genericFolders.contains(last.lowercased()), components.count >= 2 {
            let parent = components[components.count - 2]
            // A Claude scratchpad sits under a session uuid; "scratchpad" is clearer.
            let looksGenerated = parent.count >= 32 && parent.filter({ $0 == "-" }).count >= 4
            if !looksGenerated, !parent.hasPrefix("-") { return parent + "/" + last }
        }
        return last
    }

    /// Argument vectors of a process and its ancestors, nearest first. Used to work
    /// out whether a coding agent started this server.
    private func ancestry(of pid: Int32, processInfo: [Int32: ProcInfo], maxDepth: Int = 16) -> [String] {
        var result: [String] = []
        var current = pid
        var known = processInfo
        var depth = 0

        while depth < maxDepth {
            guard let info = known[current] ?? processSource.one(current) else { break }
            result.append(info.args)
            known[current] = info
            guard info.ppid > 1, info.ppid != current else { break }
            current = info.ppid
            depth += 1
        }
        return result
    }

    /// How many dev servers share a project path. Two instances of the same project
    /// almost always means you forgot to stop the first one.
    private func applyDuplicateCounts(_ servers: inout [LocalServer]) {
        var counts: [String: Int] = [:]
        for server in servers where server.isDevServer {
            if let path = server.projectPath { counts[path, default: 0] += 1 }
        }
        for index in servers.indices where servers[index].isDevServer {
            if let path = servers[index].projectPath {
                servers[index].duplicateCount = counts[path] ?? 1
            }
        }
    }
}
