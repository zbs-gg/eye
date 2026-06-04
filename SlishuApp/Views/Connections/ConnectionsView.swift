import SwiftUI

struct ConnectionsView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Подключения", systemImage: "app.connected.to.app.below.fill")
        } description: {
            Text("Obsidian, локальная LLM, файловый экспорт. Секреты в Keychain. Появятся здесь (Фаза 2).")
        }
    }
}
