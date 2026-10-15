#if ACOUPLET_SPARKLE
import Combine
import Foundation
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, @MainActor SPUStandardUserDriverDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var allowsAutomaticUpdates = false
    @Published private(set) var hasPendingUpdate = false

    /// False in development builds (Debug and `package.sh --local`), whose Info.plist has no update feed.
    /// Upstream's releases are signed with the same key, so an update from its feed would replace a local
    /// build of the fork and its LDAC fixes (decision D11). The updater is then never started.
    let isEnabled: Bool

    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)

    init(bundle: Bundle = .main) {
        isEnabled = Self.updatesEnabled(feed: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                                        distribution: bundle.object(forInfoDictionaryKey: "AcoupletDistribution") as? String)
        super.init()
        guard isEnabled else { return }
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloadsUpdates)
        controller.updater.publisher(for: \.allowsAutomaticUpdates).assign(to: &$allowsAutomaticUpdates)
    }

    nonisolated static func updatesEnabled(feed: String?, distribution: String?) -> Bool {
        guard let feed, !feed.isEmpty else { return false }
        return distribution != "development"
    }

    func start() {
        guard isEnabled else { return }
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard isEnabled else { return }
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard isEnabled else { return }
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard isEnabled else { return }
        controller.updater.automaticallyDownloadsUpdates = enabled
    }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        hasPendingUpdate = !state.userInitiated
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        hasPendingUpdate = false
    }

    func standardUserDriverWillFinishUpdateSession() {
        hasPendingUpdate = false
    }
}
#endif
