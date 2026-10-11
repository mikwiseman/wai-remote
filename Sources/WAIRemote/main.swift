import AppKit
import SwiftUI
import Combine
import RemoteCore
import WebRTC

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let updater = AppUpdater()
    var model: HostModel!
    var viewer: MacViewerModel!
    var window: NSWindow!
    var viewerWindow: NSWindow?
    var diagnosticsWindow: NSWindow?
    var statusItem: NSStatusItem!
    private var subscriptions = Set<AnyCancellable>()
    private var pendingURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "WAI Remote"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 680, height: 610)
        window.contentViewController = NSHostingController(rootView: ProgressView("Открываем WAI Remote…").frame(width: 740, height: 680))
        window.center(); window.makeKeyAndOrderFront(nil)
        makeMenus()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try KeyStore.identity() }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let identity):
                    self.model = HostModel(identity: identity)
                    self.viewer = MacViewerModel(identity: identity)
                    if UserDefaults.standard.bool(forKey: "continueSharingAfterPermissionRestart") {
                        UserDefaults.standard.removeObject(forKey: "continueSharingAfterPermissionRestart")
                        self.model.permissionRequested = true
                        self.model.start(lab: false)
                    }
                    self.window.contentViewController = NSHostingController(rootView: HomeView(host: self.model, viewer: self.viewer, connect: self.connect))
                    self.model.$pending.sink { [weak self] value in if value != nil { self?.showWindow() } }.store(in: &self.subscriptions)
                    self.model.$sharing.sink { [weak self] value in self?.statusItem.button?.toolTip = value ? "WAI Remote · доступ к экрану открыт" : "WAI Remote · доступ закрыт" }.store(in: &self.subscriptions)
                    self.viewer.$computerName.sink { [weak self] name in self?.viewerWindow?.title = "\(name) — WAI Remote" }.store(in: &self.subscriptions)
                    if let url = self.pendingURL { self.viewer.open(url); self.pendingURL = nil }
                case .failure(let error):
                    let alert = NSAlert(); alert.messageText = "Не удалось открыть ключ устройства"
                    alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil)
                }
            }
        }
    }
    private func makeMenus() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = Bundle.main.url(forResource: "MenuTemplate", withExtension: "png").flatMap(NSImage.init(contentsOf:))
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true; statusItem.button?.image = image
        let menu = NSMenu()
        menu.addItem(withTitle: "Открыть WAI Remote", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Закрыть доступ к экрану", action: #selector(stop), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "О программе WAI Remote", action: #selector(about), keyEquivalent: "")
        menu.addItem(withTitle: "Проверить обновления…", action: #selector(checkUpdates), keyEquivalent: "")
        menu.addItem(withTitle: "Настройки…", action: #selector(diagnostics), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Завершить WAI Remote", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        let main = NSMenu(), appItem = NSMenuItem(); main.addItem(appItem); appItem.submenu = menu.copy() as? NSMenu
        let edit = NSMenuItem(title: "Правка", action: nil, keyEquivalent: ""), submenu = NSMenu(title: "Правка")
        submenu.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        submenu.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        submenu.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        submenu.addItem(withTitle: "Выделить всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = submenu; main.addItem(edit)
        let windows = NSMenuItem(title: "Окно", action: nil, keyEquivalent: ""), windowMenu = NSMenu(title: "Окно")
        windowMenu.addItem(withTitle: "Свернуть", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Закрыть окно", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windows.submenu = windowMenu; main.addItem(windows); NSApp.windowsMenu = windowMenu; NSApp.mainMenu = main
    }
    func connect() {
        guard viewer != nil else { return }
        if !viewer.connected && !viewer.connecting { viewer.connect() }
        if viewerWindow == nil {
            let remote = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            remote.title = "\(viewer.computerName) — WAI Remote"; remote.isReleasedWhenClosed = false
            remote.contentMinSize = NSSize(width: 720, height: 480); remote.collectionBehavior = [.fullScreenPrimary]
            remote.delegate = self
            remote.contentViewController = NSHostingController(rootView: ViewerWindowView(model: viewer, fullScreen: { [weak remote] in remote?.toggleFullScreen(nil) }))
            remote.center(); viewerWindow = remote
        }
        viewerWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { if notification.object as? NSWindow === viewerWindow { viewer.disconnect() } }
    func windowDidResignKey(_ notification: Notification) { if notification.object as? NSWindow === viewerWindow { viewer.releaseInput() } }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func stop() { model?.stop() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func checkUpdates() { updater.check() }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func diagnostics() {
        guard let model else { return }
        if diagnosticsWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 440), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Настройки WAI Remote"; panel.isReleasedWhenClosed = false
            panel.contentViewController = NSHostingController(rootView: DiagnosticsView(model: model, updater: updater))
            panel.center(); diagnosticsWindow = panel
        }
        diagnosticsWindow?.makeKeyAndOrderFront(nil)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let viewer { viewer.open(url); showWindow() } else { pendingURL = url }
    }
    func applicationWillTerminate(_ notification: Notification) { viewer?.disconnect(); model?.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
}

private struct DiagnosticsView: View {
    @ObservedObject var model: HostModel
    @ObservedObject var updater: AppUpdater
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Обновления").font(.headline)
            Text("Версия \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))").font(.caption).foregroundStyle(.secondary)
            Toggle("Проверять автоматически", isOn: Binding(get: { updater.automaticChecksEnabled }, set: { updater.automaticChecksEnabled = $0 }))
            Text("Установка начинается только по вашему нажатию.").font(.caption).foregroundStyle(.secondary)
            if let failure = updater.startupFailure { Text(failure).font(.caption).foregroundStyle(.red) }
            Button("Проверить обновления…") { updater.check() }.disabled(!updater.canCheckForUpdates && updater.startupFailure == nil)
            Divider()
            DisclosureGroup("Диагностика") {
            VStack(alignment: .leading, spacing: 12) {
            Text("Сервер подключения").font(.headline)
            TextField("https://…", text: $model.gateway).textFieldStyle(.roundedBorder).disabled(model.sharing || model.starting)
            Text("Адрес нужен только для собственного сервера или проверки соединения.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("Открыть проверочный экран") { model.start(lab: true) }.disabled(model.sharing || model.starting)
            Button("Открыть проверку мыши и клавиатуры") { model.showInputTest() }
            }.padding(.top, 12)
            }
        }.padding(24).frame(width: 430, height: 440)
    }
}

MainActor.assumeIsolated {
    // Bound adaptive video smoothing to 70 ms on variable-latency routes.
    // A nonzero minimum enables pacing; 0 bypasses it in the pinned framework.
    // Input stays on its independent data channel. Configure before RTC objects.
    RTCInitFieldTrialDictionary(["WebRTC-ForcePlayoutDelay": "min_ms:1,max_ms:70"])
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    app.run()
}
