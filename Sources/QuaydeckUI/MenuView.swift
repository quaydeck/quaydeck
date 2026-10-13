import AppKit
import QuaydeckCore
import SwiftUI

public struct MenuView: View {
    @ObservedObject var model: AppModel

    @State private var showAllPorts = false
    @State private var showHistory = false
    @State private var hoveredPort: Int?
    @State private var pendingQuit: Int?

    /// Presented when Terminal automation is refused, which otherwise fails silently.
    @State private var restartFailed = false

    public init(model: AppModel) {
        self.model = model
    }

    private var searching: Bool { !model.query.isEmpty }
    private var showingOthers: Bool { showAllPorts || searching }

    public var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            if !model.advice.isEmpty { adviceStrip }
            Divider()

            // One scroll region for the whole middle, so nothing can fall off-screen
            // on a short display.
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if model.devServers.isEmpty && model.containerGroups.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.devServerGroups) { group in
                            if showSectionHeaders {
                                sectionHeader(Origin(group), count: group.servers.count)
                            }
                            if expanded(Origin(group).id) {
                                ForEach(group.servers) { row($0, isDev: true) }
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
                    allPortsHeader

                    if showingOthers {
                        if model.otherServers.isEmpty {
                            hint(searching ? "No other matches." : "Nothing else listening.")
                        } else {
                            ForEach(model.otherServers) { row($0, isDev: false) }
                        }
                    }

                    if !model.recentlyStopped.isEmpty {
                        sectionDivider
                        historyHeader
                        if showHistory {
                            ForEach(model.recentlyStopped) { historyRow($0) }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(height: middleHeight)

            Divider()
            footer
        }
        .frame(width: 360)
        .onAppear { model.setMenuOpen(true) }
        .onDisappear { model.setMenuOpen(false) }
        .alert("Quaydeck could not open Terminal", isPresented: $restartFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Restarting a server needs permission to control Terminal. "
                 + "Allow Quaydeck under System Settings → Privacy & Security → Automation.")
        }
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
        var devHeight = 0.0
        if model.devServers.isEmpty && model.containerGroups.isEmpty {
            devHeight = 1.6 * 50
        } else {
            for group in model.devServerGroups {
                if showSectionHeaders { devHeight += 26 }
                guard expanded(Origin(group).id) else { continue }
                for server in group.servers {
                    devHeight += server.agent != nil && server.agentSession != nil ? 57 : 50
                }
            }
            if !model.containerGroups.isEmpty {
                devHeight += 26
                if expanded(Origin.docker.id) { devHeight += Double(model.containerGroups.count) * 42 }
            }
        }
        let otherHeight = showingOthers ? Double(max(model.otherServers.count, 1)) * 42 : 0
        let historyHeight = (model.recentlyStopped.isEmpty ? 0 : 36.0)
            + (showHistory ? Double(model.recentlyStopped.count) * 38 : 0)
        return CGFloat(min(devHeight + otherHeight + historyHeight + 58, 540))
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sailboat.fill").foregroundStyle(.tint)
            Text("Quaydeck").font(.system(size: 13, weight: .semibold))
            Spacer()
            if model.scanning {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            Text(countText)
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
    }

    private var countText: String {
        let servers = model.snapshot.devServers.count
        let containers = model.snapshot.containers.count
        var text = "\(servers) server\(servers == 1 ? "" : "s")"
        if containers > 0 { text += " · \(containers) container\(containers == 1 ? "" : "s")" }
        return text
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Filter by port, project, title…", text: $model.searchText)
                .textFieldStyle(.plain).font(.system(size: 12))
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: searching ? "magnifyingglass" : "moon.zzz")
                .font(.title2).foregroundStyle(.tertiary)
            Text(searching ? "No matches" : "No dev servers running")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 20)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11)).foregroundStyle(.tertiary)
            .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private var sectionDivider: some View {
        Divider().padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
    }

    // MARK: - Advice

    private var adviceStrip: some View {
        VStack(spacing: 4) {
            ForEach(model.advice.prefix(3)) { adviceRow($0) }
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private func adviceRow(_ item: Advice) -> some View {
        let tint = tint(for: item.severity)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.icon)
                .font(.system(size: 11)).foregroundStyle(tint).padding(.top, 1)
            Text(item.text)
                .font(.system(size: 10.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let label = item.actionLabel {
                Button(label) { model.act(on: item) }
                    .font(.system(size: 10, weight: .semibold))
                    .buttonStyle(.borderless).foregroundStyle(tint)
            }
            Button { model.dismiss(item) } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain).foregroundStyle(.tertiary)
            .help("Dismiss")
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.12)))
    }

    private func tint(for severity: Advice.Severity) -> Color {
        switch severity {
        case .critical: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ server: LocalServer, isDev: Bool) -> some View {
        let hovered = hoveredPort == server.port
        let confirming = pendingQuit == server.port

        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(statusColour(server))
                .frame(width: 7, height: 7)
                .padding(.top, 5)
                .help(statusDescription(server))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if server.pinned {
                        Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow)
                    }
                    if !isDev && server.unrecognised {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8)).foregroundStyle(.orange)
                    }
                    if !isDev && server.isService {
                        Image(systemName: "cylinder.split.1x2")
                            .font(.system(size: 8)).foregroundStyle(.teal)
                            .help("Local dev service")
                    }
                    Text(verbatim: ":\(server.port)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text(isDev ? server.headline : server.noiseTitle)
                        .font(.system(size: 12)).lineLimit(1)
                    if server.isNew { tag("new", .blue) }
                    if server.isDuplicate { tag("×\(server.duplicateCount)", .orange) }
                    if server.busy { tag("busy", .red) }
                    if server.exposed {
                        Image(systemName: "globe").font(.system(size: 9)).foregroundStyle(.orange)
                            .help("Reachable on your local network")
                    }
                }

                if isDev, let subtitle = server.subtitle {
                    Text(subtitle).font(.system(size: 10.5))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                if isDev, server.agent != nil, let session = server.agentSession {
                    HStack(spacing: 4) {
                        Image(systemName: "text.bubble").font(.system(size: 8.5))
                        Text(session).lineLimit(1).truncationMode(.tail)
                    }
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .help("Started in \(server.agent?.displayName ?? "an agent") session “\(session)”")
                }
                if !isDev {
                    Text(server.unrecognised
                         ? "unrecognised · \(server.command) · PID \(server.pid)"
                            + (server.agent.map { " · started by \($0.displayName)" } ?? "")
                         : "\(server.command) · PID \(server.pid)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(server.unrecognised ? .orange : .secondary)
                }
            }

            Spacer(minLength: 4)
            trailing(server, isDev: isDev, hovered: hovered, confirming: confirming)
        }
        .padding(.vertical, 5).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(rowBackground(server, hovered: hovered, confirming: confirming))
        .onTapGesture { if !confirming { model.open(server) } }
        .onHover { inside in
            hoveredPort = inside ? server.port : (hoveredPort == server.port ? nil : hoveredPort)
        }
        .contextMenu { contextMenu(server, isDev: isDev) }
    }

    @ViewBuilder
    private func trailing(_ server: LocalServer, isDev: Bool, hovered: Bool, confirming: Bool) -> some View {
        if confirming {
            HStack(spacing: 6) {
                Text("Quit?").font(.system(size: 10, weight: .semibold)).foregroundStyle(.red)
                iconButton("checkmark.circle.fill", colour: .red, help: "Confirm") {
                    model.quit(server); pendingQuit = nil
                }
                iconButton("xmark.circle", colour: .secondary, help: "Cancel") {
                    pendingQuit = nil
                }
            }
        } else {
            HStack(spacing: 7) {
                if isDev && (hovered || server.pinned) {
                    iconButton(server.pinned ? "star.fill" : "star",
                               colour: server.pinned ? .yellow : .secondary,
                               help: server.pinned ? "Unpin" : "Pin to top") {
                        model.togglePin(server)
                    }
                }
                if isDev && hovered {
                    iconButton("arrow.clockwise", colour: .secondary, help: "Restart in Terminal") {
                        if !model.restart(server) { restartFailed = true }
                    }
                }
                if hovered {
                    iconButton("stop.circle", colour: .red.opacity(0.85), help: "Quit :\(server.port)") {
                        pendingQuit = server.port
                    }
                    iconButton("arrow.up.right.square", colour: .secondary, help: "Open \(server.url)") {
                        model.open(server)
                    }
                } else if !server.pinned || !isDev {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary).opacity(0.3)
                }
            }
        }
    }

    private func rowBackground(_ server: LocalServer, hovered: Bool, confirming: Bool) -> some View {
        let colour: Color
        if confirming {
            colour = Color.red.opacity(0.12)
        } else if server.suspicious {
            colour = Color.orange.opacity(hovered ? 0.18 : 0.10)
        } else if hovered {
            colour = Color.primary.opacity(0.08)
        } else {
            colour = .clear
        }
        return RoundedRectangle(cornerRadius: 7).fill(colour).padding(.horizontal, 6)
    }

    private func statusColour(_ server: LocalServer) -> Color {
        if server.erroring { return .orange }
        if server.respondsHTTP { return .green }
        return .secondary.opacity(0.45)
    }

    private func statusDescription(_ server: LocalServer) -> String {
        if server.erroring { return "Responding but erroring (HTTP \(server.httpStatus ?? 500))" }
        if server.respondsHTTP { return "Healthy" }
        return "Port open, no HTTP response"
    }

    @ViewBuilder
    private func contextMenu(_ server: LocalServer, isDev: Bool) -> some View {
        Button("Open \(server.url)") { model.open(server) }
        Button("Copy URL") { model.copyURL(server) }
        if server.projectPath != nil {
            if isDev {
                Button(server.pinned ? "Unpin" : "Pin to top") { model.togglePin(server) }
                Button("Restart in Terminal") {
                    if !model.restart(server) { restartFailed = true }
                }
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

    // MARK: - Origin sections

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
            withAnimation(.easeInOut(duration: 0.15)) { model.toggleSection(section.id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded(section.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                    .frame(width: 8)
                Image(systemName: section.symbol)
                    .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(section.tint)
                Text(section.title).font(.system(size: 11, weight: .semibold))
                Text(verbatim: "\(count)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 7).padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(searching)
    }

    // MARK: - Containers

    @ViewBuilder
    private func containerRow(_ group: ContainerGroup) -> some View {
        let primary = group.primary
        let hovered = hoveredPort == primary.port
        let confirming = pendingQuit == primary.port

        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(containerColour(group))
                .frame(width: 7, height: 7)
                .padding(.top, 5)
                .help(group.container.status)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(group.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if let service = group.service {
                        Text(service).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if group.exposed {
                        Image(systemName: "globe").font(.system(size: 9)).foregroundStyle(.orange)
                            .help("Published on every interface: reachable on your local network")
                    }
                }
                Text(containerSubtitle(group))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer(minLength: 4)

            if confirming {
                HStack(spacing: 6) {
                    Text("Stop?").font(.system(size: 10, weight: .semibold)).foregroundStyle(.red)
                    iconButton("checkmark.circle.fill", colour: .red, help: "Confirm") {
                        model.stop(group); pendingQuit = nil
                    }
                    iconButton("xmark.circle", colour: .secondary, help: "Cancel") {
                        pendingQuit = nil
                    }
                }
            } else if hovered {
                HStack(spacing: 7) {
                    iconButton("arrow.clockwise", colour: .secondary, help: "Restart container") {
                        model.restart(group)
                    }
                    iconButton("stop.circle", colour: .red.opacity(0.85), help: "Stop \(group.container.name)") {
                        pendingQuit = primary.port
                    }
                    iconButton("arrow.up.right.square", colour: .secondary, help: "Open \(primary.url)") {
                        model.open(group)
                    }
                }
            } else {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary).opacity(0.3)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(rowBackground(primary, hovered: hovered, confirming: confirming))
        .onTapGesture { if !confirming { model.open(group) } }
        .onHover { inside in
            hoveredPort = inside ? primary.port : (hoveredPort == primary.port ? nil : hoveredPort)
        }
        .contextMenu { containerMenu(group) }
    }

    /// ":58610→80  :58609→443 +1 · Up 3 minutes (healthy)"
    private func containerSubtitle(_ group: ContainerGroup) -> String {
        let shown = group.ports.prefix(3).map { port -> String in
            guard let inside = port.containerPort, inside != port.port else { return ":\(port.port)" }
            return ":\(port.port)→\(inside)"
        }
        var ports = shown.joined(separator: "  ")
        if group.ports.count > 3 { ports += " +\(group.ports.count - 3)" }
        var parts = [ports]
        if let title = group.primary.title, !title.isEmpty { parts.append("“\(title)”") }
        parts.append(group.container.status)
        return parts.joined(separator: " · ")
    }

    private func containerColour(_ group: ContainerGroup) -> Color {
        let status = group.container.status.lowercased()
        if group.primary.erroring || status.contains("unhealthy") { return .orange }
        if group.primary.respondsHTTP || status.contains("(healthy)") { return .green }
        return .secondary.opacity(0.45)
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
        Text(verbatim: "\(group.container.imageLabel) · \(group.container.name)")
        Button("Restart container") { model.restart(group) }
        Button("Stop container", role: .destructive) { model.stop(group) }
    }

    // MARK: - Sections

    private var allPortsHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { showAllPorts.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showingOthers ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Text("Show all ports").font(.system(size: 11.5))
                Text(verbatim: "(\(model.snapshot.otherServers.count))")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                if model.snapshot.hasAlerts {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9)).foregroundStyle(.orange)
                        .help("An unrecognised listener is running")
                }
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(searching)
    }

    private var historyHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { showHistory.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showHistory ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 10))
                Text("Recently stopped").font(.system(size: 11.5))
                Text(verbatim: "(\(model.recentlyStopped.count))")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 9) {
            Circle().fill(Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.project + (entry.framework.map { " · \($0)" } ?? ""))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Text(verbatim: "was :\(entry.lastPort)").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            iconButton("play.circle", colour: .green, help: "Restart in Terminal") {
                if !model.restart(from: entry) { restartFailed = true }
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("Restart in Terminal") {
                if !model.restart(from: entry) { restartFailed = true }
            }
            Button("Forget", role: .destructive) { model.forget(entry) }
        }
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

            // Not SettingsLink: that is macOS 14 and up, and Quaydeck supports 13.
            Button { openSettingsWindow() } label: {
                Image(systemName: "gearshape").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Settings")

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: - Small pieces

    private func iconButton(_ symbol: String, colour: Color, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12)) }
            .buttonStyle(.plain).foregroundStyle(colour).help(help)
    }

    private func tag(_ text: String, _ colour: Color) -> some View {
        Text(text).font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Capsule().fill(colour.opacity(0.85)))
            .foregroundStyle(.white)
    }
}
