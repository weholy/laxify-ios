import SwiftUI
import SwiftData

@main
struct LaxifyApp: App {
    /// Built explicitly rather than through the `.modelContainer(for:)`
    /// convenience so the same container can be handed to the Live Activity's
    /// favourite button, which has no SwiftUI environment to read it from.
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

        FavoriteToggler.shared.configure(container: container)
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
        .modelContainer(container)
    }
}
