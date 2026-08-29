import Foundation

/// A comment on a track. `parentId` is set for a reply (one level only).
struct TrackComment: Identifiable, Sendable, Hashable {
    let id: String
    let trackId: String
    let parentId: String?
    let authorName: String
    let authorHandle: String?
    let authorAvatarURL: URL?
    let text: String
    let mediaURL: URL?
    let gifURL: URL?
    let createdAt: Date
    var likeCount: Int
    var dislikeCount: Int
    var myReaction: Reaction

    enum Reaction: String, Sendable { case none, like, dislike }

    var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: createdAt, relativeTo: Date())
    }
}

/// Holds the comment threads per track.
///
/// The screen is built against this; the methods are stubs until the
/// `/tracks/{id}/comments` endpoints exist, at which point only this file
/// changes — `CommentsView` already reads and writes through here.
@Observable
@MainActor
final class CommentStore {
    static let shared = CommentStore()

    private var threads: [String: [TrackComment]] = [:]
    private(set) var isLoading = false

    private init() {}

    func comments(for trackId: String) -> [TrackComment] {
        threads[trackId] ?? []
    }

    func load(trackId: String) async {
        // TODO(backend): GET /tracks/{trackId}/comments — paginated, threaded.
    }

    func post(trackId: String, text: String, parentId: String? = nil,
              mediaURL: URL? = nil, gifURL: URL? = nil) async {
        // TODO(backend): POST /tracks/{trackId}/comments
    }

    func react(commentId: String, in trackId: String, _ reaction: TrackComment.Reaction) async {
        // TODO(backend): POST /comments/{commentId}/reaction
    }
}
