import SwiftUI
import UIKit

/// The app icon's two colors: a deep forest field and a mint arrow.
enum Brand {
    static let forest = Color(red: 0.133, green: 0.208, blue: 0.180)
    static let mint = Color(red: 0.875, green: 0.949, blue: 0.784)
    /// Mint reads on dark surfaces; on light ones the same hue needs depth.
    static let accent = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.875, green: 0.949, blue: 0.784, alpha: 1)
        : UIColor(red: 0.137, green: 0.427, blue: 0.318, alpha: 1) })
    /// Text on an accent fill.
    static let onAccent = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.133, green: 0.208, blue: 0.180, alpha: 1) : .white })
}

/// The icon's arrow, drawn diagonal first so a trim reads as a reach up and to the right.
struct BrandArrow: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        var path = Path()
        path.move(to: p(0, 1)); path.addLine(to: p(1, 0))
        path.move(to: p(0.08, 0)); path.addLine(to: p(1, 0)); path.addLine(to: p(1, 0.92))
        return path
    }
}

/// Liquid Glass from iOS 26, a material before it. Glass belongs to controls only.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        if #available(iOS 26, *) { GlassEffectContainer(spacing: spacing) { content } }
        else { content }
    }
}

extension View {
    @ViewBuilder func glass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) { glassEffect(interactive ? .regular.interactive() : .regular, in: shape) }
        else { background(.regularMaterial, in: shape) }
    }
    @ViewBuilder func glassID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26, *) { glassEffectID(id, in: namespace) } else { self }
    }
    @ViewBuilder func glassButton() -> some View {
        if #available(iOS 26, *) { buttonStyle(.glass) } else { buttonStyle(.bordered) }
    }
}
