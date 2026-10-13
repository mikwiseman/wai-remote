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
    private var viewerToolbar: ViewerToolbar?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "WAI Remote"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 560, height: 480)
        window.contentViewController = NSHostingController(rootView: ProgressView("Открываем WAI Remote…").frame(width: 640, height: 600))
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
                    self.window.setContentSize(NSSize(width: 640, height: 600))
                    self.model.$pending.sink { [weak self] value in if value != nil { self?.showHome() } }.store(in: &self.subscriptions)
                    self.model.$sharing.sink { [weak self] value in self?.statusItem.button?.toolTip = value ? "WAI Remote, доступ к экрану открыт" : "WAI Remote, доступ закрыт" }.store(in: &self.subscriptions)
                    self.viewer.$computerName.sink { [weak self] name in self?.viewerWindow?.title = name }.store(in: &self.subscriptions)
                    if let url = self.pendingURL { self.viewer.open(url); self.pendingURL = nil }
                case .failure(let error):
                    PerformanceLog.record("identity-error", ["domain": (error as NSError).domain, "code": (error as NSError).code])
                    let alert = NSAlert(); alert.messageText = "Не удалось открыть WAI Remote"
                    alert.informativeText = "Не удалось прочитать данные устройства. Закройте WAI Remote и откройте снова."; alert.runModal(); NSApp.terminate(nil)
                }
            }
        }
    }
    func makeMenus() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = Bundle.main.url(forResource: "MenuTemplate", withExtension: "png").flatMap(NSImage.init(contentsOf:))
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true; statusItem.button?.image = image
        let menu = NSMenu()
        menu.addItem(withTitle: "Открыть WAI Remote", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Подключение и доступ…", action: #selector(showHome), keyEquivalent: "")
        menu.addItem(withTitle: "Закрыть доступ к экрану", action: #selector(stop), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "О программе WAI Remote", action: #selector(about), keyEquivalent: "")
        menu.addItem(withTitle: "Проверить обновления…", action: #selector(checkUpdates), keyEquivalent: "")
        menu.addItem(withTitle: "Настройки…", action: #selector(diagnostics), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Завершить WAI Remote", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        let main = NSMenu(), appItem = NSMenuItem(); main.addItem(appItem); appItem.submenu = menu.copy() as? NSMenu
        if let appMenu = appItem.submenu {
            let hide = NSMenuItem(title: "Скрыть WAI Remote", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
            hide.target = NSApp
            let hideOthers = NSMenuItem(title: "Скрыть остальные", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            hideOthers.keyEquivalentModifierMask = [.command, .option]; hideOthers.target = NSApp
            let showAll = NSMenuItem(title: "Показать все", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
            showAll.target = NSApp
            for item in [hide, hideOthers, showAll, .separator()] { appMenu.insertItem(item, at: appMenu.numberOfItems - 1) }
        }
        let edit = NSMenuItem(title: "Правка", action: nil, keyEquivalent: ""), submenu = NSMenu(title: "Правка")
        submenu.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        submenu.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        submenu.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        submenu.addItem(withTitle: "Выделить всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = submenu; main.addItem(edit)
        let windows = NSMenuItem(title: "Окно", action: nil, keyEquivalent: ""), windowMenu = NSMenu(title: "Окно")
        let home = windowMenu.addItem(withTitle: "Подключение и доступ…", action: #selector(showHome), keyEquivalent: "0")
        home.target = self
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Свернуть", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Закрыть окно", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let release = windowMenu.addItem(withTitle: "Освободить клавиатуру", action: #selector(releaseKeyboard), keyEquivalent: "\u{1b}")
        release.keyEquivalentModifierMask = [.command, .option]; release.target = self
        windows.submenu = windowMenu; main.addItem(windows); NSApp.windowsMenu = windowMenu; NSApp.mainMenu = main
    }
    func connect() {
        guard viewer != nil else { return }
        if !viewer.connected && !viewer.connecting { viewer.connect() }
        if viewerWindow == nil {
            let size = NSSize(width: 1200, height: 780)
            let remote = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            remote.title = viewer.computerName; remote.isReleasedWhenClosed = false
            remote.contentMinSize = NSSize(width: 640, height: 420); remote.collectionBehavior = [.fullScreenPrimary]
            remote.delegate = self
            remote.contentViewController = NSHostingController(rootView: ViewerWindowView(model: viewer))
            viewerToolbar = ViewerToolbar(model: viewer, window: remote)
            remote.setContentSize(size)
            remote.center(); viewerWindow = remote
        }
        window?.orderOut(nil)
        if viewerWindow?.isMiniaturized == true { viewerWindow?.deminiaturize(nil) }
        viewerWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { if notification.object as? NSWindow === viewerWindow { viewer.disconnect() } }
    func windowDidResignKey(_ notification: Notification) { if notification.object as? NSWindow === viewerWindow { viewer.releaseInput() } }
    @objc func releaseKeyboard() { viewer?.releaseInput(); viewerWindow?.makeFirstResponder(nil) }
    @objc func showWindow() {
        if let viewer, viewer.connected || viewer.connecting, let viewerWindow {
            if viewerWindow.isMiniaturized { viewerWindow.deminiaturize(nil) }
            viewerWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else { showHome() }
    }
    @objc func showHome() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
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
        if let viewer {
            viewer.open(url)
            if viewer.connected || viewer.connecting { showWindow() } else { showHome() }
        } else { pendingURL = url }
    }
    func applicationWillTerminate(_ notification: Notification) { viewer?.disconnect(); model?.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return false }
}

private struct DiagnosticsView: View {
    @ObservedObject var model: HostModel
    @ObservedObject var updater: AppUpdater
    var body: some View {
        Form {
            Section("Обновления") {
                LabeledContent("Версия", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                Toggle("Проверять автоматически", isOn: Binding(get: { updater.automaticChecksEnabled }, set: { updater.automaticChecksEnabled = $0 }))
                if let failure = updater.startupFailure { Text(failure).font(.callout).foregroundStyle(.red) }
                Button("Проверить обновления…") { updater.check() }.disabled(!updater.canCheckForUpdates && updater.startupFailure == nil)
            }
            Section {
                DisclosureGroup("Диагностика") {
                    TextField("Сервер подключения", text: $model.gateway).disabled(model.sharing || model.starting)
                    Text("Для собственного сервера или проверки соединения.").font(.caption).foregroundStyle(.secondary)
                    Button("Проверка изображения") { model.start(lab: true) }.disabled(model.sharing || model.starting)
                    Button("Проверка мыши и клавиатуры") { model.showInputTest() }
                }
            }
        }.formStyle(.grouped).frame(width: 430, height: 440)
    }
}

MainActor.assumeIsolated {
    ScreenVideoPolicy.initializeWebRTC()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    app.run()
}
