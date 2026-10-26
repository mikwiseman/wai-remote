import SwiftUI

/// While the Mac answers (or its owner approves), nothing else competes for attention.
struct ConnectingView: View {
    @ObservedObject var model: PhoneModel
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            HomeBackdrop()
            VStack(spacing: 0) {
                Spacer()
                ZStack {
                    if !reduceMotion {
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
                    .font(.system(size: 32, weight: .bold)).tracking(-0.5)
                    .padding(.top, 64)
                Text(model.status)
                    .font(.headline).padding(.top, 10)
                Text(model.detail)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.top, 6)
                Spacer()
                Button { model.disconnect(message: HomeView.idleStatus) } label: { Text("Отменить").frame(minWidth: 140) }
                    .glassButton().controlSize(.large)
            }
            .multilineTextAlignment(.center).padding(32)
        }
        .onAppear { pulsing = true }
    }
}
