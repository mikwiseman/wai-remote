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
    private let accent = Color.accentColor
    private func connectInvitation() { viewer.invitation = viewer.invitationDraft; connect() }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                tab("Подключиться", sharing: false)
                tab("Поделиться экраном", sharing: true)
            }.padding(.top, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if sharingTab { shareContent } else { connectContent }
                }.frame(maxWidth: 560, alignment: .leading).padding(.horizontal, 32).padding(.vertical, 28).frame(maxWidth: .infinity)
            }
            if !sharingTab && host.sharing {
                Label("Доступ к вашему экрану открыт", systemImage: "record.circle")
                    .font(.callout).foregroundStyle(.secondary).padding(.bottom, 18)
            }
        }
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity, alignment: .top)
        .background { RemoteBackdrop() }
        .tint(accent)
        .onAppear { if host.starting || host.sharing || host.accessEnabled || host.permissionRequested { sharingTab = true } }
        .onChange(of: host.pending?.id) { _, pending in if pending != nil { sharingTab = true } }
        .sheet(item: $editing) { computer in
            VStack(alignment: .leading, spacing: 18) {
                Text("Название компьютера").font(.title2.weight(.semibold))
                TextField("Например, Mac mini дома", text: $computerName).textFieldStyle(.roundedBorder)
                HStack { Button("Отмена") { editing = nil }; Spacer(); Button("Сохранить") { viewer.rename(computer.id, name: computerName); editing = nil }.keyboardShortcut(.defaultAction) }
            }.padding(28).frame(width: 360)
        }
    }
    private func tab(_ title: String, sharing: Bool) -> some View {
        Button { sharingTab = sharing } label: {
            Text(title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(sharingTab == sharing ? .primary : .secondary)
                .frame(width: 170, height: 36)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(sharingTab == sharing ? accent : .clear).frame(height: 2)
                }.contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(sharingTab == sharing ? .isSelected : [])
            .accessibilityIdentifier(sharing ? "shareTab" : "connectTab")
    }
    private func title(_ text: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text).font(.system(size: 28, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var connectContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ваши компьютеры").font(.system(size: 30, weight: .semibold))
                Text("Откройте сохранённый Mac или добавьте новый.").font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Приглашение").font(.system(size: 12, weight: .medium))
                HStack(spacing: 10) {
                    TextField("Вставьте ссылку подключения", text: $viewer.invitationDraft).textFieldStyle(.roundedBorder)
                        .controlSize(.large).onSubmit(connectInvitation).accessibilityIdentifier("connectionInvitation")
                    Button("Подключиться", action: connectInvitation).remotePrimaryButton().controlSize(.large)
                        .disabled(viewer.invitationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewer.connecting)
                }
                Text("На другом Mac откройте WAI Remote и выберите «Поделиться экраном».")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !viewer.computers.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Сохранённые").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    ForEach(viewer.computers) { computer in
                        HStack(spacing: 14) {
                            Image(systemName: "desktopcomputer").font(.system(size: 23)).foregroundStyle(accent)
                            Text(computer.name).font(.system(size: 14, weight: .medium)).lineLimit(1).help(computer.name)
                            Spacer()
                            Button("Открыть") { viewer.invitation = computer.invitation; connect() }
                                .disabled(viewer.connecting)
                            Menu {
                                Button("Переименовать…") { computerName = computer.name; editing = computer }
                                Button("Забыть этот Mac", role: .destructive) { viewer.forget(computer.id) }
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22).accessibilityLabel("Действия с компьютером «\(computer.name)»")
                        }.padding(16).remoteGlass(cornerRadius: 18)
                    }
                }
            }
        }
    }
    private var shareContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            title(host.suspended ? "Доступ приостановлен" : host.reconnecting ? "Восстанавливаем соединение" : host.pending != nil ? "Запрос подключения" : host.sharing ? "Доступ открыт" : "Поделиться экраном", subtitle: host.suspended ? "Продолжим автоматически после разблокировки Mac." : host.reconnecting ? "Соединение восстановится автоматически, когда сервер станет доступен." : host.pending != nil || host.connectedName != nil ? "" : host.sharing ? "Сохранённые устройства могут подключаться в любой момент." : "Отправьте приглашение человеку, которому хотите показать экран.")
            if (!host.sharing || !host.isLab) && (!host.screenAllowed || !host.controlAllowed) {
                VStack(alignment: .leading, spacing: 16) {
                    if !host.screenAllowed { permission("Запись экрана", detail: "Разрешите запись экрана для WAI Remote в настройках macOS.", action: host.requestScreen) }
                    if !host.controlAllowed { permission("Универсальный доступ", detail: "Включите WAI Remote в разделе «Универсальный доступ», чтобы разрешить управление.", action: host.requestControl) }
                    if host.permissionRequested && !host.screenAllowed {
                        Text("Если macOS попросила перезапустить приложение, нажмите кнопку ниже.").font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("Перезапустить и продолжить") { host.restartForPermissions() }
                    }
                }
            }
            if let pending = host.pending {
                VStack(alignment: .leading, spacing: 14) {
                    Label("\(pending.offer.name) хочет подключиться", systemImage: "person.crop.circle.badge.questionmark").font(.headline)
                    Text("Разрешайте подключение, только если вы его ожидаете.").font(.callout).foregroundStyle(.secondary)
                    Text("При управлении также доступны текст, изображения и файлы, которые вы копируете в буфер обмена.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Отклонить") { host.reject() }
                        Spacer()
                        Button("Только просмотр") { host.approve(control: false) }
                        Button("Разрешить управление") { host.approve(control: true) }.remotePrimaryButton().disabled(!host.controlAllowed && !host.isLab)
                    }
                }.padding(20).remoteGlass()
            }
            if host.accessEnabled && !host.sharing {
                Label(host.status, systemImage: "moon.zzz").foregroundStyle(.secondary)
                Button("Закрыть доступ", role: .destructive) { host.stop() }
            }
            if let notice = host.backgroundNotice {
                Text(notice).font(.callout).foregroundStyle(.orange)
            }
            if host.sharing {
                if let name = host.sharedWindowName {
                    Label(name, systemImage: "macwindow").font(.callout)
                    Text("Независимая мышь. Буфер обмена общий.").font(.caption).foregroundStyle(.secondary)
                }
                if host.independentPointer {
                    Label("Независимая мышь · весь экран", systemImage: "cursorarrow.motionlines").font(.callout)
                    Text("Ваша мышь остаётся на месте. Буфер обмена общий.").font(.caption).foregroundStyle(.secondary)
                }
                if let name = host.connectedName {
                    Label(name, systemImage: "desktopcomputer").font(.headline)
                    HStack {
                        if host.sharedWindowName == nil {
                            Button(host.localDrawing ? "Закончить рисование" : "Рисовать вместе") { host.toggleLocalDraw() }
                            Button("Очистить рисунки") { host.clearInk() }
                        }
                        Spacer()
                        Button("Отключить устройство") { host.disconnectViewer() }
                    }
                } else if host.pending == nil && !host.invite.isEmpty {
                    HStack(spacing: 14) {
                        Button(copied ? "Приглашение скопировано" : "Скопировать приглашение") {
                            host.copyInvite(); copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { copied = false }
                        }.remotePrimaryButton().controlSize(.large)
                        Text("Без ограничения по времени.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } else if host.pending == nil && !host.starting {
                    Button("Создать приглашение") { host.newInvite() }.controlSize(.large)
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Закрыть доступ", role: .destructive) { host.stop() }.controlSize(.large)
                }
                Text("Доступ сохраняется после обновлений и перезапуска. Экран заблокированного Mac не передаётся.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Button { host.start(lab: false) } label: {
                    HStack { if host.starting { ProgressView().controlSize(.small) }; Text(host.starting ? "Открываем доступ…" : "Открыть доступ к экрану") }
                }.remotePrimaryButton().controlSize(.large).disabled(host.starting || !host.screenAllowed)
                if DesktopInputTarget.isSupported {
                    Button { host.start(lab: false, independentPointer: true) } label: {
                        Label("Независимая мышь", systemImage: "cursorarrow.motionlines")
                    }.controlSize(.large)
                        .disabled(host.starting || !host.screenAllowed)
                }
                if host.status != "Доступ закрыт" { Text(host.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            if !host.peers.isEmpty {
                DisclosureGroup("Разрешённые устройства (\(host.peers.count))") {
                    Text("Разрешение действует до отзыва. Новое приглашение не требуется.").foregroundStyle(.secondary).padding(.top, 8)
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
