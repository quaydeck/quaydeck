import AppKit

/// Opens the Settings scene.
///
/// `SettingsLink` would be the obvious answer, but it is macOS 14 and up and Quaydeck
/// supports 13. The selector changed name in the same release, so both are tried.
@MainActor
public func openSettingsWindow() {
    NSApp.activate(ignoringOtherApps: true)
    if #available(macOS 14, *) {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    } else {
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}
