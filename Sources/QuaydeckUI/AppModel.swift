import Combine
import Foundation
import QuaydeckCore

/// Owns the current picture of the machine and everything the menu can do to it.
@MainActor
public final class AppModel: ObservableObject {

    @Published public private(set) var snapshot = Snapshot()
    @Published public private(set) var scanning = false
    @Published public private(set) var lastScan: Date?
    @Published public var searchText = ""
    @Published public var dismissedAdvice: Set<String> = []

    public let preferences: Preferences
    public let loginItem: LoginItem
    public let actions = SystemActions()

    private let entitlements: Entitlements
    private let advisor = Advisor()
    private let probe: HealthProbing
    private let control: ProcessControlling
    private let containers: ContainerControlling
    private var inventory: PortInventory

    /// Poll quickly while the menu is open and slowly when it is not. Scanning forks
    /// several processes, so doing it every three seconds in the background would be
    /// rude on a laptop battery.
    private let openInterval: TimeInterval = 3
    private let idleInterval: TimeInterval = 20
    private var timer: Timer?
    private var menuIsOpen = false

    /// Health results survive between scans so a row does not flicker back to
    /// "no response" while the next probe is in flight.
    private var healthCache: [Int: HealthResult] = [:]
    private var knownPorts: Set<Int> = []
    private var hasScannedOnce = false
    private var cancellables: Set<AnyCancellable> = []

    /// `preferences` and `loginItem` are optional rather than defaulted, because a
    /// default argument is evaluated outside the actor and both are main-actor types.
    public init(preferences: Preferences? = nil,
                loginItem: LoginItem? = nil,
                entitlements: Entitlements = FreeEntitlements(),
                probe: HealthProbing = HealthProbe(),
                runner: CommandRunner = ShellRunner()) {
        let preferences = preferences ?? Preferences()
        let loginItem = loginItem ?? LoginItem()
        self.preferences = preferences
        self.loginItem = loginItem
        self.entitlements = entitlements
        self.probe = probe
        self.control = ProcessControl(runner: runner)
        self.containers = ContainerControl(runner: runner)
        self.inventory = PortInventory(runner: runner, userRoots: preferences.projectRoots)

        // SwiftUI needs to redraw when a preference changes, and the inventory needs
        // rebuilding when the project roots do.
        preferences.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        preferences.$projectRoots
            .dropFirst()
            .sink { [weak self] roots in
                guard let self else { return }
                self.inventory = PortInventory(runner: runner, userRoots: roots)
                self.refresh()
            }
            .store(in: &cancellables)
        loginItem.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        if preferences.notificationsEnabled { Notifier.requestAuthorisation() }
        refresh()
        scheduleTimer()
    }

    // MARK: - Derived views

    public var query: String {
        searchText.trimmingCharacters(in: .whitespaces).lowercased()
    }

    public var devServers: [LocalServer] {
        snapshot.devServers.filter { $0.matches(query) }
    }

    /// Dev servers by who started them, each group already filtered by the search.
    public var devServerGroups: [ServerGroup] {
        ServerGroup.grouping(devServers)
    }

    public var containerGroups: [ContainerGroup] {
        snapshot.containers.filter { group in
            query.isEmpty || group.title.lowercased().contains(query)
                || group.ports.contains { $0.matches(query) }
        }
    }

    public var otherServers: [LocalServer] {
        snapshot.otherServers.filter { $0.matches(query) }
    }

    public var advice: [Advice] {
        guard entitlements.isEnabled(.advice) else { return [] }
        return advisor.build(from: snapshot).filter { !dismissedAdvice.contains($0.id) }
    }

    public var recentlyStopped: [HistoryEntry] {
        guard entitlements.isEnabled(.history) else { return [] }
        return preferences.recentlyStopped(given: snapshot.servers)
    }

    // MARK: - Scanning

    public func setMenuOpen(_ open: Bool) {
        guard menuIsOpen != open else { return }
        menuIsOpen = open
        scheduleTimer()
        if open { refresh() }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = menuIsOpen ? openInterval : idleInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    public func refresh() {
        guard !scanning else { return }
        scanning = true

        let inventory = self.inventory
        Task.detached(priority: .utility) {
            let fresh = inventory.snapshot()
            await MainActor.run { self.apply(fresh) }
        }
    }

    private func apply(_ fresh: Snapshot) {
        var merged = fresh

        for index in merged.servers.indices {
            if let health = healthCache[merged.servers[index].port] {
                merged.servers[index].title = health.title
                merged.servers[index].respondsHTTP = health.respondsHTTP
                merged.servers[index].httpStatus = health.status
            }
            merged.servers[index].pinned = preferences.isPinned(merged.servers[index].projectPath)
        }

        notifyAboutChanges(in: merged)
        preferences.rememberRunning(merged.servers)

        snapshot = merged
        scanning = false
        lastScan = Date()

        // Forget cached health for ports that are gone, so a port reused by a
        // different server does not inherit the old one's title.
        let livePorts = Set(merged.servers.map(\.port))
        healthCache = healthCache.filter { livePorts.contains($0.key) }

        probeHealth(of: merged.servers.filter(\.probeable))
    }

    private func probeHealth(of servers: [LocalServer]) {
        for server in servers {
            let port = server.port
            Task { [weak self] in
                guard let self else { return }
                let result = await self.probe.probe(port: port)
                await MainActor.run {
                    self.healthCache[port] = result
                    guard let index = self.snapshot.servers.firstIndex(where: { $0.port == port })
                    else { return }
                    self.snapshot.servers[index].title = result.title ?? self.snapshot.servers[index].title
                    self.snapshot.servers[index].respondsHTTP = result.respondsHTTP
                    self.snapshot.servers[index].httpStatus = result.status
                }
            }
        }
    }

    private func notifyAboutChanges(in fresh: Snapshot) {
        let currentPorts = Set(fresh.servers.map(\.port))
        defer {
            knownPorts = currentPorts
            hasScannedOnce = true
        }
        // The first scan would otherwise announce everything already running.
        guard hasScannedOnce,
              preferences.notificationsEnabled,
              entitlements.isEnabled(.notifications) else { return }

        for server in fresh.servers where !knownPorts.contains(server.port) {
            if server.isDevServer {
                let origin = server.agent.map { " · started by \($0.displayName)" } ?? ""
                Notifier.post(title: "New dev server on :\(server.port)", body: server.headline + origin)
            } else if server.unrecognised {
                Notifier.post(title: "Unrecognised listener on :\(server.port)",
                              body: server.command + (server.exposed ? " · reachable on your network" : ""))
            }
        }
    }

    // MARK: - Actions

    public func open(_ server: LocalServer) { actions.open(server) }
    public func copyURL(_ server: LocalServer) { actions.copyURL(server) }

    public func reveal(_ server: LocalServer) {
        guard let path = server.projectPath else { return }
        actions.reveal(path)
    }

    public func openInEditor(_ server: LocalServer) {
        guard let path = server.projectPath else { return }
        actions.openInEditor(path)
    }

    public func openTerminal(_ server: LocalServer) {
        guard let path = server.projectPath else { return }
        actions.openTerminal(at: path)
    }

    public func togglePin(_ server: LocalServer) {
        guard entitlements.isEnabled(.pinning) else { return }
        preferences.togglePin(server.projectPath)
        if let index = snapshot.servers.firstIndex(where: { $0.port == server.port }) {
            snapshot.servers[index].pinned = preferences.isPinned(server.projectPath)
        }
    }

    public func quit(_ server: LocalServer, force: Bool = false) {
        // A container port is held by Docker's proxy. Signalling that pid would take
        // down every container at once, so containers are stopped through Docker.
        if let container = server.container {
            stop(containerID: container.id)
            return
        }
        control.terminate(pid: server.pid, force: force)
        refreshShortly()
    }

    public func stop(_ group: ContainerGroup) { stop(containerID: group.container.id) }

    public func restart(_ group: ContainerGroup) {
        let containers = self.containers
        let id = group.container.id
        Task.detached(priority: .userInitiated) {
            containers.restart(containerID: id)
            await MainActor.run { self.refresh() }
        }
    }

    /// `docker stop` can take ten seconds, so it never runs on the main thread.
    private func stop(containerID id: String) {
        let containers = self.containers
        Task.detached(priority: .userInitiated) {
            containers.stop(containerID: id)
            await MainActor.run { self.refresh() }
        }
    }

    public func open(_ group: ContainerGroup) { actions.open(group.primary) }

    public func reveal(_ group: ContainerGroup) {
        guard let path = group.projectPath else { return }
        actions.reveal(path)
    }

    public func openTerminal(_ group: ContainerGroup) {
        guard let path = group.projectPath else { return }
        actions.openTerminal(at: path)
    }

    // MARK: - Sections

    public func isCollapsed(_ section: String) -> Bool {
        preferences.collapsedSections.contains(section)
    }

    public func toggleSection(_ section: String) {
        if preferences.collapsedSections.contains(section) {
            preferences.collapsedSections.remove(section)
        } else {
            preferences.collapsedSections.insert(section)
        }
    }

    public func quitOtherInstances(of server: LocalServer) {
        guard let path = server.projectPath else { return }
        for other in snapshot.servers
        where other.isDevServer && other.projectPath == path && other.port != server.port {
            control.terminate(pid: other.pid, force: false)
        }
        refreshShortly()
    }

    /// Stop every instance of a project except the longest-running one, which is
    /// almost always the one you meant to keep.
    public func quitDuplicates(projectPath: String) {
        let group = snapshot.servers.filter { $0.isDevServer && $0.projectPath == projectPath }
        guard group.count > 1,
              let keep = group.max(by: { ($0.uptimeSeconds ?? 0) < ($1.uptimeSeconds ?? 0) })
        else { return }
        for server in group where server.port != keep.port {
            control.terminate(pid: server.pid, force: false)
        }
        refreshShortly()
    }

    public func quitProcess(pid: Int32) {
        control.terminate(pid: pid, force: false)
        refreshShortly()
    }

    @discardableResult
    public func restart(_ server: LocalServer) -> Bool {
        guard entitlements.isEnabled(.restartInTerminal) else { return false }
        control.terminate(pid: server.pid, force: false)
        guard let command = actions.devCommand(projectPath: server.projectPath,
                                               fallbackArgs: server.args,
                                               cwd: server.cwd) else { return false }
        let started = actions.runInTerminal(command)
        refreshShortly(after: 2)
        return started
    }

    @discardableResult
    public func restart(from entry: HistoryEntry) -> Bool {
        guard entitlements.isEnabled(.restartInTerminal) else { return false }
        guard let command = actions.devCommand(projectPath: entry.projectPath,
                                               fallbackArgs: nil,
                                               cwd: entry.projectPath) else { return false }
        let started = actions.runInTerminal(command)
        refreshShortly(after: 2)
        return started
    }

    public func forget(_ entry: HistoryEntry) { preferences.forget(entry) }

    // MARK: - Advice

    public func dismiss(_ item: Advice) { dismissedAdvice.insert(item.id) }

    public func act(on item: Advice) {
        switch item.kind {
        case .duplicate:
            if let path = item.projectPath { quitDuplicates(projectPath: path) }
        case .runaway:
            if let pid = item.pid { quitProcess(pid: pid) }
        case .erroring:
            if let port = item.port, let server = snapshot.servers.first(where: { $0.port == port }) {
                open(server)
            }
        case .unrecognised, .exposed, .memoryHog, .stale:
            if let port = item.port, let server = snapshot.servers.first(where: { $0.port == port }) {
                quit(server)
            }
        }
        dismiss(item)
    }

    // MARK: - Notifications

    public func setNotificationsEnabled(_ enabled: Bool) {
        preferences.notificationsEnabled = enabled
        if enabled { Notifier.requestAuthorisation() }
    }

    private func refreshShortly(after seconds: TimeInterval = 0.5) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self.refresh()
        }
    }
}
