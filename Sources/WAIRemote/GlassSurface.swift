import SwiftUI

extension View {
    func remoteGlass(cornerRadius: CGFloat = 24) -> some View {
        modifier(RemoteGlass(cornerRadius: cornerRadius))
    }
    @ViewBuilder func remotePrimaryButton() -> some View {
        if #available(macOS 26, iOS 26, *) { buttonStyle(.glassProminent) }
        else { buttonStyle(.borderedProminent) }
    }
}

private struct RemoteGlass: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(.background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else if #available(macOS 26, iOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

struct RemoteBackdrop: View {
    var body: some View {
        Rectangle().fill(.background)
            .overlay(alignment: .topTrailing) {
                LinearGradient(colors: [.accentColor.opacity(0.09), .clear], startPoint: .topTrailing, endPoint: .bottomLeading)
            }.ignoresSafeArea()
    }
}
