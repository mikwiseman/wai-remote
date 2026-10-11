import SwiftUI
import RemoteCore

@main struct WAIRemotePhoneApp: App {
    @StateObject private var model = PhoneModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            PhoneView(model: model)
                .tint(Color(red: 0.88, green: 0.35, blue: 0.28))
                .onOpenURL { model.open($0) }
                .onChange(of: phase) { _, value in
                    if value == .active { model.prepareIdentity() }
                    if value == .inactive, model.connected { model.releaseInput() }
                    if value == .background, model.connected || model.connecting { model.disconnect(message: "Сеанс завершён при сворачивании приложения") }
                }
        }
    }
}

struct PhoneView: View {
    @ObservedObject var model: PhoneModel
    @State private var keyboard = false
    @State private var text = ""
    @FocusState private var typing: Bool
    @Environment(\.verticalSizeClass) private var verticalSize
    private let warm = Color(red: 0.97, green: 0.96, blue: 0.93)
    var body: some View {
        Group { if model.connected { session } else { welcome } }
            .preferredColorScheme(.light)
            .onChange(of: model.mode) { _, mode in if mode != .control { keyboard = false } }
            .sheet(isPresented: $keyboard) { keyboardSheet }
    }
    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("WAI / REMOTE").font(.system(size: 13, weight: .bold, design: .monospaced)).tracking(3)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 32, weight: .light)).foregroundStyle(.tint).accessibilityHidden(true)
                }.padding(.top, 12)
                Text("Ваш Mac.\nПод рукой.").font(.system(size: 44, weight: .semibold, design: .rounded)).tracking(-2).fixedSize(horizontal: false, vertical: true)
                Text("Нажимайте, печатайте и рисуйте на экране Mac прямо с телефона.").font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    Text("ПРИГЛАШЕНИЕ С MAC").font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1.5)
                    TextField("Вставьте ссылку из WAI Remote", text: $model.invitation, axis: .vertical)
                        .lineLimit(2...3).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(size: 14, design: .monospaced)).padding(16).background(.white, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityIdentifier("invite").disabled(model.connecting)
                    HStack {
                        PasteButton(payloadType: String.self) { values in if let first = values.first { model.invitation = first } }
                            .labelStyle(.titleAndIcon).buttonBorderShape(.capsule).disabled(model.connecting)
                        Spacer()
                        if !model.invitation.isEmpty { Button("Очистить") { model.invitation = "" }.font(.subheadline) }
                    }
                    Button(action: model.connect) {
                        HStack { Text(model.connecting ? "Подключаемся…" : "Подключиться"); Spacer(); if model.connecting { ProgressView() } else { Image(systemName: "arrow.up.right") } }
                            .font(.headline).padding(20).frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 18))
                        .disabled(model.connecting || model.invitation.isEmpty || model.identity == nil).accessibilityIdentifier("connect")
                    if model.connecting { Button("Отменить") { model.disconnect() }.frame(maxWidth: .infinity) }
                }
                if model.status != "Ваш Mac. Под рукой." { Text(model.status).font(.headline).fixedSize(horizontal: false, vertical: true) }
                Text(model.detail).font(.subheadline).foregroundStyle(.secondary)
                Label("Первая версия · подключение по Wi-Fi", systemImage: "wifi").font(.footnote).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
        }.background(warm).scrollDismissesKeyboard(.interactively)
    }
    private var session: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: model.mode == .paused ? "pause.circle.fill" : "lock.shield.fill").foregroundStyle(model.mode == .paused ? Color.orange : Color.green)
                Text(model.status).font(.caption.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 0)
                Button { model.disconnect() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("Отключиться")
            }.padding(.horizontal, 14)
            ZStack {
                RemoteScreen(model: model)
                if !model.receivedFrame { ProgressView("Ждём изображение Mac…").tint(.white).foregroundStyle(.white).allowsHitTesting(false) }
                if model.mode == .paused { Text("Управление приостановлено на Mac").font(.headline).padding().background(.regularMaterial, in: Capsule()).allowsHitTesting(false) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if verticalSize == .compact { compactTools }
            else { VStack(spacing: 8) {
                HStack(spacing: 8) {
                    modeButton("Управлять", symbol: "cursorarrow", mode: .control, allowed: model.session.state?.permissions.control == true)
                    modeButton("Рисовать", symbol: "pencil.tip", mode: .draw, allowed: model.session.state?.permissions.annotate == true)
                    iconButton("Вписать экран", symbol: "arrow.down.right.and.arrow.up.left") { model.resetZoomRevision += 1 }
                }
                if model.mode == .draw { drawingTools }
                else {
                    HStack {
                        Button { keyboard = true } label: { Label("Клавиатура", systemImage: "keyboard").frame(height: 44) }.disabled(!model.canControl)
                        Spacer()
                        iconButton("Правый клик в последней точке", symbol: "computermouse.fill", disabled: !model.canControl) { model.rightClick() }
                        iconButton("Escape", symbol: "escape", disabled: !model.canControl) { model.key("Escape") }
                    }
                }
                Text(model.mode == .draw ? "Ластик удаляет объект целиком · можно отменить" : "Касание — клик · удержание — перетаскивание")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }.padding(.horizontal, 14).padding(.vertical, 10).background(warm) }
        }.background(warm)
    }
    private var compactTools: some View {
        HStack(spacing: 8) {
            ForEach([RemoteMode.control, .draw], id: \.rawValue) { mode in
                Button { model.changeMode(mode) } label: {
                    Image(systemName: mode == .control ? "cursorarrow" : "pencil.tip").frame(width: 44, height: 44)
                        .background(model.mode == mode ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 10))
                }.accessibilityLabel(mode == .control ? "Управлять" : "Рисовать")
                    .accessibilityAddTraits(model.mode == mode ? [.isSelected] : [])
                    .disabled(model.mode == .paused || !model.receivedFrame || (mode == .control ? model.session.state?.permissions.control != true : model.session.state?.permissions.annotate != true))
            }
            Divider().frame(height: 24)
            if model.mode == .draw {
                Menu {
                    ForEach(DrawingTool.allCases) { tool in Button { model.changeTool(tool) } label: { Label(tool.title, systemImage: tool.symbol) } }
                } label: { Image(systemName: model.tool.symbol).frame(width: 44, height: 44) }.accessibilityLabel("Инструмент: \(model.tool.title)")
                colorMenu
                iconButton("Отменить рисунок", symbol: "arrow.uturn.backward") { model.editInk("undo") }
                iconButton("Повторить рисунок", symbol: "arrow.uturn.forward") { model.editInk("redo") }
                if model.selectedID != nil { iconButton("Удалить объект", symbol: "trash") { model.deleteSelected() } }
                else { Menu { Button("Очистить мои рисунки", role: .destructive) { model.editInk("clear") } } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Ещё") }
            } else {
                iconButton("Клавиатура", symbol: "keyboard", disabled: !model.canControl) { keyboard = true }
                iconButton("Правый клик в последней точке", symbol: "computermouse.fill", disabled: !model.canControl) { model.rightClick() }
                iconButton("Escape", symbol: "escape", disabled: !model.canControl) { model.key("Escape") }
            }
            Spacer(minLength: 0)
            iconButton("Вписать экран", symbol: "arrow.down.right.and.arrow.up.left") { model.resetZoomRevision += 1 }
        }.padding(.horizontal, 14).padding(.vertical, 4).background(warm)
    }
    private func modeButton(_ title: String, symbol: String, mode: RemoteMode, allowed: Bool) -> some View {
        Button { model.changeMode(mode) } label: {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 44)
                .background(model.mode == mode ? Color.primary : Color.clear, in: RoundedRectangle(cornerRadius: 13))
                .foregroundStyle(model.mode == mode ? .white : .primary)
        }.disabled(model.mode == .paused || !allowed || !model.receivedFrame)
            .accessibilityAddTraits(model.mode == mode ? [.isSelected] : [])
    }
    private var drawingTools: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(DrawingTool.allCases) { tool in
                    Button { model.changeTool(tool) } label: {
                        Image(systemName: tool.symbol).frame(maxWidth: .infinity).frame(height: 44)
                            .background(model.tool == tool ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                    }.accessibilityLabel(tool.title).accessibilityAddTraits(model.tool == tool ? [.isSelected] : [])
                }
                colorMenu
            }
            HStack {
                iconButton("Отменить рисунок", symbol: "arrow.uturn.backward") { model.editInk("undo") }
                iconButton("Повторить рисунок", symbol: "arrow.uturn.forward") { model.editInk("redo") }
                Spacer()
                if model.selectedID != nil { Button("Удалить объект", role: .destructive, action: model.deleteSelected).font(.subheadline).frame(height: 44) }
                else { Button("Очистить мои", role: .destructive) { model.editInk("clear") }.font(.subheadline).frame(height: 44) }
            }
        }.disabled(!model.canDraw)
    }
    private var colorMenu: some View {
        Menu {
            ForEach(Array(InkStore.colors.enumerated()), id: \.offset) { index, color in
                Button(["Коралловый", "Синий", "Жёлтый", "Зелёный"][index]) { model.color = color }
            }
            Divider()
            ForEach([2.0, 4.0, 8.0], id: \.self) { width in Button("Толщина \(Int(width))") { model.width = width } }
        } label: { Circle().fill(Color(uiColor: UIColor(hex: model.color))).frame(width: 22, height: 22).frame(width: 44, height: 44) }.accessibilityLabel("Цвет и толщина")
    }
    private func iconButton(_ label: String, symbol: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 18)).frame(width: 44, height: 44) }.accessibilityLabel(label).disabled(disabled)
    }
    private var keyboardSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Текст на Mac").font(.headline); Spacer(); Button("Готово") { keyboard = false } }
            HStack {
                TextField("Введите текст", text: $text, axis: .vertical).lineLimit(1...4).focused($typing).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                Button { model.text(text); text = "" } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }.disabled(text.isEmpty || text.utf16.count > 4096 || !model.canControl).accessibilityLabel("Ввести на Mac")
            }
            HStack {
                Button("⌘A") { model.key("KeyA", modifiers: ["Meta"]) }.accessibilityLabel("Выделить всё на Mac")
                Spacer(); Button("Tab") { model.key("Tab") }; Spacer(); Button("⌫") { model.key("Backspace") }.accessibilityLabel("Backspace")
                Spacer(); Button("↵ Enter") { model.key("Enter") }
            }.buttonStyle(.bordered).disabled(!model.canControl)
        }.padding(24).presentationDetents([.height(220)]).presentationDragIndicator(.visible)
            .onAppear { typing = true }.onDisappear { text = "" }
    }
}
