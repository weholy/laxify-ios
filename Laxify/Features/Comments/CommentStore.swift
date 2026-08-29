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

    init(dto: LaxifyAPI.CommentDTO, trackId: String) {
        id = dto.id
        self.trackId = trackId
        parentId = dto.parentId
        authorName = dto.author.displayName
        authorHandle = dto.author.username
        authorAvatarURL = dto.author.avatarUrl.flatMap(URL.init(string:))
        text = dto.body ?? ""
        mediaURL = dto.mediaUrl.flatMap(URL.init(string:))
        gifURL = dto.gifUrl.flatMap(URL.init(string:))
        createdAt = dto.createdAt
        likeCount = dto.likeCount
        dislikeCount = dto.dislikeCount
        myReaction = Reaction(rawValue: dto.myReaction) ?? .none
    }
}

/// Holds the comment threads per track, backed by `/tracks/{id}/comments`.
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
        isLoading = true
        defer { isLoading = false }
        guard let dtos = try? await LaxifyAPI.shared.comments(trackId: trackId) else { return }
        var flat: [TrackComment] = []
        for dto in dtos {
            flat.append(TrackComment(dto: dto, trackId: trackId))
            flat.append(contentsOf: dto.replies.map { TrackComment(dto: $0, trackId: trackId) })
        }
        threads[trackId] = flat
    }

    func post(trackId: String, text: String, parentId: String? = nil,
              mediaURL: URL? = nil, gifURL: URL? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try? await LaxifyAPI.shared.postComment(
            trackId: trackId,
            body: trimmed.isEmpty ? nil : trimmed,
            parentId: parentId,
            mediaUrl: mediaURL?.absoluteString,
            gifUrl: gifURL?.absoluteString
        )
        await load(trackId: trackId)
    }

    /// Tapping the reaction you already have clears it.
    func react(commentId: String, in trackId: String, _ tapped: TrackComment.Reaction) async {
        var next: TrackComment.Reaction = tapped

        if var list = threads[trackId], let i = list.firstIndex(where: { $0.id == commentId }) {
            var c = list[i]
            next = (c.myReaction == tapped) ? .none : tapped
            if c.myReaction == .like { c.likeCount = max(0, c.likeCount - 1) }
            if c.myReaction == .dislike { c.dislikeCount = max(0, c.dislikeCount - 1) }
            if next == .like { c.likeCount += 1 }
            if next == .dislike { c.dislikeCount += 1 }
            c.myReaction = next
            list[i] = c
            threads[trackId] = list
        }

        _ = try? await LaxifyAPI.shared.reactToComment(id: commentId, value: next.rawValue)
        await load(trackId: trackId)
    }

    func delete(commentId: String, in trackId: String) async {
        try? await LaxifyAPI.shared.deleteComment(id: commentId)
        await load(trackId: trackId)
    }
}
