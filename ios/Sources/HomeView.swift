import SwiftUI
import RemoteCore

/// One focus: the Macs you can open. Adding one is a single floating action.
struct HomeView: View {
    /// PhoneModel's resting status; anything else is worth a line on this screen.
    static let idleStatus = "Ваш Mac. Под рукой."
    @ObservedObject var model: PhoneModel
    @Binding var scanning: Bool
    @State private var reached = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pendingInvite: Bool {
        guard let invite = try? RemoteInvite(model.invitation), invite.secret != nil else { return false }
        return !model.computers.contains { $0.id == invite.hostID }
    }
    private var notice: String? {
        model.status == Self.idleStatus ? nil : model.status
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            HomeBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    wordmark.padding(.top, 8)
                    if model.computers.isEmpty { hero } else { computers }
                    if pendingInvite { invitation.padding(.top, 28) }
                    if let notice {
                        Label { Text(notice) } icon: { Image(systemName: "info.circle") }
                            .font(.subheadline).foregroundStyle(.secondary)
                            .padding(.top, 24).transition(.opacity)
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 140)
                .frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            actions
        }
        .animation(.smooth, value: model.computers.map(\.id))
        .animation(.smooth, value: notice)
        .onAppear {
            if reduceMotion { reached = true }
            else { withAnimation(.spring(duration: 1.1, bounce: 0.25).delay(0.15)) { reached = true } }
        }
    }

    private var wordmark: some View {
        HStack(spacing: 8) {
            BrandArrow().stroke(Brand.accent, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .frame(width: 11, height: 11)
            Text("WAI Remote").font(.subheadline.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            BrandArrow()
                .trim(from: 0, to: reached ? 1 : 0)
                .stroke(Brand.accent, style: StrokeStyle(lineWidth: 14, lineCap: .round, lineJoin: .round))
                .frame(width: 96, height: 96)
                .padding(.top, 72).padding(.bottom, 28)
                .accessibilityHidden(true)
            Text("Ваш Mac.\nПод рукой.")
                .font(.system(size: 44, weight: .bold)).tracking(-0.8).lineSpacing(-2)
            Text("Управляйте экраном, печатайте и рисуйте вместе — из любой сети.")
                .font(.title3).foregroundStyle(.secondary)
            Text("На Mac откройте WAI Remote, выберите «Поделиться экраном» и отсканируйте QR-код.")
                .font(.subheadline).foregroundStyle(.secondary).padding(.top, 12)
        }
    }

    private var computers: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ваши Mac").font(.system(size: 34, weight: .bold)).tracking(-0.5)
                .padding(.top, 40).padding(.bottom, 8)
            ForEach(model.computers) { computer in
                Button { model.invitation = computer.invitation; model.connect() } label: {
                    ComputerRow(name: computer.name)
                }
                .buttonStyle(RowPress())
                .contextMenu { Button("Забыть этот Mac", systemImage: "trash", role: .destructive) { model.forget(computer.id) } }
                .accessibilityHint("Подключиться")
            }
        }
    }

    private var invitation: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Новое приглашение").font(.headline)
                Text("Владелец Mac подтвердит подключение.").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Открыть", action: model.connect).remotePrimaryButton().tint(Brand.accent)
        }
        .padding(20)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var actions: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                Button { scanning = true } label: {
                    Label("Сканировать QR-код", systemImage: "qrcode.viewfinder")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .remotePrimaryButton().tint(Brand.accent).foregroundStyle(Brand.onAccent)
                .controlSize(.large).accessibilityIdentifier("scanInvitationQR")
                PasteButton(payloadType: String.self) { values in
                    guard let first = values.first else { return }
                    model.invitation = first.trimmingCharacters(in: .whitespacesAndNewlines); model.connect()
                }
                .labelStyle(.iconOnly).buttonBorderShape(.circle).controlSize(.large).tint(Brand.forest)
                .accessibilityIdentifier("pasteInvitation")
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 12)
        .frame(maxWidth: 560)
    }
}

private struct ComputerRow: View {
    let name: String
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "display")
                .font(.system(size: 20, weight: .medium)).foregroundStyle(Brand.mint)
                .frame(width: 48, height: 48)
                .background(Brand.forest, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(name).font(.title3.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
            Spacer(minLength: 8)
            BrandArrow().stroke(Brand.accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .frame(width: 13, height: 13).padding(.trailing, 6)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct RowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
    }
}

/// A quiet field of the icon's forest with one mint glow where the arrow points.
struct HomeBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            (scheme == .dark ? Color.black : Color(red: 0.965, green: 0.975, blue: 0.955))
            RadialGradient(colors: [Brand.mint.opacity(scheme == .dark ? 0.16 : 0.55), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 520)
            if scheme == .dark {
                LinearGradient(colors: [Brand.forest.opacity(0.55), .clear], startPoint: .top, endPoint: .center)
            }
        }
        .ignoresSafeArea()
    }
}
