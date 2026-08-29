import SwiftUI

/// Comments on a track: text, one level of replies, like / dislike, and
/// (soon) a photo, a short clip or a GIF. The list and composer are built;
/// posting turns on once the backend endpoints land.
struct CommentsView: View {
    let track: Song
    var onClose: () -> Void

    var store = CommentStore.shared
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private var comments: [TrackComment] { store.comments(for: track.id) }

    var body: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                if comments.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 18) {
                            ForEach(comments) { comment in
                                CommentRow(comment: comment)
                            }
                        }
                        .padding(.horizontal, LaxifyMetrics.screenPadding)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                    }
                    .scrollIndicators(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                }

                composer
            }
        }
        .task { await store.load(trackId: track.id) }
    }

    private var header: some View {
        ZStack {
            Text(L("comments.title", "Комментарии"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LaxifyPalette.textPrimary)

            HStack {
                Button(L("common.done", "Готово"), action: onClose)
                    .font(.system(size: 17))
                    .foregroundStyle(LaxifyPalette.accent)
                Spacer()
                if !comments.isEmpty {
                    Text("\(comments.count)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.textSecondary)
                }
            }
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.vertical, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(LaxifyPalette.textTertiary)
            Text(L("comments.empty", "Пока нет комментариев"))
                .font(LaxifyTypography.body)
                .foregroundStyle(LaxifyPalette.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            Button {} label: {
                Image(systemName: "photo")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textSecondary)
            }
            .buttonStyle(.plain)

            Button {} label: {
                Text("GIF")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(LaxifyPalette.textSecondary)
            }
            .buttonStyle(.plain)

            TextField(L("comments.write", "Написать комментарий…"), text: $draft, axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(1...4)
                .focused($composerFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(LaxifyPalette.surface, in: Capsule())

            Button {} label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(LaxifyPalette.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .overlay(alignment: .top) {
            Text(L("comments.soon", "Комментарии подключим совсем скоро"))
                .font(.system(size: 11))
                .foregroundStyle(LaxifyPalette.textTertiary)
                .offset(y: -4)
                .opacity(comments.isEmpty ? 1 : 0)
        }
        .background(.ultraThinMaterial)
    }
}

struct CommentRow: View {
    let comment: TrackComment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.authorName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                    Text(comment.relativeTime)
                        .font(.system(size: 12))
                        .foregroundStyle(LaxifyPalette.textTertiary)
                }

                Text(comment.text)
                    .font(.system(size: 15))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 18) {
                    Label("\(comment.likeCount)", systemImage: "hand.thumbsup")
                    Label("\(comment.dislikeCount)", systemImage: "hand.thumbsdown")
                    Text(L("comments.reply", "Ответить"))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LaxifyPalette.textSecondary)
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
    }

    private var avatar: some View {
        Group {
            if let url = comment.authorAvatarURL {
                AsyncCoverImage(url: url, cornerRadius: 18, displaySize: 72)
            } else {
                Circle().fill(LaxifyPalette.surfaceElevated)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(LaxifyPalette.textTertiary)
                    }
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
    }
}
