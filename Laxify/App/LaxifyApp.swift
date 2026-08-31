import SwiftUI
import SwiftData

@main
struct LaxifyApp: App {
    private let container: ModelContainer

    init() {
        AppLogger.log("app: launched")
        CrashReporter.install()
        CrashReporter.breadcrumb("app launched")

        // Find a way to the server before anything asks for one. On a network
        // that filters some of them this is the difference between an app
        // that works and one that looks broken.
        Task {
            await LaxifyAPI.shared.prepare()

            // Artwork for the sign-in wall, fetched at launch so it is
            // already in the cache by the time that screen needs it. Costs
            // nothing when someone is already signed in.
            if await !LaxifyAPI.shared.isSignedIn {
                await Self.warmSignInArtwork()
            }
        }

        do {
            container = try ModelContainer(
                for: FavoriteTrack.self, SearchHistoryEntry.self, DislikedTrack.self,
                PlayRecord.self, DownloadedTrack.self
            )
        } catch {
            fatalError("Не удалось создать локальное хранилище: \(error)")
        }
    }

    /// Loads and caches the covers the sign-in wall is built from.
    private static func warmSignInArtwork() async {
        guard let showcase = try? await LaxifyAPI.shared.showcase(limit: 60) else { return }

        let songs = showcase.map(\.song).filter { $0.coverURL != nil }
        guard songs.count >= 6 else { return }

        CoverArtCache.save(songs)
        AsyncCoverImage.prefetchCovers(for: Array(songs.prefix(24)), width: 110)
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                // Laxify is a dark app and only a dark app. Following the
                // system meant a light phone got a half-drawn version of
                // screens that were composed against black.
                .preferredColorScheme(.dark)
        }
        .modelContainer(container)
    }
}
