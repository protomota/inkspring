import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class InkspringUpdates {
    let isConfigured = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String
    private(set) var canCheck = false
    private var controller: SPUStandardUpdaterController?
    private var availability: NSKeyValueObservation?

    func start() {
        guard isConfigured, controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        self.controller = controller
        availability = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.canCheck = self?.controller?.updater.canCheckForUpdates == true
            }
        }
        controller.startUpdater()
    }

    func check() {
        controller?.updater.checkForUpdates()
    }
}
