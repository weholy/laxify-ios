import SwiftUI
import SwiftData

@main
struct LaxifyApp: App {
    init() {
        AppLogger.log("app: launched")
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
        .modelContainer(for: [FavoriteTrack.self, SearchHistoryEntry.self, DislikedTrack.self])
    }
}
