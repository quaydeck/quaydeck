import Foundation
import ServiceManagement

/// Start-at-login, as an explicit user choice.
///
/// Quaydeck never registers itself. A menu bar utility that silently adds a login item
/// on first launch is the fastest way to lose someone's trust, so this only ever moves
/// when the user moves it.
@MainActor
public final class LoginItem: ObservableObject {
    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var lastError: String?

    public init() {
        self.isEnabled = SMAppService.mainApp.status == .enabled
    }

    public func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    public func set(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // The common cause is the app not living in /Applications, where macOS
            // refuses to register a login item. Say so rather than silently reverting.
            lastError = error.localizedDescription
        }
        refresh()
    }
}
