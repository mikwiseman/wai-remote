import SwiftUI

/// Owned native controls for verifying CGEvent delivery without touching a user's documents.
struct InputTestView: View {
    @State private var clicks = 0
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("WAI REMOTE / ПРОВЕРКА ВВОДА MACOS").font(.system(size: 12, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
            Text("Настоящие кнопки.\nНастоящий ввод.").font(.system(size: 36, weight: .semibold)).tracking(-1).fixedSize(horizontal: false, vertical: true)
            Text("Проверьте клик, текст и рисунки поверх экрана.").font(.system(size: 16)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 28) {
                Button("Нажать для проверки") { clicks += 1; PerformanceLog.record("test-click", ["count": clicks]) }.buttonStyle(.borderedProminent).controlSize(.large).tint(Color(red:0.23,green:0.38,blue:0.31))
                Text("Нажатий: \(clicks)").font(.system(size: 28, weight: .medium)).monospacedDigit()
            }
            TextField("Введите текст с пульта", text: $text).textFieldStyle(.roundedBorder).font(.system(size: 16)).controlSize(.large).accessibilityLabel("Тестовый текст")
            if PerformanceLog.enabled {
                TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(format: "%.3f", context.date.timeIntervalSince1970)).font(.system(size: 16, design: .monospaced))
                        GeometryReader { geometry in
                            Rectangle().fill(.black.opacity(0.08))
                            Rectangle().fill(Color(red:0.23,green:0.38,blue:0.31)).frame(width: 64)
                                .offset(x: (geometry.size.width - 64) * (sin(context.date.timeIntervalSince1970 * 2) + 1) / 2)
                        }.frame(height: 28)
                    }
                }
            }
            Spacer()
            Text("Проверка не изменяет ваши документы. После закрытия окна данные исчезнут.").font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(32).frame(minWidth:680,minHeight:580).background(Color(red:0.96,green:0.945,blue:0.918)).preferredColorScheme(.light)
    }
}
