import SwiftUI

/// The operator's panel — who has signed up, and what can be done about them.
///
/// Reloads whenever it is opened, whenever a tab changes, and after every
/// action, because a list of people that is stale is worse than no list: the
/// ban you just applied has to be visible or you will apply it twice.
struct AdminPanelView: View {
    var onBack: () -> Void

    private enum Tab: String, CaseIterable, Identifiable {
        case users
        case overview

        var id: String { rawValue }

        @MainActor
        var title: String {
            switch self {
            case .users: L("admin.users", "Пользователи")
            case .overview: L("admin.overview", "Обзор")
            }
        }
    }

    @State private var tab: Tab = .users
    @State private var users: [LaxifyAPI.AdminUserDTO] = []
    @State private var overview: LaxifyAPI.AdminOverviewDTO?
    @State private var query = ""
    @State private var isLoading = false
    @State private var failure: String?
    @State private var selected: LaxifyAPI.AdminUserDTO?

    var body: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                SettingsHeader(title: L("settings.admin", "VIP-панель"), onBack: onBack)

                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { entry in
                        Text(entry.title).tag(entry)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                .padding(.bottom, 12)

                content
            }
        }
        .task(id: tab) { await reload() }
        .sheet(item: $selected) { user in
            AdminUserSheet(user: user) { await reload() } onClose: { selected = nil }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .users: userList
        case .overview: overviewList
        }
    }

    // MARK: - Users

    private var userList: some View {
        ScrollView {
            VStack(spacing: 10) {
                searchField

                if let failure {
                    notice(failure)
                }

                if isLoading && users.isEmpty {
                    ProgressView().padding(.top, 40)
                }

                ForEach(users) { user in
                    Button { selected = user } label: { row(user) }
                        .buttonStyle(.plain)
                }

                if !isLoading && users.isEmpty && failure == nil {
                    notice(L("admin.empty", "Никого не нашлось"))
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.bottom, 120)
        }
        .refreshable { await reload() }
        .scrollDismissesKeyboard(.interactively)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LaxifyPalette.textTertiary)

            TextField(L("admin.search", "Имя, ник или почта"), text: $query)
                .font(.system(size: 15))
                .foregroundStyle(LaxifyPalette.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { Task { await reload() } }

            if !query.isEmpty {
                Button {
                    query = ""
                    Task { await reload() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(LaxifyPalette.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            LaxifyPalette.surface,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private func row(_ user: LaxifyAPI.AdminUserDTO) -> some View {
        HStack(spacing: 12) {
            avatar(user)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(user.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                        .lineLimit(1)

                    if user.isAdmin {
                        Text("VIP")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color(hex: 0xFFD60A), in: Capsule())
                    }

                    if user.isBanned {
                        Image(systemName: "nosign")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.red)
                    }
                }

                Text("@\(user.username)")
                    .font(.system(size: 13))
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .lineLimit(1)

                Text(user.email ?? "—")
                    .font(.system(size: 12))
                    .foregroundStyle(LaxifyPalette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.dayFormatter.string(from: user.createdAt))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textSecondary)
                Text(Self.timeFormatter.string(from: user.createdAt))
                    .font(.system(size: 11))
                    .foregroundStyle(LaxifyPalette.textTertiary)
            }
        }
        .padding(12)
        .background(
            LaxifyPalette.surface,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func avatar(_ user: LaxifyAPI.AdminUserDTO) -> some View {
        Group {
            if let url = user.avatarURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Circle().fill(LaxifyPalette.surfaceElevated)
                    }
                }
            } else {
                Circle()
                    .fill(LaxifyPalette.surfaceElevated)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(LaxifyPalette.textTertiary)
                    }
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(Circle())
    }

    // MARK: - Overview

    @ViewBuilder
    private var overviewList: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let failure {
                    notice(failure)
                }

                if let overview {
                    stat(L("admin.usersTotal", "Всего аккаунтов"), "\(overview.usersTotal)")
                    stat(L("admin.usersActive", "Активны за неделю"), "\(overview.usersActive7d)")
                    stat(L("admin.plays24h", "Прослушиваний за сутки"), "\(overview.plays24h)")
                    stat(L("admin.playlists", "Плейлистов"), "\(overview.playlistsTotal)")
                    stat(L("admin.favorites", "В избранном"), "\(overview.favoritesTotal)")
                } else if isLoading {
                    ProgressView().padding(.top, 40)
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.bottom, 120)
        }
        .refreshable { await reload() }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LaxifyPalette.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(LaxifyPalette.textPrimary)
        }
        .padding(16)
        .background(
            LaxifyPalette.surface,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(LaxifyTypography.footnote)
            .foregroundStyle(LaxifyPalette.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
    }

    // MARK: - Loading

    private func reload() async {
        isLoading = true
        failure = nil
        defer { isLoading = false }

        do {
            switch tab {
            case .users:
                users = try await LaxifyAPI.shared.adminUsers(query: query)
            case .overview:
                overview = try await LaxifyAPI.shared.adminOverview()
            }
        } catch APIError.server(_, let detail) {
            failure = detail
        } catch {
            failure = L("admin.failed", "Сервер не ответил. Потяните вниз, чтобы повторить")
        }
    }

    /// The operator's own clock — a registration time is only useful next to
    /// the day you are having.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("ddMMyy")
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("HHmm")
        return formatter
    }()
}

/// One account, opened: everything known about them, and the two things that
/// can be done to them.
private struct AdminUserSheet: View {
    let user: LaxifyAPI.AdminUserDTO
    var onChanged: () async -> Void
    var onClose: () -> Void

    @State private var noticeTitle = ""
    @State private var noticeBody = ""
    @State private var isBusy = false
    @State private var result: String?
    @State private var isBanned: Bool

    init(
        user: LaxifyAPI.AdminUserDTO,
        onChanged: @escaping () async -> Void,
        onClose: @escaping () -> Void
    ) {
        self.user = user
        self.onChanged = onChanged
        self.onClose = onClose
        _isBanned = State(initialValue: user.isBanned)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    facts
                    notifier
                    banButton

                    if let result {
                        Text(result)
                            .font(LaxifyTypography.footnote)
                            .foregroundStyle(LaxifyPalette.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                .padding(.vertical, 16)
            }
            .background(LaxifyPalette.background.ignoresSafeArea())
            .navigationTitle(user.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.close", "Закрыть"), action: onClose)
                }
            }
        }
    }

    private var facts: some View {
        VStack(spacing: 0) {
            fact(L("admin.handle", "Юзернейм"), "@\(user.username)")
            Divider().overlay(LaxifyPalette.separator)
            fact(L("settings.email", "Почта"), user.email ?? "—")
            Divider().overlay(LaxifyPalette.separator)
            fact(L("admin.registered", "Регистрация"), Self.full.string(from: user.createdAt))
            if let seen = user.lastSeenAt {
                Divider().overlay(LaxifyPalette.separator)
                fact(L("admin.lastSeen", "Был в сети"), Self.full.string(from: seen))
            }
        }
        .background(
            LaxifyPalette.surface,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(LaxifyPalette.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LaxifyPalette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(14)
    }

    private var notifier: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("admin.notify", "Отправить уведомление"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LaxifyPalette.textPrimary)

            TextField(L("admin.notify.title", "Заголовок"), text: $noticeTitle)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    LaxifyPalette.surfaceElevated,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )

            TextField(L("admin.notify.body", "Текст"), text: $noticeBody, axis: .vertical)
                .lineLimit(3...8)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    LaxifyPalette.surfaceElevated,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )

            Button {
                send()
            } label: {
                HStack(spacing: 8) {
                    if isBusy { ProgressView().tint(.white) }
                    Text(L("admin.notify.send", "Отправить"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .glassEffect(.regular.tint(LaxifyPalette.accent).interactive(), in: .capsule)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(noticeTitle.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
            .opacity(noticeTitle.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1)
        }
        .padding(16)
        .background(
            LaxifyPalette.surface,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    @ViewBuilder
    private var banButton: some View {
        if user.isAdmin {
            Text(L("admin.cannotBan", "Администратора заблокировать нельзя"))
                .font(LaxifyTypography.footnote)
                .foregroundStyle(LaxifyPalette.textTertiary)
        } else {
            Button {
                toggleBan()
            } label: {
                Text(isBanned
                     ? L("admin.unban", "Разблокировать")
                     : L("admin.ban", "Заблокировать"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isBanned ? LaxifyPalette.accent : .red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .glassEffect(
                        .regular.tint((isBanned ? LaxifyPalette.accent : .red).opacity(0.12)).interactive(),
                        in: .capsule
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
    }

    private func send() {
        let title = noticeTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }

        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                try await LaxifyAPI.shared.adminNotify(
                    userId: user.id, title: title, body: noticeBody
                )
                noticeTitle = ""
                noticeBody = ""
                result = L("admin.notify.sent", "Отправлено")
            } catch APIError.server(_, let detail) {
                result = detail
            } catch {
                result = L("admin.failed", "Сервер не ответил")
            }
        }
    }

    private func toggleBan() {
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                if isBanned {
                    try await LaxifyAPI.shared.adminUnban(userId: user.id)
                } else {
                    try await LaxifyAPI.shared.adminBan(
                        userId: user.id, reason: L("admin.ban.reason", "Нарушение правил")
                    )
                }
                isBanned.toggle()
                await onChanged()
            } catch APIError.server(_, let detail) {
                result = detail
            } catch {
                result = L("admin.failed", "Сервер не ответил")
            }
        }
    }

    private static let full: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
