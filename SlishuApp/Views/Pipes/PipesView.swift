import SwiftUI

struct PipesView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Плагины", systemImage: "powerplug")
        } description: {
            Text("Локальные scheduled-агенты (саммари дня → Obsidian) появятся здесь. Реальный backend, не заглушки.")
        }
    }
}
