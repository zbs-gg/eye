import SwiftUI

struct TimelineView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Таймлайн", systemImage: "clock.arrow.circlepath")
        } description: {
            Text("История экрана, time-travel скруббер и семантический поиск появятся здесь (Фаза 2).")
        }
    }
}
