import Combine
import Foundation
import Sparkle

/// Wraps Sparkle so the rest of the app does not have to know about it.
///
/// The updater only starts when the bundle actually carries a feed URL and a public
/// key. A development build has neither, and starting Sparkle without them produces a
/// dialog complaining about the app's configuration on every launch.
@MainActor
final class Updater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    /// Whether this build is set up to receive updates at all.
    let isConfigured: Bool

    private let controller: SPUStandardUpdaterController?
    private var cancellables: Set<AnyCancellable> = []

    init(automaticallyChecks: Bool = true) {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        isConfigured = !(feed ?? "").isEmpty && !(key ?? "").isEmpty

        guard isConfigured else {
            controller = nil
            return
        }

        let controller = SPUStandardUpdaterController(startingUpdater: true,
                                                      updaterDelegate: nil,
                                                      userDriverDelegate: nil)
        controller.updater.automaticallyChecksForUpdates = automaticallyChecks
        self.controller = controller

        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
            .store(in: &cancellables)
    }

    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }
}
