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
        .task {
            await store.load()
            await store.markAllRead()
        }
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
    /// An image an operator attached to this one notice — a broadcast or a
    /// direct notify, never a social one. Takes priority over everything.
    var iconURL: URL?
    let createdAt: Date
    var isRead: Bool

    enum Kind: String, Sendable {
        case system, like, reply, build
        case monthReset = "month_reset"
    }

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

    /// Two lines in the list, everything on a tap. A notice worth sending is
    /// often longer than a row, and truncating it with no way to read the
    /// rest makes the row worse than useless.
    @State private var isExpanded = false

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.28)) { isExpanded.toggle() }
        } label: {
            HStack(alignment: isExpanded ? .top : .center, spacing: 12) {
                leading

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                        .lineLimit(isExpanded ? nil : 1)
                        .multilineTextAlignment(.leading)

                    if !item.body.isEmpty {
                        Text(item.body)
                            .font(.system(size: 13))
                            .foregroundStyle(LaxifyPalette.textSecondary)
                            .lineLimit(isExpanded ? nil : 2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A picture, always. A custom icon an operator attached wins; a social
    /// notice shows who did it; a plain system notice shows the app's own
    /// mark — never the bare sparkle glyph that used to stand in for it,
    /// which read as a placeholder nobody had gotten around to replacing.
    @ViewBuilder
    private var leading: some View {
        if let url = item.iconURL ?? item.avatarURL {
            AsyncCoverImage(url: url, cornerRadius: 20, displaySize: 80)
                .frame(width: 40, height: 40)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(LaxifyPalette.accentMuted)
                .frame(width: 40, height: 40)
                .overlay {
                    Image("LaxifyLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                }
                .clipShape(Circle())
        }
    }
}

extension AppNotification {
    init(dto: LaxifyAPI.NotificationDTO) {
        id = dto.id
        kind = Kind(rawValue: dto.kind) ?? .system
        title = dto.title
        body = dto.body
        avatarURL = dto.actorAvatarUrl.flatMap(URL.init(string:))
        iconURL = dto.iconUrl.flatMap(URL.init(string:))
        createdAt = dto.createdAt
        isRead = dto.isRead
    }
}

@Observable
@MainActor
final class NotificationStore {
    static let shared = NotificationStore()

    private(set) var items: [AppNotification] = []
    private(set) var unreadCount = 0

    private init() {}

    /// Clears the previous account's notifications — and, more visibly, its
    /// unread badge, which otherwise sat on the next person's tab bar.
    func reset() {
        items = []
        unreadCount = 0
    }

    func load() async {
        async let list = LaxifyAPI.shared.notifications()
        async let count = LaxifyAPI.shared.notificationsUnreadCount()
        if let dtos = try? await list {
            items = dtos.map(AppNotification.init(dto:))
        }
        if let c = try? await count {
            unreadCount = c
        }
    }

    func markAllRead() async {
        unreadCount = 0
        try? await LaxifyAPI.shared.markNotificationsRead()
        for i in items.indices { items[i].isRead = true }
    }
}
