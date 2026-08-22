import SwiftUI
import SwiftData

@main
struct LaxifyApp: App {
    private let container: ModelContainer

    init() {
        AppLogger.log("app: launched")

        do {
            container = try ModelContainer(
                for: FavoriteTrack.self, SearchHistoryEntry.self, DislikedTrack.self
            )
        } catch {
            fatalError("Не удалось создать локальное хранилище: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
        .modelContainer(container)
    }
}
