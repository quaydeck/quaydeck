import Foundation

/// A specific, actionable thing worth telling the user, derived only from signals
/// already collected. No network, no model, no telemetry: just arithmetic over a
/// snapshot.
public struct Advice: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case unrecognised, exposed, memoryHog, duplicate, stale, runaway, erroring
    }

    public enum Severity: Int, Comparable, Sendable {
        case critical = 0, warning = 1, info = 2
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    /// Stable across scans, so dismissing one makes it stay dismissed until the
    /// underlying condition actually changes.
    public let id: String
    public let kind: Kind
    public let severity: Severity
    public let icon: String
    public let text: String
    public let actionLabel: String?
    public let port: Int?
    public let projectPath: String?
    public let pid: Int32?

    public init(id: String, kind: Kind, severity: Severity, icon: String, text: String,
                actionLabel: String?, port: Int? = nil, projectPath: String? = nil, pid: Int32? = nil) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.icon = icon
        self.text = text
        self.actionLabel = actionLabel
        self.port = port
        self.projectPath = projectPath
        self.pid = pid
    }
}

public struct Advisor: Sendable {
    /// Memory at which a dev server is worth mentioning.
    private let memoryThresholdMB: Int
    /// Idle time after which a server is probably forgotten.
    private let staleAfter: TimeInterval

    public init(memoryThresholdMB: Int = 1000, staleAfter: TimeInterval = 86_400) {
        self.memoryThresholdMB = memoryThresholdMB
        self.staleAfter = staleAfter
    }

    public func build(from snapshot: Snapshot) -> [Advice] {
        var result: [Advice] = []
        result += runawayAdvice(snapshot.busyProcesses)
        result += erroringAdvice(snapshot.servers)
        result += unrecognisedAdvice(snapshot.servers)
        result += memoryAdvice(snapshot.servers)
        result += exposedAdvice(snapshot.servers)
        result += duplicateAdvice(snapshot.servers)
        result += staleAdvice(snapshot.servers)
        return result.sorted { ($0.severity, $0.id) < ($1.severity, $1.id) }
    }

    // MARK: - Individual rules

    private func runawayAdvice(_ busy: [BusyProcess]) -> [Advice] {
        busy.map { process in
            let detail = process.cpu >= 70 ? "pegging \(process.cpu)% CPU" : "holding \(process.memMB) MB"
            return Advice(
                id: "busy:\(process.pid)",
                kind: .runaway,
                severity: .warning,
                icon: "bolt.fill",
                text: "\(process.project ?? process.command) (\(process.command)) is \(detail) with no server. Hung build?",
                actionLabel: "Quit",
                pid: process.pid
            )
        }
    }

    private func erroringAdvice(_ servers: [LocalServer]) -> [Advice] {
        servers.filter { $0.isDevServer && $0.erroring }.map { server in
            Advice(
                id: "erroring:\(server.port)",
                kind: .erroring,
                severity: .warning,
                icon: "exclamationmark.octagon.fill",
                text: "\(server.project ?? "A server") on :\(server.port) is returning HTTP \(server.httpStatus ?? 500).",
                actionLabel: "Open",
                port: server.port
            )
        }
    }

    private func unrecognisedAdvice(_ servers: [LocalServer]) -> [Advice] {
        servers.filter(\.unrecognised).map { server in
            let network = server.exposed ? " and is reachable on your network" : ""
            let origin = server.agent.map { " Started by \($0.displayName)." } ?? ""
            return Advice(
                id: "unrecognised:\(server.port)",
                kind: .unrecognised,
                // Reachable from the network is the alarming case. Bound to this Mac
                // only, it is worth a look rather than a red banner.
                severity: server.exposed ? .critical : .warning,
                icon: "exclamationmark.shield.fill",
                text: "\(server.command) is listening on :\(server.port) from an untrusted path\(network).\(origin)",
                actionLabel: "Quit",
                port: server.port
            )
        }
    }

    private func memoryAdvice(_ servers: [LocalServer]) -> [Advice] {
        servers.filter { $0.memMB >= memoryThresholdMB }.map { server in
            Advice(
                id: "memory:\(server.port)",
                kind: .memoryHog,
                severity: .warning,
                icon: "memorychip",
                text: "\(label(server)) on :\(server.port) is using \(server.memMB) MB.",
                actionLabel: "Quit",
                port: server.port
            )
        }
    }

    /// Skipped for projects already flagged as duplicates: one clear message beats two
    /// overlapping ones. Containers count too: Docker publishes on every interface
    /// unless told `127.0.0.1:`, which is how a database ends up on the café wifi.
    private func exposedAdvice(_ servers: [LocalServer]) -> [Advice] {
        let duplicatePaths = Set(servers.filter { $0.isDevServer && $0.isDuplicate }
            .compactMap(\.projectPath))
        return servers
            .filter { ($0.isDevServer || $0.isContainer) && $0.exposed
                && !($0.isDevServer && (($0.projectPath).map(duplicatePaths.contains) ?? false)) }
            .map { server in
                Advice(
                    id: "exposed:\(server.port)",
                    kind: .exposed,
                    severity: .warning,
                    icon: "globe",
                    text: "\(label(server)) on :\(server.port) is reachable from your local network.",
                    actionLabel: nil,
                    port: server.port
                )
            }
    }

    private func duplicateAdvice(_ servers: [LocalServer]) -> [Advice] {
        var seen = Set<String>()
        var result: [Advice] = []
        for server in servers where server.isDevServer && server.isDuplicate {
            guard let path = server.projectPath, seen.insert(path).inserted else { continue }
            result.append(Advice(
                id: "duplicate:\(path)",
                kind: .duplicate,
                severity: .info,
                icon: "square.on.square",
                text: "\(server.project ?? "A project") is running \(server.duplicateCount) times. Keep the oldest?",
                actionLabel: "Quit extras",
                port: server.port,
                projectPath: path
            ))
        }
        return result
    }

    private func staleAdvice(_ servers: [LocalServer]) -> [Advice] {
        servers
            .filter { $0.isDevServer && Double($0.uptimeSeconds ?? 0) > staleAfter && $0.cpu < 1 }
            .map { server in
                Advice(
                    id: "stale:\(server.port)",
                    kind: .stale,
                    severity: .info,
                    icon: "clock.badge.questionmark",
                    text: "\(label(server)) has been idle for \(server.uptimeText ?? "a while"). Still need it?",
                    actionLabel: "Quit",
                    port: server.port
                )
            }
    }

    private func label(_ server: LocalServer) -> String {
        if let container = server.container { return container.name }
        return server.project ?? server.folder ?? server.systemLabel ?? server.command
    }
}
