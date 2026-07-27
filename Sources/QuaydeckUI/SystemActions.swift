import AppKit
import Foundation
import QuaydeckCore

/// Everything Quaydeck asks macOS to do on the user's behalf: open a browser, reveal a
/// folder, put a command in a terminal.
public struct SystemActions {

    /// Editors we know how to open a folder in, in the order we prefer them.
    private static let editorBundleIdentifiers = [
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.microsoft.VSCode",
        "com.visualstudio.code.oss",
        "dev.zed.Zed",
        "com.sublimetext.4",
        "com.jetbrains.WebStorm",
        "com.apple.dt.Xcode",
    ]

    /// Terminals we know how to run a command in.
    private static let terminalBundleIdentifiers = [
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "com.apple.Terminal",
    ]

    public init() {}

    public func open(_ server: LocalServer) {
        guard let url = URL(string: server.url) else { return }
        NSWorkspace.shared.open(url)
    }

    public func copyURL(_ server: LocalServer) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(server.url, forType: .string)
    }

    public func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    public func openInEditor(_ path: String) {
        let workspace = NSWorkspace.shared
        for identifier in Self.editorBundleIdentifiers {
            if let application = workspace.urlForApplication(withBundleIdentifier: identifier) {
                workspace.open([URL(fileURLWithPath: path)], withApplicationAt: application,
                               configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        workspace.open(URL(fileURLWithPath: path))
    }

    public func openTerminal(at path: String) {
        let terminal = Self.terminalBundleIdentifiers
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
        guard let terminal else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// Run a command in Terminal.app.
    ///
    /// This drives another application, so macOS asks the user for Automation
    /// permission the first time. If they decline, nothing happens and we say so
    /// rather than failing silently.
    @discardableResult
    public func runInTerminal(_ command: String) -> Bool {
        let script = "tell application \"Terminal\"\nactivate\ndo script \(Self.quoteForAppleScript(command))\nend tell"
        guard let apple = NSAppleScript(source: script) else { return false }
        var error: NSDictionary?
        apple.executeAndReturnError(&error)
        return error == nil
    }

    /// Best guess at how to start a project's dev server: read the package manager
    /// from the lockfile and the script from the manifest, and fall back to re-running
    /// whatever the process was launched with.
    public func devCommand(projectPath: String?, fallbackArgs: String?, cwd: String?) -> String? {
        let fileManager = FileManager.default
        if let projectPath, fileManager.fileExists(atPath: projectPath + "/package.json") {
            let manager: String
            if fileManager.fileExists(atPath: projectPath + "/pnpm-lock.yaml") { manager = "pnpm" }
            else if fileManager.fileExists(atPath: projectPath + "/yarn.lock") { manager = "yarn" }
            else if fileManager.fileExists(atPath: projectPath + "/bun.lockb") { manager = "bun" }
            else if fileManager.fileExists(atPath: projectPath + "/bun.lock") { manager = "bun" }
            else { manager = "npm" }
            let script = packageHasScript("dev", at: projectPath) ? "dev"
                : packageHasScript("start", at: projectPath) ? "start" : "dev"
            return "cd \(Self.quoteForShell(projectPath)) && \(manager) run \(script)"
        }
        if let fallbackArgs, let directory = cwd ?? projectPath, !fallbackArgs.isEmpty {
            return "cd \(Self.quoteForShell(directory)) && \(fallbackArgs)"
        }
        return nil
    }

    private func packageHasScript(_ name: String, at path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path + "/package.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any] else { return false }
        return scripts[name] != nil
    }

    // MARK: - Quoting

    static func quoteForShell(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func quoteForAppleScript(_ text: String) -> String {
        "\"" + text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
