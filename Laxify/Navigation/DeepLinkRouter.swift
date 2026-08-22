import Foundation

@MainActor
@Observable
final class DeepLinkRouter {
    static let shared = DeepLinkRouter()

    var pendingArtistId: String?
    var pendingAlbum: MusicAlbum?
    var pendingCollection: MusicCollection?

    private init() {}

    func handle(_ url: URL) -> Bool {
        guard let link = DeepLink(url: url) else { return false }

        switch link {
        case .artist(let id):
            pendingArtistId = id
        case .album(let id):
            pendingAlbum = MusicAlbum(id: id, title: "", artistName: "", coverURL: nil, year: nil)
        case .playlist(let id):
            pendingCollection = MusicCollection(id: id, title: "", subtitle: nil, coverURL: nil)
        case .track(let id):
            Task { await playTrack(id: id) }
        }
        return true
    }

    private func playTrack(id: String) async {
        guard let song = try? await CatalogService.shared.song(id: id) else { return }
        AudioPlayerController.shared.play(song, queue: [song])
    }
}
