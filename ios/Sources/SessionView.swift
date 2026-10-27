import SwiftUI
import RemoteCore

/// The Mac's screen is the content. Controls float in glass at its edges and get out of the way.
struct SessionView: View {
    @ObservedObject var model: PhoneModel
    @State private var typing = false
    @State private var zoomed = false
    @State private var greeting = false
    @StateObject private var modifiers = KeyboardModifiers()
    @Namespace private var glass
    @Namespace private var selection
    @Environment(\.verticalSizeClass) private var verticalSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var landscape: Bool { verticalSize == .compact }
    /// Controls line up along the bottom in portrait and down the trailing edge in landscape.
    private func line(_ spacing: CGFloat, @ViewBuilder _ content: () -> some View) -> some View {
        let layout = landscape ? AnyLayout(VStackLayout(spacing: spacing)) : AnyLayout(HStackLayout(spacing: spacing))
        return layout { content() }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Edge to edge; while typing it sits between the top controls and the keyboard.
            RemoteScreen(model: model) { zoomed = $0 }
                .ignoresSafeArea(.container, edges: typing ? .horizontal : .all)
            RemoteKeyboard(model: model, modifiers: modifiers, active: $typing).frame(width: 1, height: 1).opacity(0)
            edges
            if !typing { dock.transition(slide(landscape ? .trailing : .bottom)) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if typing { KeyboardBar(model: model, modifiers: modifiers) { typing = false }.transition(.opacity) }
        }
        .preferredColorScheme(.dark)
        .tint(Brand.mint)
        .statusBarHidden(landscape)
        .persistentSystemOverlays(.hidden)
        .animation(motion(.spring(duration: 0.45, bounce: 0.2)), value: model.mode)
        .animation(motion(.spring(duration: 0.35, bounce: 0.2)), value: model.tool)
        .animation(motion(.spring(duration: 0.4, bounce: 0.15)), value: typing)
        .animation(motion(.smooth), value: zoomed)
        .animation(motion(.smooth), value: status)
        .onChange(of: model.receivedFrame) { _, shown in
            guard shown else { return }
            greeting = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { greeting = false }
        }
        .onChange(of: model.canControl) { _, allowed in if !allowed { typing = false } }
        .sensoryFeedback(.selection, trigger: model.mode)
        .sensoryFeedback(.selection, trigger: model.tool)
        #if DEBUG
        .onAppear { if PhoneModel.demoMoment == "typing" { typing = true } }
        #endif
    }

    private func motion(_ animation: Animation) -> Animation { reduceMotion ? .easeInOut(duration: 0.2) : animation }
    private func slide(_ edge: Edge) -> AnyTransition { reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity) }

    // MARK: Edges

    /// Leaving sits in the corner; fitting the screen appears only once it is zoomed.
    private var edges: some View {
        GlassGroup(spacing: 12) {
            ZStack(alignment: .top) {
                line(12) {
                    circleButton("Отключиться", symbol: "xmark", id: "leave") { model.disconnect() }
                    Spacer(minLength: 0)
                    if zoomed {
                        circleButton("Вписать экран", symbol: "arrow.down.right.and.arrow.up.left", id: "fit") { model.resetZoomRevision += 1 }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if let status { pill(status).padding(.top, 4).padding(.horizontal, landscape ? 0 : 76).transition(slide(.top)) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, landscape ? 12 : 4)
    }

    private struct Status: Equatable { let text: String; let symbol: String? }
    private var status: Status? {
        if model.connectionInterrupted { return Status(text: "Восстанавливаем связь…", symbol: nil) }
        if !model.receivedFrame { return Status(text: "Ждём изображение Mac…", symbol: nil) }
        if model.mode == .paused { return Status(text: "Пауза на Mac", symbol: "pause.fill") }
        if greeting { return Status(text: model.computerName, symbol: "lock.fill") }
        return nil
    }
    private func pill(_ status: Status) -> some View {
        HStack(spacing: 8) {
            if let symbol = status.symbol { Image(systemName: symbol).font(.caption.weight(.bold)).foregroundStyle(Brand.mint) }
            else { ProgressView().controlSize(.small) }
            Text(status.text).font(.subheadline.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.8)
        }
        .multilineTextAlignment(.center)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(.horizontal, 16).padding(.vertical, 8).frame(minHeight: 44)
        // A capsule at one line, a rounded card when large text wraps.
        .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .glassID("status", in: glass)
        .accessibilityElement(children: .combine)
    }

    // MARK: Dock

    private var live: Bool { model.canControl || model.canDraw }
    private var allowed: Permissions? { model.session.state?.permissions }

    private var dock: some View {
        GlassGroup(spacing: 10) {
            line(10) {
                modes
                if model.mode == .draw {
                    undo
                } else {
                    circleButton("Клавиатура", symbol: "keyboard", id: "keyboard", enabled: model.canControl) { typing = true }
                    more
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: landscape ? .trailing : .bottom)
        .padding(landscape ? .trailing : .bottom, landscape ? 16 : 8)
    }

    /// One capsule: the cursor controls the Mac, the pen opens into the drawing tools.
    private var modes: some View {
        let drawing = model.mode == .draw
        return line(0) {
            segment("Управлять", symbol: "cursorarrow", selected: model.mode == .control,
                    enabled: live && allowed?.control == true) { model.changeMode(.control) }
            ForEach(drawing ? [DrawingTool.pen, .marker, .arrow, .eraser] : [.pen]) { tool in
                segment(drawing ? tool.title : "Рисовать", symbol: tool.symbol, selected: drawing && model.tool == tool,
                        enabled: live && allowed?.annotate == true) { drawing ? model.changeTool(tool) : model.changeMode(.draw) }
            }
            if drawing { ink }
        }
        .padding(4)
        .glass(in: Capsule(), interactive: true)
        .glassID("modes", in: glass)
    }

    private func segment(_ title: String, symbol: String, selected: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                .foregroundStyle(selected ? Brand.forest : .primary)
                .opacity(enabled || selected ? 1 : 0.35)
                .frame(width: 44, height: 44)
                .background { if selected { Circle().fill(Brand.mint).matchedGeometryEffect(id: "selected", in: selection) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer { Label(title, systemImage: symbol) }
    }

    private static let inks = Array(zip(InkStore.colors, ["Коралловый", "Синий", "Жёлтый", "Зелёный"]))
    private static let widths: [(Double, String)] = [(2, "Тонкая"), (4, "Средняя"), (8, "Толстая")]

    /// A menu icon: a dot in its colour, or in the text's colour when it shows a width.
    private static func dot(_ diameter: CGFloat, _ color: UIColor?) -> Image {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 22, height: 22)).image { _ in
            (color ?? .black).setFill(); UIBezierPath(ovalIn: CGRect(x: 11 - diameter / 2, y: 11 - diameter / 2, width: diameter, height: diameter)).fill()
        }
        return Image(uiImage: image.withRenderingMode(color == nil ? .alwaysTemplate : .alwaysOriginal))
    }

    /// The dot shows the colour and, by its size, the line width.
    private var ink: some View {
        Menu {
            Picker("Цвет", selection: $model.color) {
                ForEach(Self.inks, id: \.0) { ink in
                    Label { Text(ink.1) } icon: { Self.dot(16, UIColor(hex: ink.0)) }.tag(ink.0)
                }
            }
            .pickerStyle(.inline)
            Picker("Толщина", selection: $model.width) {
                ForEach(Self.widths, id: \.0) { width in Label { Text(width.1) } icon: { Self.dot(4 + width.0 * 2, nil) }.tag(width.0) }
            }
            .pickerStyle(.inline)
        } label: {
            Circle().fill(Color(uiColor: UIColor(hex: model.color)))
                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
                .frame(width: 12 + model.width * 1.5, height: 12 + model.width * 1.5)
                .animation(motion(.spring(duration: 0.3, bounce: 0.3)), value: model.width)
                .frame(width: 44, height: 44).contentShape(Circle())
        }
        .disabled(!model.canDraw)
        .accessibilityLabel("Цвет и толщина")
        .accessibilityValue([Self.inks.first { $0.0 == model.color }?.1, Self.widths.first { $0.0 == model.width }?.1]
            .compactMap { $0 }.joined(separator: ", "))
    }

    private var undo: some View {
        Menu {
            Button("Повторить", systemImage: "arrow.uturn.forward") { model.editInk("redo") }
            Button("Выделить", systemImage: "cursorarrow") { model.changeTool(.select) }
            if model.selectedID != nil {
                Button("Удалить объект", systemImage: "trash", role: .destructive, action: model.deleteSelected)
            }
            Button("Очистить мои рисунки", systemImage: "trash", role: .destructive) { model.editInk("clear") }
        } label: {
            circle("arrow.uturn.backward", id: "more", enabled: model.canDraw)
        } primaryAction: { model.editInk("undo") }
        .disabled(!model.canDraw).tint(.primary)
        .accessibilityLabel("Отменить")
        .accessibilityHint("Удерживайте, чтобы повторить или очистить")
    }

    private var more: some View {
        Menu {
            Button("Правый клик", systemImage: "contextualmenu.and.cursorarrow") { model.rightClick() }
            Button("Escape", systemImage: "escape") { model.key("Escape") }
        } label: {
            circle("ellipsis", id: "more", enabled: model.canControl)
        }
        .disabled(!model.canControl).tint(.primary)
        .accessibilityLabel("Ещё")
    }

    private func circleButton(_ title: String, symbol: String, id: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) { circle(symbol, id: id, enabled: enabled) }
            .buttonStyle(.plain).disabled(!enabled)
            .accessibilityLabel(title)
            .accessibilityShowsLargeContentViewer { Label(title, systemImage: symbol) }
    }

    private func circle(_ symbol: String, id: String, enabled: Bool) -> some View {
        Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.primary).opacity(enabled ? 1 : 0.35)
            .frame(width: 52, height: 52)
            .contentShape(Circle())
            .glass(in: Circle(), interactive: true)
            .glassID(id, in: glass)
    }
}
