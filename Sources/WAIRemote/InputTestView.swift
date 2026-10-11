import SwiftUI

/// Owned native controls for verifying CGEvent delivery without touching a user's documents.
struct InputTestView: View {
    @State private var clicks = 0
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("WAI REMOTE / ПРОВЕРКА ВВОДА MACOS").font(.system(size: 12, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
            Text("Настоящие кнопки.\nНастоящий ввод.").font(.system(size: 44, weight: .semibold)).tracking(-1.5)
            Text("Это отдельное тестовое окно. Здесь можно проверить клик, текст и рисунки поверх экрана.").font(.system(size: 16)).foregroundStyle(.secondary)
            HStack(spacing: 28) {
                Button("Нажать для проверки") { clicks += 1 }.buttonStyle(.borderedProminent).controlSize(.large).tint(Color(red:0.23,green:0.38,blue:0.31))
                Text("Нажатий: \(clicks)").font(.system(size: 28, weight: .medium)).monospacedDigit()
            }
            TextField("Введите текст с пульта", text: $text).textFieldStyle(.roundedBorder).font(.system(size: 16)).controlSize(.large).accessibilityLabel("Тестовый текст")
            Spacer()
            Text("Проверка не изменяет ваши документы. После закрытия окна данные исчезнут.").font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(44).frame(minWidth:760,minHeight:500).background(Color(red:0.96,green:0.945,blue:0.918)).preferredColorScheme(.light)
    }
}
