import AppKit
import Combine

/// Standard toolbar items inherit macOS materials, contrast and accessibility.
@MainActor
final class ViewerToolbar: NSObject, NSToolbarDelegate {
    private let model: MacViewerModel
    private weak var window: NSWindow?
    private let toolbar = NSToolbar(identifier: "remoteViewer")
    private var observation: AnyCancellable?
    private static let draw = NSToolbarItem.Identifier("draw")
    private static let undo = NSToolbarItem.Identifier("undoInk")
    private static let disconnect = NSToolbarItem.Identifier("disconnect")

    init(model: MacViewerModel, window: NSWindow) {
        self.model = model; self.window = window
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        observation = model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.refresh() }
        refresh()
    }

    private func refresh() {
        var items: [NSToolbarItem.Identifier] = [.flexibleSpace]
        if model.connected, model.session.state?.permissions.annotate == true {
            items.append(Self.draw)
            if model.mode == .draw { items.append(Self.undo) }
            items.append(.space)
        }
        if model.connected || model.connecting { items.append(Self.disconnect) }
        if toolbar.itemIdentifiers != items { toolbar.itemIdentifiers = items }
        let subtitle = !model.connected ? "" : model.connectionInterrupted ? "Соединение прервано" : model.mode == .paused ? "Управление приостановлено" : model.session.state?.permissions.control != true ? "Только просмотр" : model.session.state?.surface.id.hasPrefix("window:") == true ? "Отдельное окно" : ""
        if window?.subtitle != subtitle { window?.subtitle = subtitle }
        for item in toolbar.items where item.itemIdentifier == Self.draw {
            let drawing = model.mode == .draw
            let title = drawing ? (model.session.state?.permissions.control == true ? "Завершить рисование" : "Вернуться к просмотру") : "Рисовать"
            if item.label != title {
                item.label = title; item.toolTip = title
                item.image = NSImage(systemSymbolName: drawing ? (model.session.state?.permissions.control == true ? "cursorarrow" : "eye") : "pencil.tip", accessibilityDescription: title)
            }
            item.isEnabled = model.mode != .paused && !model.session.invalidated
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.draw, Self.undo, .space, Self.disconnect] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let title: String, symbol: String, action: Selector
        switch identifier {
        case Self.draw: title = "Рисовать"; symbol = "pencil.tip"; action = #selector(toggleDrawing)
        case Self.undo: title = "Отменить рисунок"; symbol = "arrow.uturn.backward"; action = #selector(undoDrawing)
        case Self.disconnect: title = "Отключиться"; symbol = "xmark"; action = #selector(disconnect)
        default: return nil
        }
        item.label = title; item.paletteLabel = title; item.toolTip = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.target = self; item.action = action; item.isBordered = true
        item.autovalidates = false
        return item
    }
    @objc private func toggleDrawing() { model.changeMode(model.mode == .draw ? .control : .draw) }
    @objc private func undoDrawing() { model.editInk("undo") }
    @objc private func disconnect() { model.disconnect() }
}
