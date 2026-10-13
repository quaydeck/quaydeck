import AppKit
import Combine
import Foundation
import QuaydeckCore

/// Owns the current picture of the machine and everything the menu can do to it.
@MainActor
public final class AppModel: ObservableObject {

    @Published public private(set) var snapshot = Snapshot()
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

    /// Poll quickly while the menu is open and slowly when it is not. A scan reads the
    /// kernel directly and costs about 15 ms of CPU, but a closed menu is most of the
    /// day, and Low Power Mode asks every app to back off further.
    private let openInterval: TimeInterval = 3
    private var idleInterval: TimeInterval {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? 60 : 20
    }
    private var timer: Timer?
    private var menuIsOpen = false
    /// Not published: a scan takes milliseconds, and flipping a published flag twice
    /// per scan redrew the menu for nothing.
    private var scanning = false
    /// Screens asleep or another user active: nobody can look, so nothing is scanned.
    private var paused = false
    /// The newest scan. Published straight away while the menu is open; while it is
    /// closed only when something the menu bar or a notification cares about changed.
    private var latest = Snapshot()
    /// When each port last had its page fetched.
    private var probedAt: [Int: Date] = [:]

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
                runner: CommandRunner = ShellRunner(),
                inventory injected: PortInventory? = nil) {
        let preferences = preferences ?? Preferences()
        let loginItem = loginItem ?? LoginItem()
        self.preferences = preferences
        self.loginItem = loginItem
        self.entitlements = entitlements
        self.probe = probe
        self.control = ProcessControl(runner: runner)
        self.containers = ContainerControl(runner: runner)
        // An injected inventory is a recorded machine (screenshots, previews); it is
        // kept as is rather than rebuilt when the project folders change.
        self.inventory = injected ?? PortInventory(runner: runner, userRoots: preferences.projectRoots)

        // SwiftUI needs to redraw when a preference changes, and the inventory needs
        // rebuilding when the project roots do.
        preferences.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        preferences.$projectRoots
            .dropFirst()
            .filter { _ in injected == nil }
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
        observeSystem()
        refresh()
        scheduleTimer()
    }

    /// Stops scanning while the screens sleep or the session is switched away, scans
    /// once on return, and picks up Low Power Mode as it changes.
    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let pause: [Notification.Name] = [NSWorkspace.screensDidSleepNotification,
                                          NSWorkspace.willSleepNotification,
                                          NSWorkspace.sessionDidResignActiveNotification]
        let resume: [Notification.Name] = [NSWorkspace.screensDidWakeNotification,
                                           NSWorkspace.didWakeNotification,
                                           NSWorkspace.sessionDidBecomeActiveNotification]
        for name in pause {
            workspace.publisher(for: name)
                .sink { [weak self] _ in self?.setPaused(true) }
                .store(in: &cancellables)
        }
        for name in resume {
            workspace.publisher(for: name)
                .sink { [weak self] _ in self?.setPaused(false) }
                .store(in: &cancellables)
        }
        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleTimer() }
            .store(in: &cancellables)
    }

    private func setPaused(_ value: Bool) {
        guard paused != value else { return }
        paused = value
        if value {
            timer?.invalidate()
            timer = nil
        } else {
            scheduleTimer()
            refresh()
        }
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
        if open, latest != snapshot { snapshot = latest }
        scheduleTimer()
        if open { refresh() }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        guard !paused else { return }
        let interval = menuIsOpen ? openInterval : idleInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Lets macOS fold this wake-up in with others instead of waking just for us.
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func refresh() {
        guard !scanning, !paused else { return }
        scanning = true

        let inventory = self.inventory
        let interactive = menuIsOpen
        Task.detached(priority: .utility) {
            let fresh = inventory.snapshot(interactive: interactive)
            await MainActor.run { self.apply(fresh) }
        }
    }

    /// What the menu bar icon and notifications depend on. While the menu is closed,
    /// a scan that leaves this unchanged is kept, not published.
    private func outline(_ snapshot: Snapshot) -> [String] {
        snapshot.servers.map { "\($0.port):\($0.kind):\($0.agent?.rawValue ?? "")" }.sorted()
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

        latest = merged
        if menuIsOpen || outline(merged) != outline(snapshot) {
            snapshot = merged
        }
        scanning = false

        // Forget cached health for ports that are gone, so a port reused by a
        // different server does not inherit the old one's title.
        let livePorts = Set(merged.servers.map(\.port))
        healthCache = healthCache.filter { livePorts.contains($0.key) }
        probedAt = probedAt.filter { livePorts.contains($0.key) }

        probeHealth(of: merged.servers.filter(\.probeable))
    }

    /// Fetches pages only as often as someone could notice: every few seconds while
    /// the menu is open, and while it is closed only for ports never seen before, so
    /// the title is already there when the menu opens.
    private func probeHealth(of servers: [LocalServer]) {
        let now = Date()
        for server in servers {
            let port = server.port
            if let last = probedAt[port], !menuIsOpen || now.timeIntervalSince(last) < 6 { continue }
            probedAt[port] = now
            Task { [weak self] in
                guard let self else { return }
                let result = await self.probe.probe(port: port)
                await MainActor.run {
                    let previous = self.healthCache[port]
                    self.healthCache[port] = result
                    guard previous != result else { return }
                    for index in self.latest.servers.indices where self.latest.servers[index].port == port {
                        self.latest.servers[index].title = result.title ?? self.latest.servers[index].title
                        self.latest.servers[index].respondsHTTP = result.respondsHTTP
                        self.latest.servers[index].httpStatus = result.status
                    }
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

    public func open(_ group: ContainerGroup) {
        guard let url = URL(string: group.openURL) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Agent sessions

    /// Back to the session that started a server: the Codex chat in the Codex app, or
    /// the Claude session resumed in Terminal.
    @discardableResult
    public func openSession(of server: LocalServer) -> Bool {
        if let url = SessionLinks.codexThreadURL(for: server) {
            return NSWorkspace.shared.open(url)
        }
        if let command = SessionLinks.claudeResumeCommand(for: server) {
            return actions.runInTerminal(command)
        }
        return false
    }

    public func copySessionCommand(of server: LocalServer) {
        guard let command = SessionLinks.claudeResumeCommand(for: server)
                ?? SessionLinks.codexResumeCommand(for: server) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// "localhost:55003", for ports a browser cannot use.
    public func copyAddress(_ server: LocalServer) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("localhost:\(server.port)", forType: .string)
    }

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
        case .leftBehind:
            for server in snapshot.servers where server.leftBehind { control.terminate(pid: server.pid, force: false) }
            refreshShortly()
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
