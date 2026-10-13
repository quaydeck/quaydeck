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
    private let signatures: SignatureChecking

    /// What is known about a listening process that does not change while it runs:
    /// its project, framework, classification and who started it. Worked out once per
    /// process rather than on every scan, which also spares the parent walk and the
    /// dozens of file checks behind finding a project.
    private struct Context {
        let project: Project?
        let framework: String?
        let kind: ListenerKind
        let label: String?
        let attribution: AgentAttribution?
        let folder: String?
        let resolved: Date
    }

    private let cacheLock = NSLock()
    private var contexts: [String: Context] = [:]
    private var dockerCache: (ports: Set<Int>, at: Date, result: [Int: PublishedPort])?

    /// A package.json or `git init` can appear after a server starts, so a context is
    /// re-derived every couple of minutes rather than kept for the life of the process.
    private static let contextLifetime: TimeInterval = 120

    /// `readsKernel` picks how sockets and processes are read. Left nil, a real
    /// `ShellRunner` gets the kernel path and any other runner gets `lsof` and `ps`,
    /// so recorded fixtures keep driving the whole pipeline.
    public init(runner: CommandRunner = ShellRunner(),
                fileSystem: FileSystemProbe = RealFileSystem(),
                environment: EnvironmentProbing = ProcessEnvironment(),
                signatures: SignatureChecking = CodeSignatureChecker(),
                home: String = NSHomeDirectory(),
                userRoots: [String] = [],
                readsKernel: Bool? = nil) {
        self.environment = environment
        self.signatures = signatures
        self.sessionTitles = SessionTitles(fileSystem: fileSystem, home: home)
        self.docker = DockerSource(runner: runner, fileSystem: fileSystem, home: home)
        if readsKernel ?? (runner is ShellRunner) {
            let kernel = KernelSource()
            self.listenerSource = ListenerSource(kernel: kernel)
            self.processSource = ProcessSource(kernel: kernel)
        } else {
            self.listenerSource = ListenerSource(runner: runner)
            self.processSource = ProcessSource(runner: runner)
        }
        self.resolver = ProjectResolver(fileSystem: fileSystem, home: home, userRoots: userRoots)
        self.frameworks = FrameworkDetector(fileSystem: fileSystem)
        self.git = GitInspector(runner: runner)
        self.classifier = Classifier(home: home)
        self.busyDetector = BusyProcessDetector(processes: processSource, resolver: resolver)
    }

    /// One complete look at the machine. Safe to call off the main thread, and never
    /// to be called on it.
    ///
    /// `interactive` is whether someone is looking at the result. When nobody is, git
    /// state and Docker's container list are refreshed far less often: they only show
    /// in the menu, and a closed menu is most of the day.
    public func snapshot(now: Date = Date(), includeBusyProcesses: Bool = true,
                         interactive: Bool = true) -> Snapshot {
        let listeners = listenerSource.listeners()
        guard !listeners.isEmpty else { return Snapshot() }

        // An IPv4 and an IPv6 binding for the same server are two sockets and one
        // server to a human. Collapse them, and treat the merged row as exposed if any
        // single binding was.
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
        let published = publishedPorts(byPort, now: now, maxAge: interactive ? 10 : 60)
        let gitAge: TimeInterval = interactive ? 8 : 60

        var liveKeys = Set<String>()
        var servers = byPort.map { port, holder -> LocalServer in
            let info = processInfo[holder.pid]
            var server = LocalServer(
                port: port,
                pid: holder.pid,
                // The kernel's process name survives spaces in binary paths; an argv[0]
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
                let key = "\(server.pid)|\(server.cwd)|\(server.args)"
                liveKeys.insert(key)
                apply(context(for: server, key: key, processInfo: processInfo, now: now),
                      to: &server, now: now, gitAge: gitAge)
            }
            return server
        }

        cacheLock.lock()
        contexts = contexts.filter { liveKeys.contains($0.key) }
        cacheLock.unlock()

        applyDuplicateCounts(&servers)
        servers.sort { ($0.isDevServer ? 0 : 1, $0.port) < ($1.isDevServer ? 0 : 1, $1.port) }

        let busy = includeBusyProcesses
            ? busyDetector.detect(excluding: pids, now: now)
            : []

        return Snapshot(servers: servers, busyProcesses: busy)
    }

    // MARK: - Docker

    /// Docker's container list, asked for only when its proxy holds a port, and then
    /// only when the set of ports it holds has changed or the last answer is old.
    /// Ports cannot change without the set changing; only status and health drift.
    private func publishedPorts(_ byPort: [Int: (pid: Int32, command: String, exposed: Bool)],
                                now: Date, maxAge: TimeInterval) -> [Int: PublishedPort] {
        let held = Set(byPort.filter { DockerSource.isContainerRuntime(command: $0.value.command) }.keys)
        guard !held.isEmpty else { return [:] }
        cacheLock.lock()
        if let cached = dockerCache, cached.ports == held, now.timeIntervalSince(cached.at) < maxAge {
            cacheLock.unlock()
            return cached.result
        }
        cacheLock.unlock()
        let result = docker.publishedPorts()
        cacheLock.lock()
        dockerCache = (held, now, result)
        cacheLock.unlock()
        return result
    }

    // MARK: - Context

    private func context(for server: LocalServer, key: String,
                         processInfo: [Int32: ProcInfo], now: Date) -> Context {
        cacheLock.lock()
        if let cached = contexts[key], now.timeIntervalSince(cached.resolved) < Self.contextLifetime {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let project = resolver.resolve(cwd: server.cwd, args: server.args)
        let framework = frameworks.detect(args: server.args, command: server.command,
                                          projectPath: project?.path)
        var (kind, label) = classifier.classify(command: server.command,
                                                args: server.args,
                                                hasProject: project != nil)

        // An odd install location is outweighed by a signature Apple issued: Figma's
        // font helper lives in ~/Library/Application Support and is signed by Figma.
        // Only asked for listeners that would otherwise be flagged.
        if kind == .unrecognised, let signer = signatures.trustedSigner(of: server.pid) {
            kind = .system
            label = label ?? "\(server.command) (\(signer))"
        }

        // Who started it. Asked for dev servers; for project-less runtimes, which are
        // exactly the previews agents leave in chat folders; and for unrecognised
        // listeners, so an alert can say "started by Claude". That stays an alert:
        // markers are only environment variables, which anything can set, so they
        // explain a listener but never vouch for one.
        var attribution: AgentAttribution?
        var folder: String?
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
            folder = Self.folderName(servedBy: server.args, cwd: server.cwd)
        }

        let context = Context(project: project, framework: framework, kind: kind, label: label,
                              attribution: attribution, folder: folder, resolved: now)
        cacheLock.lock()
        contexts[key] = context
        cacheLock.unlock()
        return context
    }

    private func apply(_ context: Context, to server: inout LocalServer, now: Date, gitAge: TimeInterval) {
        server.projectPath = context.project?.path
        server.project = context.project?.name
        server.framework = context.framework
        server.folder = context.folder
        server.kind = context.kind

        switch context.kind {
        case .devServer:
            if let root = context.project?.gitRoot ?? context.project?.path {
                let status = git.status(at: root, now: now, maxAge: gitAge)
                server.branch = status.branch
                server.dirty = status.dirty
            }
            if let attribution = context.attribution {
                server.agent = attribution.agent
                server.agentSession = sessionTitles.title(for: attribution, now: now)
            }
        case .unrecognised:
            server.systemLabel = context.label
            server.agent = context.attribution?.agent
        case .service, .system, .container:
            server.systemLabel = context.label
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
