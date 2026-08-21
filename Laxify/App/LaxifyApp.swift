import SwiftUI
import SwiftData

@main
struct LaxifyApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [FavoriteTrack.self, SearchHistoryEntry.self])
    }
}
