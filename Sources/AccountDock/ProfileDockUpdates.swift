import AppKit
import Combine
import Sparkle

@MainActor
final class ProfileDockUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var automatic = true
    @Published private(set) var sessionInProgress = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var enabled = false
    var mayUpdate: () -> Bool = { true }
    private var controller: SPUStandardUpdaterController?
    private var subscriptions = Set<AnyCancellable>()

    func start() {
        guard controller == nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).sink { [weak self] in self?.canCheck = $0 }.store(in: &subscriptions)
        updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] in self?.automatic = $0 }.store(in: &subscriptions)
        updater.publisher(for: \.sessionInProgress).sink { [weak self] in self?.sessionInProgress = $0 }.store(in: &subscriptions)
        updater.publisher(for: \.lastUpdateCheckDate).sink { [weak self] in self?.lastChecked = $0 }.store(in: &subscriptions)
        controller.startUpdater()
        enabled = true
    }
    func check() { guard mayUpdate(), canCheck else { return }; controller?.checkForUpdates(nil) }
    func setAutomatic(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard mayUpdate() else { throw NSError(domain: "ProfileDock", code: 1, userInfo: [NSLocalizedDescriptionKey: "Finish or cancel the ChatGPT update before updating ProfileDock."]) }
    }
}
