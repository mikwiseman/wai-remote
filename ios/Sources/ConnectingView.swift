import SwiftUI

/// While the Mac answers (or its owner approves), nothing else competes for attention.
struct ConnectingView: View {
    @ObservedObject var model: PhoneModel
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            HomeBackdrop()
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: 24)
                        ZStack {
                            if !reduceMotion && !model.connectionBusy {
                                ForEach(0..<3, id: \.self) { ring in
                                    Circle().stroke(Brand.accent.opacity(0.4), lineWidth: 1.5)
                                        .scaleEffect(pulsing ? 2.6 : 0.9).opacity(pulsing ? 0 : 0.9)
                                        .animation(.easeOut(duration: 2.7).repeatForever(autoreverses: false).delay(Double(ring) * 0.9), value: pulsing)
                                }
                            }
                            Image(systemName: "display")
                                .font(.system(size: 30, weight: .medium)).foregroundStyle(Brand.mint)
                                .frame(width: 84, height: 84)
                                .background(Brand.forest, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                        }
                        .frame(width: 84, height: 84).accessibilityHidden(true)
                        Text(model.computerName)
                            .font(.largeTitle.bold()).tracking(-0.5)
                            .padding(.top, model.connectionBusy ? 32 : 64)
                        Text(model.status)
                            .font(.headline).padding(.top, 10)
                        Text(model.detail)
                            .font(.subheadline).foregroundStyle(.secondary)
                            .padding(.top, 6)
                        Spacer(minLength: 32)
                        if model.connectionBusy {
                            Button {
                                if model.canSwitchConnection { model.switchConnection() }
                                else { model.retryConnection() }
                            } label: {
                                Text(model.canSwitchConnection ? "Подключиться здесь" : "Повторить")
                                    .font(.headline).frame(maxWidth: .infinity, minHeight: 32)
                            }
                            .remotePrimaryButton().tint(Brand.accent).foregroundStyle(Brand.onAccent)
                            .controlSize(.large).accessibilityIdentifier("retryBusyConnection")
                            .padding(.bottom, 12)
                        }
                        Button { model.disconnect(message: HomeView.idleStatus) } label: {
                            Text("Отменить").frame(minWidth: 140, minHeight: 32)
                        }
                        .glassButton().controlSize(.large)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480, minHeight: max(0, geometry.size.height - 64))
                    .padding(32).frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .onAppear { pulsing = !model.connectionBusy }
        .onChange(of: model.connectionBusy) { _, busy in pulsing = !busy }
    }
}
