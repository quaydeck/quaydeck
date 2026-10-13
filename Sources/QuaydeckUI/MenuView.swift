import AppKit
import QuaydeckCore
import SwiftUI

/// The menu: a search field, one-line rows grouped by who started them, and a detail
/// pane for whichever row is under the mouse or selected with the arrow keys.
///
/// Rows stay to a single line so a long list still fits; everything else about a
/// server (URL, path, branch, uptime, memory, who started it) lives in the pane, which
/// has a fixed height so nothing moves under the pointer.
public struct MenuView: View {
    @ObservedObject var model: AppModel

    /// Every row the arrow keys can land on.
    enum RowID: Hashable {
        case server(Int)
        case container(String)
        case history(String)
    }

    @State private var showAllPorts = false
    @State private var showHistory = false
    @State private var showAllAdvice = false
    @State private var hovered: RowID?
    @State private var selected: RowID?
    @State private var pendingQuit: RowID?
    @State private var keyMonitor: Any?
    @FocusState private var searchFocused: Bool

    /// Presented when Terminal automation is refused, which otherwise fails silently.
    @State private var restartFailed = false

    public init(model: AppModel) {
        self.model = model
    }

    private var searching: Bool { !model.query.isEmpty }
    private var showingOthers: Bool { showAllPorts || searching }

    // Row metrics, shared by the rows and the height estimate.
    private let rowHeight: CGFloat = 26
    private let headerHeight: CGFloat = 24
    private let detailHeight: CGFloat = 54

    public var body: some View {
        VStack(spacing: 0) {
            searchBar
            if !model.advice.isEmpty { adviceBar }
            Divider()

            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        list
                    }
                    .padding(.vertical, 5)
                }
                .frame(height: middleHeight)
                .onChange(of: selected) { id in
                    guard let id, hovered != id else { return }
                    withAnimation(.easeOut(duration: 0.12)) { scroller.scrollTo(id) }
                }
            }

            if let active = activeRow {
                Divider()
                detailPane(active)
                    .frame(height: detailHeight, alignment: .topLeading)
            }
            Divider()
            footer
        }
        .frame(width: 360)
        .onAppear {
            model.setMenuOpen(true)
            installKeyMonitor()
            // Typing should filter straight away, as in Spotlight.
            DispatchQueue.main.async { searchFocused = true }
        }
        .onDisappear {
            model.setMenuOpen(false)
            removeKeyMonitor()
            pendingQuit = nil
        }
        .onChange(of: model.searchText) { _ in selected = navigableRows.first }
        .alert("Quaydeck could not open Terminal", isPresented: $restartFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Restarting a server needs permission to control Terminal. "
                 + "Allow Quaydeck under System Settings → Privacy & Security → Automation.")
        }
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if model.devServers.isEmpty && model.containerGroups.isEmpty {
            emptyState
        } else {
            ForEach(model.devServerGroups) { group in
                let origin = Origin(group)
                if showSectionHeaders { sectionHeader(origin, count: group.servers.count) }
                if expanded(origin.id) {
                    ForEach(group.servers) { serverRow($0, isDev: true) }
                }
            }
            if !model.containerGroups.isEmpty {
                sectionHeader(.docker, count: model.containerGroups.count)
                if expanded(Origin.docker.id) {
                    ForEach(model.containerGroups) { containerRow($0) }
                }
            }
        }

        sectionDivider
        disclosure(title: "All ports", count: model.snapshot.otherServers.count,
                   open: showingOthers, alert: model.snapshot.hasAlerts) {
            showAllPorts.toggle()
        }
        .disabled(searching)
        if showingOthers {
            if model.otherServers.isEmpty {
                hint(searching ? "No other matches." : "Nothing else listening.")
            } else {
                ForEach(model.otherServers) { serverRow($0, isDev: false) }
            }
        }

        if !model.recentlyStopped.isEmpty {
            disclosure(title: "Recently stopped", count: model.recentlyStopped.count,
                       open: showHistory, alert: false) {
                showHistory.toggle()
            }
            if showHistory {
                ForEach(model.recentlyStopped) { historyRow($0) }
            }
        }
    }

    /// Rows in display order, for the arrow keys.
    private var navigableRows: [RowID] {
        var rows: [RowID] = []
        for group in model.devServerGroups where expanded(Origin(group).id) {
            rows += group.servers.map { .server($0.port) }
        }
        if expanded(Origin.docker.id) {
            rows += model.containerGroups.map { .container($0.id) }
        }
        if showingOthers { rows += model.otherServers.map { .server($0.port) } }
        if showHistory { rows += model.recentlyStopped.map { .history($0.id) } }
        return rows
    }

    /// The row the detail pane describes: the one under the mouse, else the one the
    /// arrow keys picked, else the first.
    private var activeRow: RowID? {
        let rows = navigableRows
        if let hovered, rows.contains(hovered) { return hovered }
        if let selected, rows.contains(selected) { return selected }
        return rows.first
    }

    /// Headers only earn their space once there is more than "your servers" to tell
    /// apart.
    private var showSectionHeaders: Bool {
        let groups = model.devServerGroups
        return groups.count > 1 || groups.contains { $0.agent != nil } || !model.containerGroups.isEmpty
    }

    /// Searching opens every section, so a match is never hidden in a folded one.
    private func expanded(_ section: String) -> Bool {
        searching || !model.isCollapsed(section)
    }

    /// Fits the content rather than filling the screen, capped so a machine with
    /// thirty listeners still produces a usable popover.
    private var middleHeight: CGFloat {
        var height: CGFloat = 10
        if model.devServers.isEmpty && model.containerGroups.isEmpty {
            height += 64
        } else {
            for group in model.devServerGroups {
                if showSectionHeaders { height += headerHeight }
                if expanded(Origin(group).id) { height += CGFloat(group.servers.count) * rowHeight }
            }
            if !model.containerGroups.isEmpty {
                height += headerHeight
                if expanded(Origin.docker.id) { height += CGFloat(model.containerGroups.count) * rowHeight }
            }
        }
        height += 13 + headerHeight
        if showingOthers { height += CGFloat(max(model.otherServers.count, 1)) * rowHeight }
        if !model.recentlyStopped.isEmpty {
            height += headerHeight
            if showHistory { height += CGFloat(model.recentlyStopped.count) * rowHeight }
        }
        return min(height, 440)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(searchPrompt, text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
                .help("Clear (esc)")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private var searchPrompt: String {
        let servers = model.snapshot.devServers.count
        let containers = model.snapshot.containers.count
        var parts = ["\(servers) server\(servers == 1 ? "" : "s")"]
        if containers > 0 { parts.append("\(containers) container\(containers == 1 ? "" : "s")") }
        return "Search " + parts.joined(separator: ", ")
    }

    // MARK: - Advice

    /// The most pressing item on one line; the rest one click away.
    private var adviceBar: some View {
        let items = model.advice
        let shown = showAllAdvice ? items : Array(items.prefix(1))
        return VStack(spacing: 3) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                adviceRow(item, more: index == 0 && items.count > 1 ? items.count - 1 : nil)
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 8)
    }

    private func adviceRow(_ item: Advice, more: Int?) -> some View {
        let tint = tint(for: item.severity)
        return HStack(spacing: 7) {
            Image(systemName: item.icon).font(.system(size: 10.5)).foregroundStyle(tint)
            Text(item.text)
                .font(.system(size: 11))
                .lineLimit(1).truncationMode(.tail)
                .help(item.text)
            Spacer(minLength: 4)
            if let more {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showAllAdvice.toggle() }
                } label: {
                    Text(verbatim: showAllAdvice ? "less" : "+\(more)")
                        .font(.system(size: 9.5, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(tint.opacity(0.18)))
                }
                .buttonStyle(.plain).foregroundStyle(tint)
                .help(showAllAdvice ? "Show only the first" : "Show all \(more + 1)")
            }
            if let label = item.actionLabel {
                Button(label) { model.act(on: item) }
                    .font(.system(size: 10.5, weight: .semibold))
                    .buttonStyle(.borderless).foregroundStyle(tint)
            }
            Button { model.dismiss(item) } label: {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundStyle(.tertiary)
            .help("Dismiss")
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.11)))
    }

    private func tint(for severity: Advice.Severity) -> Color {
        switch severity {
        case .critical: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }

    // MARK: - Rows

    /// The frame every row shares: hover and selection, the inline quit
    /// confirmation, click to open, and its context menu.
    private func rowShell<Content: View, MenuItems: View>(
        _ id: RowID,
        tinted: Bool = false,
        open: @escaping () -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder menu: () -> MenuItems
    ) -> some View {
        let isHovered = hovered == id
        let isSelected = activeRow == id && hovered == nil
        let confirming = pendingQuit == id
        let fill: Color
        if confirming { fill = .red.opacity(0.12) }
        else if isHovered { fill = .primary.opacity(0.08) }
        else if isSelected { fill = .accentColor.opacity(0.13) }
        else if tinted { fill = .orange.opacity(0.09) }
        else { fill = .clear }

        return HStack(spacing: 8) { content() }
            .padding(.horizontal, 14)
            .frame(height: rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(fill).padding(.horizontal, 6))
            .onTapGesture { if !confirming { open() } }
            .onHover { inside in
                if inside {
                    hovered = id
                    selected = id
                } else if hovered == id {
                    hovered = nil
                }
            }
            .contextMenu { menu() }
            .id(id)
    }

    private func dot(_ colour: Color) -> some View {
        Circle().fill(colour).frame(width: 6, height: 6)
    }

    private func portLabel(_ port: Int, muted: Bool = false) -> some View {
        Text(verbatim: ":\(port)")
            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
            .foregroundStyle(muted ? .tertiary : .secondary)
            .frame(minWidth: 46, alignment: .leading)
    }

    private func names(_ primary: String, _ secondary: String?) -> some View {
        HStack(spacing: 6) {
            Text(primary).font(.system(size: 12.5)).lineLimit(1).layoutPriority(1)
            if let secondary, !secondary.isEmpty {
                Text(secondary).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
    }

    @ViewBuilder
    private func serverRow(_ server: LocalServer, isDev: Bool) -> some View {
        let id = RowID.server(server.port)
        rowShell(id, tinted: server.suspicious, open: { model.open(server) }) {
            dot(isDev ? statusColour(server) : (server.unrecognised ? .orange : .secondary.opacity(0.35)))
            portLabel(server.port, muted: !isDev)
            if isDev {
                names(server.project ?? server.folder ?? server.command, devHint(server))
            } else {
                names(server.noiseTitle, server.unrecognised ? "unrecognised" : nil)
            }
            Spacer(minLength: 4)
            trailing(id, quit: { model.quit(server) }, restart: isDev ? { restart(server) } : nil) {
                glyphs(server, isDev: isDev)
            }
        } menu: {
            serverMenu(server, isDev: isDev)
        }
    }

    /// The one hint a dev row has room for: the agent session that started it, else
    /// the page's title, else what it runs on.
    private func devHint(_ server: LocalServer) -> String? {
        if server.agent != nil, let session = server.agentSession { return session }
        if let title = server.title, !title.isEmpty { return title }
        return server.framework
    }

    @ViewBuilder
    private func glyphs(_ server: LocalServer, isDev: Bool) -> some View {
        HStack(spacing: 5) {
            if server.pinned { symbol("star.fill", .yellow, "Pinned") }
            if server.isNew { tag("new", .blue) }
            if server.isDuplicate { tag("×\(server.duplicateCount)", .orange) }
            if server.busy { tag("busy", .red) }
            if server.exposed { symbol("globe", .orange, "Reachable on your local network") }
            if !isDev && server.unrecognised { symbol("exclamationmark.triangle.fill", .orange, "Unrecognised") }
        }
    }

    @ViewBuilder
    private func containerRow(_ group: ContainerGroup) -> some View {
        let id = RowID.container(group.id)
        let primary = group.primary
        rowShell(id, open: { primary.probeable ? model.open(group) : model.copyAddress(primary) }) {
            dot(containerColour(group))
            portLabel(primary.port)
            names(group.title, group.service ?? group.container.imageLabel)
            Spacer(minLength: 4)
            trailing(id, quit: { model.stop(group) }, restart: { model.restart(group) }, quitVerb: "Stop?") {
                HStack(spacing: 5) {
                    if group.ports.count > 1 { tag("+\(group.ports.count - 1)", .secondary) }
                    if group.exposed { symbol("globe", .orange, "Published on every interface") }
                }
            }
        } menu: {
            containerMenu(group)
        }
    }

    @ViewBuilder
    private func historyRow(_ entry: HistoryEntry) -> some View {
        let id = RowID.history(entry.id)
        rowShell(id, open: { restart(entry) }) {
            Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1).frame(width: 6, height: 6)
            portLabel(entry.lastPort, muted: true)
            names(entry.project, entry.framework)
            Spacer(minLength: 4)
            if hovered == id {
                iconButton("play.fill", colour: .green, help: "Start again in Terminal") { restart(entry) }
            }
        } menu: {
            Button("Start again in Terminal") { restart(entry) }
            Button("Forget", role: .destructive) { model.forget(entry) }
        }
    }

    /// Glyphs at rest; on hover, the row's actions; while confirming, the question.
    @ViewBuilder
    private func trailing<Glyphs: View>(_ id: RowID, quit: @escaping () -> Void,
                                        restart: (() -> Void)?, quitVerb: String = "Quit?",
                                        @ViewBuilder glyphs: () -> Glyphs) -> some View {
        if pendingQuit == id {
            HStack(spacing: 6) {
                Text(quitVerb).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.red)
                iconButton("checkmark.circle.fill", colour: .red, help: "Confirm") {
                    quit(); pendingQuit = nil
                }
                iconButton("xmark.circle", colour: .secondary, help: "Cancel") { pendingQuit = nil }
            }
        } else if hovered == id {
            HStack(spacing: 8) {
                if let restart {
                    iconButton("arrow.clockwise", colour: .secondary, help: "Restart", action: restart)
                }
                iconButton("stop.fill", colour: .red.opacity(0.85), help: "Stop") { pendingQuit = id }
            }
        } else {
            glyphs()
        }
    }

    private func restart(_ server: LocalServer) {
        if !model.restart(server) { restartFailed = true }
    }

    private func restart(_ entry: HistoryEntry) {
        if !model.restart(from: entry) { restartFailed = true }
    }

    private func statusColour(_ server: LocalServer) -> Color {
        if server.erroring { return .orange }
        if server.respondsHTTP { return .green }
        return .secondary.opacity(0.4)
    }

    private func containerColour(_ group: ContainerGroup) -> Color {
        let status = group.container.status.lowercased()
        if group.primary.erroring || status.contains("unhealthy") { return .orange }
        if group.primary.respondsHTTP || status.contains("(healthy)") { return .green }
        return .secondary.opacity(0.4)
    }

    // MARK: - Detail pane

    @ViewBuilder
    private func detailPane(_ id: RowID) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            switch id {
            case .server(let port):
                if let server = model.snapshot.servers.first(where: { $0.port == port }) {
                    serverDetail(server)
                }
            case .container(let containerID):
                if let group = model.containerGroups.first(where: { $0.id == containerID }) {
                    containerDetail(group)
                }
            case .history(let path):
                if let entry = model.recentlyStopped.first(where: { $0.id == path }) {
                    detailLine(entry.project + (entry.framework.map { " · \($0)" } ?? ""), strong: true)
                    detailLine(abbreviate(entry.projectPath), middle: true)
                    detailLine("Stopped · last on :\(entry.lastPort) · click to start again in Terminal")
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func serverDetail(_ server: LocalServer) -> some View {
        if server.isDevServer {
            detailLine(server.url + (server.title.map { "  “\($0)”" } ?? "")
                       + (server.healthText.map { "  \($0)" } ?? ""), strong: true)
            detailLine([server.projectPath.map(abbreviate) ?? abbreviate(server.cwd),
                        server.gitText, server.framework].compactMap { $0 }.joined(separator: " · "),
                       middle: true)
            detailLine([server.uptimeText.map { "up \($0)" }, server.cpuText, server.memText,
                        "PID \(server.pid)", origin(of: server)].compactMap { $0 }.joined(separator: " · "))
        } else {
            detailLine("\(server.noiseTitle) · \(server.url)", strong: true)
            detailLine(server.args.isEmpty ? server.command : server.args, middle: true)
            detailLine([server.unrecognised ? "Unrecognised location" : (server.isService ? "Local service" : "System"),
                        server.exposed ? "reachable on your network" : "this Mac only",
                        "PID \(server.pid)",
                        server.agent.map { "started by \($0.displayName)" }].compactMap { $0 }.joined(separator: " · "))
        }
    }

    /// A database container gets its address, not a URL: it does not speak HTTP, and a
    /// click copies the address instead of opening a browser tab that cannot load.
    @ViewBuilder
    private func containerDetail(_ group: ContainerGroup) -> some View {
        let primary = group.primary
        if primary.probeable {
            detailLine(primary.url + (primary.title.map { "  “\($0)”" } ?? ""), strong: true)
        } else {
            detailLine("localhost:\(primary.port) · \(group.container.imageLabel)", strong: true)
        }
        detailLine(group.projectPath.map(abbreviate) ?? group.container.name, middle: true)
        detailLine(primary.probeable
                   ? group.portsText + " · " + group.container.status
                   : "Click copies the address · " + group.container.status)
    }

    private func origin(of server: LocalServer) -> String {
        guard let agent = server.agent else { return "started by you" }
        guard let session = server.agentSession else { return "started by \(agent.displayName)" }
        return "\(agent.displayName): “\(session)”"
    }

    private func detailLine(_ text: String, strong: Bool = false, middle: Bool = false) -> some View {
        Text(verbatim: text)
            .font(.system(size: strong ? 11.5 : 10.5, weight: strong ? .medium : .regular))
            .foregroundStyle(strong ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(middle ? .middle : .tail)
            .textSelection(.enabled)
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - Menus

    @ViewBuilder
    private func serverMenu(_ server: LocalServer, isDev: Bool) -> some View {
        Button("Open \(server.url)") { model.open(server) }
        Button("Copy URL") { model.copyURL(server) }
        if server.projectPath != nil {
            if isDev {
                Button(server.pinned ? "Unpin" : "Pin to top") { model.togglePin(server) }
                Button("Restart in Terminal") { restart(server) }
                if server.isDuplicate {
                    Button("Quit other instances of this project") { model.quitOtherInstances(of: server) }
                }
            }
            Button("Open in editor") { model.openInEditor(server) }
            Button("Reveal in Finder") { model.reveal(server) }
            Button("Open in Terminal") { model.openTerminal(server) }
        }
        Divider()
        Button("Quit (SIGTERM)") { model.quit(server) }
        Button("Force quit (SIGKILL)", role: .destructive) { model.quit(server, force: true) }
    }

    @ViewBuilder
    private func containerMenu(_ group: ContainerGroup) -> some View {
        ForEach(group.ports) { port in
            Button("Open \(port.url)" + (port.containerPort.map { " (→ \($0))" } ?? "")) {
                model.open(port)
            }
        }
        Button("Copy URL") { model.copyURL(group.primary) }
        if group.projectPath != nil {
            Button("Reveal project in Finder") { model.reveal(group) }
            Button("Open project in Terminal") { model.openTerminal(group) }
        }
        Divider()
        Button("Restart container") { model.restart(group) }
        Button("Stop container", role: .destructive) { model.stop(group) }
    }

    // MARK: - Sections

    /// One heading per origin: the servers you started, those each agent started, and
    /// Docker's containers.
    struct Origin {
        let id: String
        let title: String
        let symbol: String
        let tint: Color

        static let you = Origin(id: "you", title: "Yours", symbol: "person.fill", tint: .secondary)
        static let docker = Origin(id: "docker", title: "Docker", symbol: "shippingbox.fill",
                                   tint: Color(red: 0.11, green: 0.39, blue: 0.93))

        init(id: String, title: String, symbol: String, tint: Color) {
            self.id = id
            self.title = title
            self.symbol = symbol
            self.tint = tint
        }

        init(_ group: ServerGroup) {
            guard let agent = group.agent else { self = .you; return }
            switch agent {
            case .claude:
                self.init(id: agent.rawValue, title: agent.displayName, symbol: "asterisk",
                          tint: Color(red: 0.85, green: 0.47, blue: 0.34))
            case .codex:
                self.init(id: agent.rawValue, title: agent.displayName,
                          symbol: "chevron.left.forwardslash.chevron.right", tint: .primary)
            case .cursor, .copilot, .aider:
                self.init(id: agent.rawValue, title: agent.displayName, symbol: "sparkles", tint: .secondary)
            }
        }
    }

    private func sectionHeader(_ section: Origin, count: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { model.toggleSection(section.id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: section.symbol)
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(section.tint)
                    .frame(width: 12)
                Text(section.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(verbatim: "\(count)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                Spacer()
                Image(systemName: expanded(section.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: headerHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(searching)
    }

    private func disclosure(title: String, count: Int, open: Bool, alert: Bool,
                            toggle: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(verbatim: "\(count)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                if alert { symbol("exclamationmark.triangle.fill", .orange, "An unrecognised listener is running") }
                Spacer()
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: headerHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 5) {
            Image(systemName: searching ? "magnifyingglass" : "moon.zzz")
                .font(.system(size: 16)).foregroundStyle(.tertiary)
            Text(searching ? "No matches" : "No dev servers running")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).frame(height: 64)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11)).foregroundStyle(.tertiary)
            .padding(.horizontal, 14).frame(height: rowHeight)
    }

    private var sectionDivider: some View {
        Divider().padding(.horizontal, 14).padding(.vertical, 6)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button { model.setNotificationsEnabled(!model.preferences.notificationsEnabled) } label: {
                Image(systemName: model.preferences.notificationsEnabled ? "bell.fill" : "bell.slash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.preferences.notificationsEnabled ? Color.accentColor : .secondary)
            .help(model.preferences.notificationsEnabled
                  ? "Alerts on for new and unrecognised listeners"
                  : "Alerts off")

            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Refresh now")

            Spacer()

            Text("↑↓ select  ↩ open")
                .font(.system(size: 10)).foregroundStyle(.quaternary)

            Spacer()

            // Not SettingsLink: that is macOS 14 and up, and Quaydeck supports 13.
            Button { openSettingsWindow() } label: {
                Image(systemName: "gearshape").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Settings")

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    // MARK: - Keyboard

    /// Arrow keys move the selection and return opens it, while the search field
    /// keeps the focus so typing always filters. Escape clears a search first and
    /// closes the menu second.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // An open alert owns return and escape.
            if restartFailed { return event }
            switch event.keyCode {
            case 125: moveSelection(by: 1); return nil       // down
            case 126: moveSelection(by: -1); return nil      // up
            case 36, 76:                                    // return, enter
                openSelection(); return nil
            case 53:                                        // escape
                if !model.searchText.isEmpty { model.searchText = ""; return nil }
                return event
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func moveSelection(by step: Int) {
        let rows = navigableRows
        guard !rows.isEmpty else { return }
        hovered = nil
        let current = activeRow.flatMap { rows.firstIndex(of: $0) } ?? (step > 0 ? -1 : rows.count)
        selected = rows[max(0, min(rows.count - 1, current + step))]
    }

    private func openSelection() {
        switch activeRow {
        case .server(let port):
            if let server = model.snapshot.servers.first(where: { $0.port == port }) { model.open(server) }
        case .container(let id):
            if let group = model.containerGroups.first(where: { $0.id == id }) { model.open(group) }
        case .history(let path):
            if let entry = model.recentlyStopped.first(where: { $0.id == path }) { restart(entry) }
        case nil:
            break
        }
    }

    // MARK: - Small pieces

    private func iconButton(_ symbol: String, colour: Color, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11)) }
            .buttonStyle(.plain).foregroundStyle(colour).help(help)
    }

    private func symbol(_ name: String, _ colour: Color, _ help: String) -> some View {
        Image(systemName: name).font(.system(size: 9)).foregroundStyle(colour).help(help)
    }

    private func tag(_ text: String, _ colour: Color) -> some View {
        Text(verbatim: text).font(.system(size: 8.5, weight: .bold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Capsule().fill(colour.opacity(0.85)))
            .foregroundStyle(.white)
    }
}
