import Foundation
import QuaydeckCore

/// A project Quaydeck has seen running, so it can be restarted from memory after it
/// has stopped.
public struct HistoryEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: String { projectPath }
    public let projectPath: String
    public var project: String
    public var framework: String?
    public var lastPort: Int
    public var lastSeen: Date
}

/// Everything Quaydeck remembers between launches. All of it lives in UserDefaults on
/// this machine; none of it goes anywhere else.
@MainActor
public final class Preferences: ObservableObject {
    private enum Key {
        static let pinned = "pinnedProjects"
        static let notifications = "notificationsEnabled"
        static let history = "projectHistory"
        static let roots = "projectRoots"
        static let completedFirstRun = "completedFirstRun"
        static let checkForUpdates = "checkForUpdates"
        static let collapsedSections = "collapsedSections"
    }

    private let defaults: UserDefaults

    @Published public var pinnedProjects: Set<String> {
        didSet { defaults.set(Array(pinnedProjects), forKey: Key.pinned) }
    }

    @Published public var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notifications) }
    }

    /// Directories the user has nominated as holding their projects. Optional: project
    /// detection works without it, this only improves naming for projects that carry
    /// no manifest.
    @Published public var projectRoots: [String] {
        didSet { defaults.set(projectRoots, forKey: Key.roots) }
    }

    @Published public var history: [HistoryEntry] {
        didSet {
            if let data = try? JSONEncoder().encode(history) {
                defaults.set(data, forKey: Key.history)
            }
        }
    }

    /// Whether the welcome screen has been shown and dismissed.
    @Published public var completedFirstRun: Bool {
        didSet { defaults.set(completedFirstRun, forKey: Key.completedFirstRun) }
    }

    @Published public var checkForUpdates: Bool {
        didSet { defaults.set(checkForUpdates, forKey: Key.checkForUpdates) }
    }

    /// Menu sections folded shut: "you", "claude", "codex", "docker" and so on.
    @Published public var collapsedSections: Set<String> {
        didSet { defaults.set(Array(collapsedSections), forKey: Key.collapsedSections) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.pinnedProjects = Set(defaults.stringArray(forKey: Key.pinned) ?? [])
        self.notificationsEnabled = defaults.bool(forKey: Key.notifications)
        self.projectRoots = defaults.stringArray(forKey: Key.roots) ?? []
        self.completedFirstRun = defaults.bool(forKey: Key.completedFirstRun)
        // Default on, but only once the user has been through the welcome screen.
        self.checkForUpdates = defaults.object(forKey: Key.checkForUpdates) as? Bool ?? true
        self.collapsedSections = Set(defaults.stringArray(forKey: Key.collapsedSections) ?? [])
        if let data = defaults.data(forKey: Key.history),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            self.history = decoded
        } else {
            self.history = []
        }
    }

    // MARK: - History

    private static let historyLimit = 30

    public func rememberRunning(_ servers: [LocalServer]) {
        var byPath = Dictionary(history.map { ($0.projectPath, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Date()
        for server in servers where server.isDevServer {
            guard let path = server.projectPath, let name = server.project else { continue }
            byPath[path] = HistoryEntry(projectPath: path, project: name,
                                        framework: server.framework, lastPort: server.port,
                                        lastSeen: now)
        }
        history = Array(byPath.values.sorted { $0.lastSeen > $1.lastSeen }.prefix(Self.historyLimit))
    }

    public func forget(_ entry: HistoryEntry) {
        history.removeAll { $0.projectPath == entry.projectPath }
    }

    /// Projects we have seen run that are not running now.
    public func recentlyStopped(given servers: [LocalServer]) -> [HistoryEntry] {
        let running = Set(servers.filter(\.isDevServer).compactMap(\.projectPath))
        return history.filter { !running.contains($0.projectPath) }
    }

    // MARK: - Pins

    public func isPinned(_ path: String?) -> Bool {
        guard let path else { return false }
        return pinnedProjects.contains(path)
    }

    public func togglePin(_ path: String?) {
        guard let path else { return }
        if pinnedProjects.contains(path) {
            pinnedProjects.remove(path)
        } else {
            pinnedProjects.insert(path)
        }
    }
}
