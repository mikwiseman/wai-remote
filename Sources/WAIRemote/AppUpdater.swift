import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var startupFailure: String?
    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
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
        catch { startupFailure = "Не удалось запустить обновления: " + error.localizedDescription }
    }
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
