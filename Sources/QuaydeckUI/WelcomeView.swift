import AppKit
import SwiftUI

/// Shown once, on first launch.
///
/// It exists to make two things explicit before Quaydeck does anything: what it reads
/// from the machine, and whether it may start at login. The previous version of this
/// app registered a login item silently the first time its menu was opened, which is
/// exactly the kind of thing that makes people distrust a menu bar utility.
public struct WelcomeView: View {
    @ObservedObject var model: AppModel
    var onFinish: () -> Void

    @State private var startAtLogin = false
    @State private var enableNotifications = false

    public init(model: AppModel, onFinish: @escaping () -> Void) {
        self.model = model
        self.onFinish = onFinish
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 16) {
                point(icon: "eye",
                      title: "It reads, locally",
                      detail: "Quaydeck runs lsof and ps to see which ports are listening, and reads "
                            + "your project files to name them. All of it stays on this Mac.")

                point(icon: "wifi.slash",
                      title: "It sends nothing",
                      detail: "No account, no analytics, no telemetry, no network calls except to "
                            + "your own localhost servers to read their page title.")

                Divider().padding(.vertical, 2)

                Toggle(isOn: $startAtLogin) {
                    Text("Start Quaydeck at login").font(.system(size: 13))
                }
                Toggle(isOn: $enableNotifications) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notify me about new and unrecognised listeners").font(.system(size: 13))
                        Text("macOS will ask for permission the first time.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)

            Spacer(minLength: 0)
            Divider()

            HStack {
                Link("Read the privacy note", destination: URL(string: "https://quaydeck.app/privacy")!)
                    .font(.caption)
                Spacer()
                Button("Start Using Quaydeck", action: finish)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 56, height: 56)
                .accessibilityHidden(true)
            Text("Quaydeck").font(.system(size: 24, weight: .bold))
            Text("Every dev server running on this Mac, in your menu bar.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private func point(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15)).foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func finish() {
        // Both of these only happen because the user ticked the box on this screen.
        if startAtLogin { model.loginItem.set(true) }
        if enableNotifications { model.setNotificationsEnabled(true) }
        model.preferences.completedFirstRun = true
        onFinish()
    }
}
