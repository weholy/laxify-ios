import SwiftUI

/// The bell feed: system notices (a new build in the Telegram channel, the
/// monthly stats reset) and social ones ("X liked your profile"). Built
/// against `NotificationStore`; the data arrives once the backend has a
/// `notifications` table and feed endpoint.
struct NotificationsView: View {
    var onClose: () -> Void
    var store = NotificationStore.shared

    var body: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                if store.items.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(store.items) { item in
                                NotificationRow(item: item)
                            }
                        }
                        .padding(.horizontal, LaxifyMetrics.screenPadding)
                        .padding(.top, 10)
                        .padding(.bottom, 30)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .task { await store.load() }
    }

    private var header: some View {
        ZStack {
            Text(L("notifications.title", "Уведомления"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LaxifyPalette.textPrimary)
            HStack {
                Button(action: onClose) {
                    Text(L("common.done", "Готово")).glassPill()
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.vertical, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "bell")
                .font(.system(size: 34))
                .foregroundStyle(LaxifyPalette.textTertiary)
            Text(L("notifications.empty", "Пока пусто"))
                .font(LaxifyTypography.body)
                .foregroundStyle(LaxifyPalette.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct AppNotification: Identifiable, Sendable, Hashable {
    let id: String
    let kind: Kind
    let title: String
    let body: String
    let avatarURL: URL?
    let createdAt: Date
    var isRead: Bool

    enum Kind: String, Sendable { case system, like, reply, build, monthReset }

    var icon: String {
        switch kind {
        case .system: "sparkles"
        case .like: "heart.fill"
        case .reply: "arrowshape.turn.up.left.fill"
        case .build: "paperplane.fill"
        case .monthReset: "calendar"
        }
    }
}

struct NotificationRow: View {
    let item: AppNotification

    var body: some View {
        HStack(spacing: 12) {
            leading

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .lineLimit(1)
                Text(item.body)
                    .font(.system(size: 13))
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if !item.isRead {
                Circle().fill(LaxifyPalette.accent).frame(width: 8, height: 8)
            }
        }
        .padding(12)
        .background(
            LaxifyPalette.surface,
            in: RoundedRectangle(cornerRadius: LaxifyMetrics.cardCornerRadius, style: .continuous)
        )
    }

    @ViewBuilder
    private var leading: some View {
        if let url = item.avatarURL {
            AsyncCoverImage(url: url, cornerRadius: 20, displaySize: 80)
                .frame(width: 40, height: 40)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(LaxifyPalette.accentMuted)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: item.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.accent)
                }
        }
    }
}

@Observable
@MainActor
final class NotificationStore {
    static let shared = NotificationStore()

    private(set) var items: [AppNotification] = []
    private(set) var unreadCount = 0

    private init() {}

    func load() async {
        // TODO(backend): GET /notifications
    }

    func markAllRead() async {
        // TODO(backend): POST /notifications/read
        unreadCount = 0
    }
}
