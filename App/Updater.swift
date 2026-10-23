import Foundation
import Sparkle

/// Updates from GitHub Releases via Sparkle. The feed is the latest release's appcast.xml
/// (SUFeedURL); each update's disk image must carry an EdDSA signature matching SUPublicEDKey
/// and be signed with the same certificate as the installed app.
@MainActor @Observable
final class Updater {
    private(set) var canCheck = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    /// Screenshot runs don't start it: no checks, no prompts.
    init(start: Bool) {
        controller = SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: nil, userDriverDelegate: nil)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = canCheck }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var checksAutomatically: Bool {
        get { access(keyPath: \.checksAutomatically); return controller.updater.automaticallyChecksForUpdates }
        set { withMutation(keyPath: \.checksAutomatically) { controller.updater.automaticallyChecksForUpdates = newValue } }
    }

    var installsAutomatically: Bool {
        get { access(keyPath: \.installsAutomatically); return controller.updater.automaticallyDownloadsUpdates }
        set { withMutation(keyPath: \.installsAutomatically) { controller.updater.automaticallyDownloadsUpdates = newValue } }
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}
