import SwiftUI
import SwiftData

@main
struct LaxifyApp: App {
    init() {
        AppLogger.log("app: launched")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [FavoriteTrack.self, SearchHistoryEntry.self])
    }
}
