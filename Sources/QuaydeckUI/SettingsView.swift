import AppKit
import QuaydeckCore
import SwiftUI

public struct SettingsView: View {
    @ObservedObject var model: AppModel
    /// Supplied by the app target, which owns the updater.
    var checkForUpdates: (() -> Void)?
    var updatesAvailable: Bool

    public init(model: AppModel, updatesAvailable: Bool = false, checkForUpdates: (() -> Void)? = nil) {
        self.model = model
        self.updatesAvailable = updatesAvailable
        self.checkForUpdates = checkForUpdates
    }

    public var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            projects.tabItem { Label("Projects", systemImage: "folder") }
            about.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460, height: 320)
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section {
                Toggle("Start Quaydeck at login", isOn: Binding(
                    get: { model.loginItem.isEnabled },
                    set: { model.loginItem.set($0) }
                ))
                if let error = model.loginItem.lastError {
                    Text(error)
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("macOS only allows this for apps in your Applications folder.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Notify me about new dev servers and unrecognised listeners", isOn: Binding(
                    get: { model.preferences.notificationsEnabled },
                    set: { model.setNotificationsEnabled($0) }
                ))
                Text("Off by default. Quaydeck only asks macOS for permission once you turn this on.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if updatesAvailable {
                Section {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { model.preferences.checkForUpdates },
                        set: { model.preferences.checkForUpdates = $0 }
                    ))
                    if let checkForUpdates {
                        Button("Check Now", action: checkForUpdates)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Projects

    private var projects: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Project folders")
                .font(.headline)
            Text("Quaydeck finds projects on its own by looking for a package.json, go.mod, "
                 + "Cargo.toml, .git and similar. Add a folder here only if you keep projects "
                 + "that have none of those, and Quaydeck will name them after the folder instead.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(model.preferences.projectRoots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(abbreviate(root)).font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Button {
                            model.preferences.projectRoots.removeAll { $0 == root }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                if model.preferences.projectRoots.isEmpty {
                    Text("No folders added. Detection works without them.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(minHeight: 120)

            HStack {
                Button("Add Folder…", action: addFolder)
                Spacer()
            }
        }
        .padding(16)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        guard !model.preferences.projectRoots.contains(path) else { return }
        model.preferences.projectRoots.append(path)
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - About

    private var about: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text("Quaydeck").font(.title2).bold()
            Text("Version \(Self.version) (\(Self.build))")
                .font(.caption).foregroundStyle(.secondary)

            Text("Everything Quaydeck knows, it read from your own machine. "
                 + "Nothing is uploaded, and there is no analytics or telemetry of any kind.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            HStack(spacing: 14) {
                Link("Source", destination: URL(string: "https://github.com/quaydeck/quaydeck")!)
                Link("Privacy", destination: URL(string: "https://quaydeck.app/privacy")!)
                Link("Report an issue",
                     destination: URL(string: "https://github.com/quaydeck/quaydeck/issues/new")!)
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
}
