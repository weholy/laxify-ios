import SwiftUI
import SwiftData

@main
struct LaxifyApp: App {
    private let container: ModelContainer

    init() {
        AppLogger.log("app: launched")
        CrashReporter.install()
        CrashReporter.breadcrumb("app launched")

        do {
            container = try ModelContainer(
                for: FavoriteTrack.self, SearchHistoryEntry.self, DislikedTrack.self
            )
        } catch {
            fatalError("Не удалось создать локальное хранилище: \(error)")
        }
    }

    @State private var appearance = AppearanceSettings.shared

    var body: some Scene {
        WindowGroup {
            AppRootView()
                // nil follows the system, which is the default and what most
                // people leave it on.
                .preferredColorScheme(appearance.theme.colorScheme)
        }
        .modelContainer(container)
    }
}
