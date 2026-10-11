import AppKit
import SwiftUI
import RemoteCore

struct HomeView: View {
    @ObservedObject var host: HostModel
    @ObservedObject var viewer: MacViewerModel
    let connect: () -> Void
    @State private var sharingTab = false
    @State private var copied = false
    @State private var editing: SavedComputer?
    @State private var computerName = ""
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { colorScheme == .dark ? Color(red: 0.66, green: 0.84, blue: 0.72) : Color(red: 0.19, green: 0.34, blue: 0.28) }
    private func connectInvitation() { viewer.invitation = viewer.invitationDraft; connect() }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                Text("WAI Remote").font(.system(size: 15, weight: .semibold))
                Spacer()
                Label(host.sharing ? "Ваш экран доступен" : "Ваш экран закрыт", systemImage: host.sharing ? "circle.fill" : "lock.fill")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(host.sharing ? accent : .secondary)
            }.padding(.horizontal, 30).padding(.top, 22).padding(.bottom, 24)
            Picker("Что вы хотите сделать", selection: $sharingTab) {
                Text("Подключиться").tag(false)
                Text("Поделиться экраном").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 360)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if sharingTab { shareContent } else { connectContent }
                }.frame(maxWidth: 560, alignment: .leading).padding(.horizontal, 36).padding(.vertical, 32).frame(maxWidth: .infinity)
            }
            HStack {
                Text("Далеко. И всё же рядом.")
                Spacer()
                Text("macOS · WAI")
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 30).padding(.bottom, 20)
        }
        .frame(minWidth: 680, minHeight: 610)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .onAppear { if host.starting || host.sharing || host.permissionRequested { sharingTab = true } }
        .onChange(of: host.pending?.id) { _, pending in if pending != nil { sharingTab = true } }
        .sheet(item: $editing) { computer in
            VStack(alignment: .leading, spacing: 18) {
                Text("Как назвать этот Mac?").font(.title2.weight(.semibold))
                TextField("Например, Mac mini дома", text: $computerName).textFieldStyle(.roundedBorder)
                HStack { Button("Отмена") { editing = nil }; Spacer(); Button("Сохранить") { viewer.rename(computer.id, name: computerName); editing = nil }.keyboardShortcut(.defaultAction) }
            }.padding(28).frame(width: 360)
        }
    }
    private func title(_ text: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text).font(.system(size: 38, weight: .semibold)).tracking(-1.3).fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var connectContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            title("Другой Mac.\nПрямо перед вами.", subtitle: "Откройте его экран здесь. Работайте мышью и клавиатурой, будто сидите рядом.")
            VStack(alignment: .leading, spacing: 10) {
                Text("Приглашение с другого Mac").font(.system(size: 12, weight: .medium))
                HStack(spacing: 10) {
                    TextField("Вставьте ссылку подключения", text: $viewer.invitationDraft).textFieldStyle(.roundedBorder)
                        .controlSize(.large).onSubmit(connectInvitation).accessibilityIdentifier("connectionInvitation")
                    Button("Подключиться", action: connectInvitation).buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(viewer.invitationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewer.connecting)
                }
                Text("На другом Mac: WAI Remote → Поделиться экраном → Скопировать приглашение.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !viewer.computers.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("ВАШИ КОМПЬЮТЕРЫ").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                    ForEach(viewer.computers) { computer in
                        HStack(spacing: 14) {
                            Image(systemName: "desktopcomputer").font(.system(size: 23)).foregroundStyle(accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(computer.name).font(.system(size: 14, weight: .medium))
                                Text("Сохранённое подключение").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Открыть") { viewer.invitation = computer.invitation; connect() }
                                .disabled(viewer.connecting)
                            Menu {
                                Button("Переименовать…") { computerName = computer.name; editing = computer }
                                Button("Забыть этот Mac", role: .destructive) { viewer.forget(computer.id) }
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
                        }.padding(.vertical, 4)
                    }
                }
            } else {
                Label("После первого подключения Mac появится здесь.", systemImage: "bookmark")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
    }
    private var shareContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            title(host.sharing ? "Можно подключаться." : "Ваш экран.\nПо вашему приглашению.", subtitle: host.sharing ? "Новые устройства подключаются только с вашего согласия." : "Отправьте приглашение себе или человеку, которому доверяете. Вы решаете, кто увидит экран.")
            if (!host.sharing || !host.isLab) && (!host.screenAllowed || !host.controlAllowed) {
                VStack(alignment: .leading, spacing: 16) {
                    if !host.screenAllowed { permission("Показать экран", detail: "Включите WAI Remote в разделе записи экрана macOS, затем вернитесь сюда.", action: host.requestScreen) }
                    if !host.controlAllowed { permission("Управлять мышью и клавиатурой", detail: "Включите WAI Remote в настройках управления macOS. Разрешение подхватится после возвращения.", action: host.requestControl) }
                    if host.permissionRequested {
                        Text("Если macOS попросила перезапуск или разрешение уже включено, продолжите после перезапуска приложения.").font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("Перезапустить и продолжить") { host.restartForPermissions() }
                    }
                }
            }
            if let pending = host.pending {
                VStack(alignment: .leading, spacing: 14) {
                    Label("\(pending.offer.name) хочет подключиться", systemImage: "person.crop.circle.badge.questionmark").font(.headline)
                    Text("Имя указано на другом устройстве. Подтвердите, только если ожидаете это подключение.").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Отклонить") { host.reject() }
                        Spacer()
                        Button("Только просмотр") { host.approve(control: false) }
                        Button("Разрешить управление") { host.approve(control: true) }.buttonStyle(.borderedProminent).disabled(!host.controlAllowed && !host.isLab)
                    }
                }.padding(20).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            }
            if host.sharing {
                if let name = host.connectedName {
                    Label(name, systemImage: "desktopcomputer").font(.headline)
                    Text(host.status).foregroundStyle(.secondary)
                    HStack {
                        Button(host.localDrawing ? "Закончить рисование" : "Рисовать вместе") { host.toggleLocalDraw() }
                        Button("Очистить рисунки") { host.clearInk() }
                        Spacer()
                        Button("Отключить устройство") { host.disconnectViewer() }
                    }
                } else if !host.invite.isEmpty {
                    HStack(spacing: 14) {
                        Button(copied ? "Приглашение скопировано" : "Скопировать приглашение") {
                            host.copyInvite(); copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { copied = false }
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                        Text("На 10 минут.\nДля одного нового устройства.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } else if !host.starting {
                    Button("Создать приглашение") { host.newInvite() }.controlSize(.large)
                }
                Divider()
                HStack {
                    Label("Доступ открыт", systemImage: "circle.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
                    Spacer()
                    Button("Закрыть доступ") { host.stop() }.foregroundStyle(.red).controlSize(.large)
                }
                Text("Блокировка и сон Mac закрывают доступ. Уже разрешённые устройства могут подключаться, пока доступ открыт.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Button { host.start(lab: false) } label: {
                    HStack { if host.starting { ProgressView().controlSize(.small) }; Text(host.starting ? "Открываем доступ…" : "Открыть доступ к экрану") }
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(host.starting || !host.screenAllowed)
                if host.status != "Доступ закрыт" { Text(host.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Text("Пока доступ закрыт, никто не может увидеть ваш экран.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !host.peers.isEmpty {
                DisclosureGroup("Разрешённые устройства · \(host.peers.count)") {
                    ForEach(host.peers) { peer in
                        HStack { Text(peer.name); Spacer(); Button("Отозвать доступ") { host.forget(peer.id) } }.padding(.top, 10)
                    }
                }.font(.system(size: 12))
            }
        }
    }
    private func permission(_ text: String, detail: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.open").foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 4) { Text(text).font(.system(size: 13, weight: .medium)); Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
            Spacer()
            Button("Разрешить…", action: action)
        }
    }
}
