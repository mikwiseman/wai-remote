import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var startupFailure: String?
    private(set) var relaunchingForUpdate = false
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    private var observation: NSKeyValueObservation?

    override init() {
        super.init()
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let feed = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init(string:))
        guard let key, Data(base64Encoded: key)?.count == 32,
              let feed, feed.scheme == "https", feed.host != nil, feed.user == nil, feed.password == nil else {
            startupFailure = "В этой сборке не настроена проверка подписи обновлений."
            return
        }
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
        do { try controller.updater.start() }
        catch {
            PerformanceLog.record("updater-error", ["domain": (error as NSError).domain, "code": (error as NSError).code])
            startupFailure = "Не удалось запустить проверку обновлений. Закройте WAI Remote и откройте снова."
        }
    }
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { relaunchingForUpdate = true }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { relaunchingForUpdate = false }
    var automaticChecksEnabled: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { objectWillChange.send(); controller.updater.automaticallyChecksForUpdates = newValue }
    }
    func check() {
        NSApp.activate(ignoringOtherApps: true)
        if let startupFailure {
            let alert = NSAlert(); alert.messageText = "Обновления недоступны"; alert.informativeText = startupFailure; alert.runModal()
        } else { controller.updater.checkForUpdates() }
    }
}
