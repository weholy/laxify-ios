import SwiftUI
import PhotosUI

/// Comments on a track, in the X / Telegram mould: an avatar, a name line,
/// the text, an optional photo or GIF, then a quiet action row. Replies sit
/// one level deep under their parent with a thin connector.
///
/// The list and composer are complete; `CommentStore` is a stub until the
/// `/tracks/{id}/comments` endpoints exist.
struct CommentsView: View {
    let track: Song
    var onClose: () -> Void

    var store = CommentStore.shared

    @State private var draft = ""
    @State private var replyingTo: TrackComment?
    @State private var photoItem: PhotosPickerItem?
    @FocusState private var composerFocused: Bool

    private var all: [TrackComment] { store.comments(for: track.id) }
    private var topLevel: [TrackComment] {
        all.filter { $0.parentId == nil }.sorted { $0.createdAt > $1.createdAt }
    }
    private func replies(of id: String) -> [TrackComment] {
        all.filter { $0.parentId == id }.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().overlay(LaxifyPalette.separator)

                if topLevel.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(topLevel) { comment in
                                thread(comment)
                            }
                        }
                        .padding(.bottom, 24)
                    }
                    .scrollIndicators(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                }

                composer
            }
        }
        .task { await store.load(trackId: track.id) }
        .onChange(of: photoItem) { _, _ in /* upload wired with the backend */ }
    }

    // MARK: - Chrome

    private var header: some View {
        ZStack {
            VStack(spacing: 1) {
                Text(L("comments.title", "Комментарии"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                Text(track.title)
                    .font(.system(size: 12))
                    .foregroundStyle(LaxifyPalette.textTertiary)
                    .lineLimit(1)
            }

            HStack {
                Button(L("common.done", "Готово"), action: onClose)
                    .font(.system(size: 17))
                    .foregroundStyle(LaxifyPalette.accent)
                Spacer()
                if !topLevel.isEmpty {
                    Text("\(all.count)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.textSecondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(LaxifyPalette.textTertiary)
            Text(L("comments.empty", "Пока нет комментариев"))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(LaxifyPalette.textSecondary)
            Text(L("comments.beFirst", "Будьте первым"))
                .font(.system(size: 13))
                .foregroundStyle(LaxifyPalette.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Thread

    @ViewBuilder
    private func thread(_ comment: TrackComment) -> some View {
        let kids = replies(comment.id)

        VStack(alignment: .leading, spacing: 0) {
            CommentCell(comment: comment, isReply: false) { onReply(comment) } onLike: {
                Task { await store.react(commentId: comment.id, in: track.id, .like) }
            } onDislike: {
                Task { await store.react(commentId: comment.id, in: track.id, .dislike) }
            }

            if !kids.isEmpty {
                HStack(spacing: 0) {
                    // Telegram-style connector for the reply group.
                    Rectangle()
                        .fill(LaxifyPalette.separator)
                        .frame(width: 2)
                        .padding(.leading, 30)
                        .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(kids) { kid in
                            CommentCell(comment: kid, isReply: true) { onReply(comment) } onLike: {
                                Task { await store.react(commentId: kid.id, in: track.id, .like) }
                            } onDislike: {
                                Task { await store.react(commentId: kid.id, in: track.id, .dislike) }
                            }
                        }
                    }
                }
            }

            Divider().overlay(LaxifyPalette.separator.opacity(0.6))
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
    }

    private func onReply(_ comment: TrackComment) {
        replyingTo = comment
        composerFocused = true
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 0) {
            if let replyingTo {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text("\(L("comments.replyingTo", "Ответ")) \(replyingTo.authorName)")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        self.replyingTo = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(LaxifyPalette.textSecondary)
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                .padding(.vertical, 8)
            }

            HStack(alignment: .bottom, spacing: 10) {
                PhotosPicker(selection: $photoItem, matching: .any(of: [.images, .videos])) {
                    Image(systemName: "photo")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.textSecondary)
                        .frame(height: 38)
                }

                Button {} label: {
                    Text("GIF")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(LaxifyPalette.textSecondary)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(LaxifyPalette.textSecondary, lineWidth: 1.4)
                        )
                        .frame(height: 38)
                }
                .buttonStyle(.plain)

                TextField(L("comments.write", "Написать комментарий…"), text: $draft, axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(LaxifyPalette.surface, in: Capsule())

                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(LaxifyPalette.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isDraftEmpty)
                .opacity(isDraftEmpty ? 0.4 : 1)
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().overlay(LaxifyPalette.separator) }
    }

    private var isDraftEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let parent = replyingTo?.id
        draft = ""
        replyingTo = nil
        composerFocused = false
        Task { await store.post(trackId: track.id, text: text, parentId: parent) }
    }
}

// MARK: - Cell

struct CommentCell: View {
    let comment: TrackComment
    let isReply: Bool
    var onReply: () -> Void
    var onLike: () -> Void
    var onDislike: () -> Void

    private var avatarSize: CGFloat { isReply ? 30 : 38 }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(comment.authorName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                    if let handle = comment.authorHandle {
                        Text("@\(handle)")
                            .font(.system(size: 13))
                            .foregroundStyle(LaxifyPalette.textTertiary)
                            .lineLimit(1)
                    }
                    Text("· \(comment.relativeTime)")
                        .font(.system(size: 13))
                        .foregroundStyle(LaxifyPalette.textTertiary)
                    Spacer(minLength: 0)
                }

                if !comment.text.isEmpty {
                    Text(comment.text)
                        .font(.system(size: 15))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                media

                actionRow
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 12)
    }

    private var avatar: some View {
        Group {
            if let url = comment.authorAvatarURL {
                AsyncCoverImage(url: url, cornerRadius: avatarSize / 2, displaySize: avatarSize * 2)
            } else {
                Circle().fill(LaxifyPalette.surfaceElevated)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: avatarSize * 0.42))
                            .foregroundStyle(LaxifyPalette.textTertiary)
                    }
            }
        }
        .frame(width: avatarSize, height: avatarSize)
        .clipShape(Circle())
    }

    @ViewBuilder
    private var media: some View {
        if let url = comment.gifURL ?? comment.mediaURL {
            AsyncCoverImage(url: url, cornerRadius: 12, displaySize: 480)
                .frame(maxWidth: 220, maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    if comment.gifURL != nil {
                        Text("GIF")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
                            .padding(6)
                    }
                }
                .padding(.top, 2)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 20) {
            Button(action: onReply) {
                Label(L("comments.reply", "Ответить"), systemImage: "bubble.right")
                    .labelStyle(.titleAndIcon)
            }

            Button(action: onLike) {
                HStack(spacing: 4) {
                    Image(systemName: comment.myReaction == .like ? "heart.fill" : "heart")
                        .foregroundStyle(comment.myReaction == .like ? .red : LaxifyPalette.textSecondary)
                    if comment.likeCount > 0 { Text("\(comment.likeCount)").monospacedDigit() }
                }
            }

            Button(action: onDislike) {
                HStack(spacing: 4) {
                    Image(systemName: comment.myReaction == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    if comment.dislikeCount > 0 { Text("\(comment.dislikeCount)").monospacedDigit() }
                }
            }

            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(LaxifyPalette.textSecondary)
        .buttonStyle(.plain)
    }
}
