import SwiftUI
import RemoteCore

/// The Mac's screen is the content. Controls float in one glass dock and get out of the way.
struct SessionView: View {
    @ObservedObject var model: PhoneModel
    @State private var typing = false
    @State private var zoomed = false
    @State private var greeting = false
    @Namespace private var glass
    @Environment(\.verticalSizeClass) private var verticalSize
    private var landscape: Bool { verticalSize == .compact }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RemoteScreen(model: model) { value in withAnimation(.smooth) { zoomed = value } }
                .ignoresSafeArea(.container)
            RemoteKeyboard(model: model, active: $typing).frame(width: 1, height: 1).opacity(0)
            VStack {
                HStack(alignment: .top) {
                    circleButton("Отключиться", symbol: "xmark") { model.disconnect() }
                    Spacer(minLength: 12)
                    if let status { pill(status).transition(.move(edge: .top).combined(with: .opacity)) }
                    Spacer(minLength: 12)
                    circleButton("Вписать экран", symbol: "arrow.down.right.and.arrow.up.left") { model.resetZoomRevision += 1 }
                        .opacity(zoomed ? 1 : 0).allowsHitTesting(zoomed)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 4)
            if !typing {
                let layout = landscape ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
                GlassGroup(spacing: 10) {
                    layout {
                        modeSwitch
                        if model.mode == .draw { drawingTools } else { controlTools }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: landscape ? .trailing : .bottom)
                .padding(landscape ? .trailing : .bottom, landscape ? 12 : 8)
                .transition(.move(edge: landscape ? .trailing : .bottom).combined(with: .opacity))
            }
        }
        .preferredColorScheme(.dark)
        .tint(Brand.mint)
        .statusBarHidden(landscape)
        .persistentSystemOverlays(.hidden)
        .animation(.spring(duration: 0.45, bounce: 0.2), value: model.mode)
        .animation(.spring(duration: 0.4, bounce: 0.15), value: typing)
        .animation(.smooth, value: status?.text)
        .onChange(of: model.receivedFrame) { _, shown in
            guard shown else { return }
            greeting = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { greeting = false }
        }
        .onChange(of: model.canControl) { _, allowed in if !allowed { typing = false } }
        .sensoryFeedback(.selection, trigger: model.mode)
    }

    // MARK: Status

    private struct Status { let text: String; let symbol: String?; let busy: Bool }
    private var status: Status? {
        if model.connectionInterrupted { return Status(text: "Восстанавливаем связь…", symbol: nil, busy: true) }
        if !model.receivedFrame { return Status(text: "Ждём изображение Mac…", symbol: nil, busy: true) }
        if model.mode == .paused { return Status(text: "Управление приостановлено на Mac", symbol: "pause.fill", busy: false) }
        if greeting { return Status(text: model.computerName, symbol: "lock.fill", busy: false) }
        return nil
    }
    private func pill(_ status: Status) -> some View {
        HStack(spacing: 8) {
            if status.busy { ProgressView().controlSize(.small) }
            else if let symbol = status.symbol { Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(Brand.mint) }
            Text(status.text).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .padding(.horizontal, 16).frame(height: 44)
        .glass(in: Capsule())
        .accessibilityElement(children: .combine)
    }

    // MARK: Dock

    private var modeSwitch: some View {
        let layout = landscape ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        return layout {
            modeButton(.control, symbol: "cursorarrow", title: "Управлять", allowed: model.session.state?.permissions.control == true)
            modeButton(.draw, symbol: "pencil.tip", title: "Рисовать", allowed: model.session.state?.permissions.annotate == true)
        }
        .padding(4)
        .glass(in: Capsule(), interactive: true)
        .glassID("mode", in: glass)
    }
    private func modeButton(_ mode: RemoteMode, symbol: String, title: String, allowed: Bool) -> some View {
        let selected = model.mode == mode
        return Button { model.changeMode(mode) } label: {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                .foregroundStyle(selected ? Brand.forest : .primary)
                .frame(width: 44, height: 44)
                .background { if selected { Circle().fill(Brand.mint).matchedGeometryEffect(id: "mode", in: glass) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(model.mode == .paused || !allowed || !model.receivedFrame)
        .accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var controlTools: some View {
        circleButton("Клавиатура", symbol: "keyboard", disabled: !model.canControl) { typing = true }
            .glassID("keyboard", in: glass)
        Menu {
            Button("Правый клик", systemImage: "contextualmenu.and.cursorarrow") { model.rightClick() }
            Button("Escape", systemImage: "escape") { model.key("Escape") }
        } label: { menuLabel }
            .disabled(!model.canControl)
            .accessibilityLabel("Ещё")
            .glassID("more", in: glass)
    }

    @ViewBuilder private var drawingTools: some View {
        let layout = landscape ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            ForEach([DrawingTool.pen, .marker, .arrow, .eraser]) { tool in
                Button { model.changeTool(tool) } label: {
                    Image(systemName: tool.symbol).font(.system(size: 17, weight: .medium))
                        .foregroundStyle(model.tool == tool ? Brand.mint : .primary.opacity(0.75))
                        .frame(width: 42, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tool.title).accessibilityAddTraits(model.tool == tool ? .isSelected : [])
            }
            Menu {
                ForEach(Array(InkStore.colors.enumerated()), id: \.offset) { index, color in
                    Button(["Коралловый", "Синий", "Жёлтый", "Зелёный"][index]) { model.color = color }
                }
                Divider()
                ForEach([2.0, 4.0, 8.0], id: \.self) { width in Button("Толщина \(Int(width))") { model.width = width } }
            } label: {
                Circle().fill(Color(uiColor: UIColor(hex: model.color)))
                    .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 2))
                    .frame(width: 22, height: 22).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Цвет и толщина")
        }
        .padding(.horizontal, landscape ? 2 : 6).padding(.vertical, landscape ? 6 : 2)
        .glass(in: Capsule(), interactive: true)
        .glassID("tools", in: glass)
        .disabled(!model.canDraw)
        Menu {
            Button("Отменить", systemImage: "arrow.uturn.backward") { model.editInk("undo") }
            Button("Повторить", systemImage: "arrow.uturn.forward") { model.editInk("redo") }
            Button("Выделить", systemImage: "cursorarrow") { model.changeTool(.select) }
            if model.selectedID != nil {
                Button("Удалить объект", systemImage: "trash", role: .destructive, action: model.deleteSelected)
            }
            Button("Очистить мои рисунки", systemImage: "trash", role: .destructive) { model.editInk("clear") }
        } label: { menuLabel } primaryAction: { model.editInk("undo") }
            .disabled(!model.canDraw)
            .accessibilityLabel("Отменить рисунок")
            .glassID("more", in: glass)
    }

    private var menuLabel: some View {
        Image(systemName: model.mode == .draw ? "arrow.uturn.backward" : "ellipsis")
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 52, height: 52)
            .glass(in: Circle(), interactive: true)
            .contentShape(Circle())
    }

    private func circleButton(_ title: String, symbol: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                .frame(width: 52, height: 52)
                .glass(in: Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.45 : 1)
        .accessibilityLabel(title)
    }
}
