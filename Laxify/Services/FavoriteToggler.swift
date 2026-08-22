import Foundation
import SwiftData

/// Toggles the current track's favourite state from outside the view layer.
///
/// The Live Activity's button has no SwiftUI environment to read a
/// `modelContext` from, so the model container is handed to this object at
/// launch and it owns the write.
@MainActor
final class FavoriteToggler {
    static let shared = FavoriteToggler()

    private var container: ModelContainer?

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
    }

    var isCurrentFavorite: Bool {
        guard let container, let song = AudioPlayerController.shared.currentSong else {
            return false
        }
        let context = ModelContext(container)
        let trackId = song.id
        let descriptor = FetchDescriptor<FavoriteTrack>(
            predicate: #Predicate { $0.id == trackId }
        )
        return ((try? context.fetch(descriptor)) ?? []).isEmpty == false
    }

    func toggleCurrent() {
        guard let container, let song = AudioPlayerController.shared.currentSong else { return }

        let context = ModelContext(container)
        let trackId = song.id
        let descriptor = FetchDescriptor<FavoriteTrack>(
            predicate: #Predicate { $0.id == trackId }
        )
        let existing = (try? context.fetch(descriptor)) ?? []

        if let found = existing.first {
            context.delete(found)
            SyncService.shared.favoriteRemoved(trackId: trackId)
        } else {
            context.insert(FavoriteTrack(song: song))
            SyncService.shared.favoriteAdded(song)
        }

        try? context.save()
        NowPlayingActivityController.shared.refresh()
    }
}
