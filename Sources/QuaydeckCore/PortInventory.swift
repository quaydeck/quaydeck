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

    public init(runner: CommandRunner = ShellRunner(),
                fileSystem: FileSystemProbe = RealFileSystem(),
                home: String = NSHomeDirectory(),
                userRoots: [String] = []) {
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
            resolveContext(&server, processInfo: processInfo, now: now)
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

        let (kind, label) = classifier.classify(command: server.command,
                                                args: server.args,
                                                hasProject: project != nil)
        server.kind = kind

        switch kind {
        case .devServer:
            if let root = project?.gitRoot ?? project?.path {
                let status = git.status(at: root, now: now)
                server.branch = status.branch
                server.dirty = status.dirty
            }
            server.startedByAgent = classifier.agentName(inAncestry: ancestry(of: server.pid,
                                                                             processInfo: processInfo))
        case .service, .system, .unrecognised:
            server.systemLabel = label
        }
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
