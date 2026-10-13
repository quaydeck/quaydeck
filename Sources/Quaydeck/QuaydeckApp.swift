import AppKit
import QuaydeckCore
import QuaydeckUI
import SwiftUI

/// Single owner of the long-lived objects, so the app scene and the app delegate can
/// both reach the same model without passing it through a scene.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let model: AppModel
    let updater: Updater

    private init() {
        let preferences = Preferences()
        model = AppModel(preferences: preferences,
                         // Everything in 1.0 is free, permanently. This is the seam a
                         // paid tier would replace, not a fork of the app.
                         entitlements: FreeEntitlements())
        updater = Updater(automaticallyChecks: preferences.checkForUpdates)
    }
}

@main
struct QuaydeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppEnvironment.shared.model
    @StateObject private var updater = AppEnvironment.shared.updater

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model,
                         updatesAvailable: updater.isConfigured,
                         checkForUpdates: updater.checkForUpdates)
                .onChange(of: model.preferences.checkForUpdates) { enabled in
                    updater.setAutomaticChecks(enabled)
                }
        }
    }

    /// The count is the useful thing at a glance. SF Symbols only carry numbered
    /// circles up to 50, so anything beyond that clamps.
    private var menuBarSymbol: String {
        let count = model.snapshot.devServers.count
        // A porthole with water in it, like the app icon.
        guard count > 0 else { return "circle.bottomhalf.filled" }
        return "\(min(count, 50)).circle.fill"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var welcomeWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard !AppEnvironment.shared.model.preferences.completedFirstRun else { return }
            showWelcome()
        }
    }

    @MainActor
    private func showWelcome() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(
            rootView: WelcomeView(model: AppEnvironment.shared.model) { [weak self] in
                self?.welcomeWindow?.close()
                self?.welcomeWindow = nil
            }
        )
        welcomeWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
