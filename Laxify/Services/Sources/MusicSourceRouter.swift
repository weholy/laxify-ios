import Foundation
import SwiftUI

/// The one catalogue the screens talk to.
///
/// Two different questions are being answered here, and conflating them is
/// the mistake this is built to avoid. *Browsing* — the feed, search, the
/// genre rows — belongs to whichever source is selected right now. *A
/// particular track, artist or album* belongs to whichever source its id came
/// from, whatever is selected now: a queue outlives a switch, a favourite
/// saved last month has to keep opening, and the player must not go asking
/// SoundCloud about a Yandex id because someone tapped a logo mid-song.
struct MusicSourceRouter: MusicService {
    static let shared = MusicSourceRouter()

    /// Where browsing goes.
    private var browsing: any MusicService { service(for: SelectedSource.current) }

    private func service(for source: MusicSource) -> any MusicService {
        switch source {
        case .soundcloud: CatalogService.shared
        case .yandex: YandexRoutedService.shared
        case .ytmusic: YTMusicService.shared
        }
    }

    /// Where a question about one thing goes.
    private func owner(of identifier: String) -> any MusicService {
        service(for: MusicSource.of(identifier))
    }

    // MARK: - Browsing

    func homeContent() async throws -> HomeContent {
        try await browsing.homeContent()
    }

    func search(query: String) async throws -> SearchResults {
        try await browsing.search(query: query)
    }

    func popularTracks() async throws -> [Song] {
        try await browsing.popularTracks()
    }

    func categories() async throws -> [MusicCategory] {
        try await browsing.categories()
    }

    func categoryTracks(id: String, title: String, page: Int) async throws -> [Song] {
        try await browsing.categoryTracks(id: id, title: title, page: page)
    }

    func suggestions(for query: String) async throws -> [String] {
        try await browsing.suggestions(for: query)
    }

    func categoryCoverURL(id: String) async -> URL? {
        await browsing.categoryCoverURL(id: id)
    }

    // MARK: - One particular thing

    func artistDetail(artistId: String) async throws -> ArtistDetail {
        try await owner(of: artistId).artistDetail(artistId: artistId)
    }

    func artistTracks(artistId: String, page: Int) async throws -> [Song] {
        try await owner(of: artistId).artistTracks(artistId: artistId, page: page)
    }

    func albumDetail(albumId: String) async throws -> (album: MusicAlbum, songs: [Song]) {
        try await owner(of: albumId).albumDetail(albumId: albumId)
    }

    func playlistTracks(collectionId: String) async throws -> (title: String, songs: [Song]) {
        // The named rows on the home screen — "wave", "charts", "for-you" —
        // are not ids from any source; they mean "whatever the selected
        // source calls this". Anything carrying a source prefix is a real
        // collection and belongs to whoever issued it.
        if collectionId.contains(":") {
            return try await owner(of: collectionId).playlistTracks(collectionId: collectionId)
        }
        return try await browsing.playlistTracks(collectionId: collectionId)
    }

    func song(id: String) async throws -> Song {
        try await owner(of: id).song(id: id)
    }

    func streamURL(for songId: String) async throws -> URL {
        try await owner(of: songId).streamURL(for: songId)
    }
}

/// The chosen source, for SwiftUI.
///
/// A thin observable mirror of `SelectedSource`, which is where the value
/// actually lives — screens need to redraw when it changes, services need to
/// read it off the main actor, and neither can have the other's storage.
@MainActor
@Observable
final class SourceStore {
    static let shared = SourceStore()

    private(set) var selected: MusicSource

    private init() {
        selected = SelectedSource.current
    }

    /// Switches source.
    ///
    /// Nothing is thrown away: the caches are keyed by source, so this
    /// immediately shows whatever that source had last time and refreshes
    /// behind it. Playback is left exactly as it is — a track already
    /// sounding belongs to the source it came from, and stopping the music
    /// because someone tapped a logo would be its own small outrage.
    func select(_ source: MusicSource) {
        guard source != selected else { return }

        SelectedSource.set(source)
        selected = source

        RemoteLog.shared.info(
            "источник переключён",
            category: "source",
            context: ["на": source.rawValue]
        )
    }
}
