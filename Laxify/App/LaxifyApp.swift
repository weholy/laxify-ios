import SwiftUI
import SwiftData

@main
struct LaxifyApp: App {
    private let container: ModelContainer

    init() {
        AppLogger.log("app: launched")
        CrashReporter.install()
        CrashReporter.breadcrumb("app launched")

        // Before the route below is chosen, so a VPN switched on or off while
        // the app is open is noticed rather than discovered by a failure.
        Task { @MainActor in NetworkMonitor.shared.start() }

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

        container = Self.makeContainer()
    }

    /// The on-device store, whatever state it is found in.
    ///
    /// This used to stop the app dead when the store would not open. The store
    /// is only a local copy — everything that matters is on the account and
    /// comes back down on sign-in — but a crash on launch does not come back:
    /// a store left unreadable by an interrupted write or a model change meant
    /// the app crashed on every launch until it was deleted and reinstalled.
    /// So an unreadable store is set aside and a fresh one made, and if even
    /// that fails the app runs on memory for the session.
    private static func makeContainer() -> ModelContainer {
        let models: [any PersistentModel.Type] = [
            FavoriteTrack.self, SearchHistoryEntry.self, DislikedTrack.self,
            PlayRecord.self, DownloadedTrack.self
        ]
        let schema = Schema(models)

        do {
            return try ModelContainer(for: schema)
        } catch {
            AppLogger.log("app: локальное хранилище не открылось — \(error)")
            CrashReporter.breadcrumb("store failed to open: \(error)")
        }

        // Set the unreadable files aside and start clean.
        let configuration = ModelConfiguration(schema: schema)
        let storeURL = configuration.url
        for suffix in ["", "-shm", "-wal"] {
            let file = URL(fileURLWithPath: storeURL.path + suffix)
            try? FileManager.default.removeItem(at: file)
        }

        if let rebuilt = try? ModelContainer(for: schema, configurations: configuration) {
            return rebuilt
        }

        let inMemory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        // Memory cannot fail for the reasons disk can; if it somehow does,
        // there is genuinely nothing to run on.
        return try! ModelContainer(for: schema, configurations: inMemory)
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
