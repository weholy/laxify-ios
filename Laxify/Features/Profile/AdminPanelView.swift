import SwiftUI
import PhotosUI

/// Випка — the operator's panel.
///
/// Rebuilt around what the operator comes here to do. It used to open on a
/// raw list of people under five tabs squeezed into one segmented control,
/// with statistics as ten tables in a row and errors as three hundred
/// unsorted log lines — everything was there and nothing was findable.
///
/// Now it opens the way iOS Settings does: the handful of numbers that say
/// how things are, then a list of sections that say what is inside them and
/// how much needs attention. Errors are grouped by what went wrong, with how
/// often, instead of printed one by one; the action log speaks words rather
/// than codes.
struct AdminPanelView: View {
    var onBack: () -> Void

    enum Destination: Hashable {
        case people
        case problems
        case statistics
        case broadcast
        case journal
    }

    @State private var path: [Destination] = []
    @State private var stats: LaxifyAPI.AdminStatsDTO?
    @State private var problems: [LaxifyAPI.AdminDiagnosticRow] = []
    @State private var isLoading = false
    @State private var failure: String?

    var body: some View {
        NavigationStack(path: $path) {
            hub
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Destination.self) { destination in
                    switch destination {
                    case .people: AdminPeopleScreen()
                    case .problems: AdminProblemsScreen()
                    case .statistics: AdminStatisticsScreen()
                    case .broadcast: AdminBroadcastScreen()
                    case .journal: AdminJournalScreen()
                    }
                }
        }
        .tint(LaxifyPalette.accent)
    }

    // MARK: - Hub

    private var hub: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                SettingsHeader(title: L("settings.admin", "Випка"), onBack: onBack)

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let failure { AdminNotice(text: failure) }

                        summary
                        sections

                        AdminSectionTitle(L("admin.appVersion", "Версия приложения"))
                        AdminVersionGateCard()
                    }
                    .padding(.horizontal, LaxifyMetrics.screenPadding)
                    .padding(.top, 4)
                    .padding(.bottom, 60)
                }
                .refreshable { await reload() }
            }
        }
        .task { await reload() }
    }

    /// Four numbers, each with the one piece of context that makes it mean
    /// something. Tapping one opens the section it summarises.
    private var summary: some View {
        let errorsToday = problems.filter {
            $0.level == "error" && $0.happenedAt > Date().addingTimeInterval(-86_400)
        }.count

        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            AdminSummaryTile(
                value: stats.map { "\($0.usersTotal)" } ?? "—",
                title: L("admin.sum.people", "Людей"),
                detail: stats.map { "+\($0.usersToday) " + L("admin.sum.today", "сегодня") },
                symbol: "person.2.fill",
                tint: LaxifyPalette.accent
            ) { path.append(.people) }

            AdminSummaryTile(
                value: stats.map { "\($0.usersActive24h)" } ?? "—",
                title: L("admin.sum.active", "Заходили за сутки"),
                detail: stats.map { "\($0.usersActive7d) " + L("admin.sum.week", "за неделю") },
                symbol: "bolt.fill",
                tint: Color(hex: 0x34C759)
            ) { path.append(.statistics) }

            AdminSummaryTile(
                value: stats.map { "\($0.plays24h)" } ?? "—",
                title: L("admin.sum.plays", "Прослушиваний за сутки"),
                detail: stats.map { "\($0.plays7d) " + L("admin.sum.week", "за неделю") },
                symbol: "play.fill",
                tint: Color(hex: 0xAF52DE)
            ) { path.append(.statistics) }

            AdminSummaryTile(
                value: isLoading && problems.isEmpty ? "—" : "\(errorsToday)",
                title: L("admin.sum.errors", "Ошибок за сутки"),
                detail: errorsToday == 0
                    ? L("admin.sum.allGood", "всё спокойно")
                    : L("admin.sum.look", "посмотреть"),
                symbol: errorsToday == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                tint: errorsToday == 0 ? Color(hex: 0x34C759) : Color(hex: 0xFF453A)
            ) { path.append(.problems) }
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 10) {
            AdminSectionTitle(L("admin.sections", "Разделы"))

            SettingsCard {
                AdminSectionRow(
                    symbol: "person.2.fill",
                    tint: LaxifyPalette.accent,
                    title: L("admin.people", "Люди"),
                    subtitle: stats.map {
                        "\($0.usersTotal) " + L("admin.row.accounts", "аккаунтов") + " · "
                            + "\($0.usersBanned) " + L("admin.row.banned", "заблокировано")
                    } ?? L("admin.row.peopleSub", "Поиск, баны, права")
                ) { path.append(.people) }

                SettingsDivider()

                AdminSectionRow(
                    symbol: "exclamationmark.triangle.fill",
                    tint: Color(hex: 0xFF9F0A),
                    title: L("admin.problems", "Ошибки"),
                    subtitle: L("admin.row.problemsSub", "Что ломается у людей, по группам"),
                    badge: problemGroupsCount
                ) { path.append(.problems) }

                SettingsDivider()

                AdminSectionRow(
                    symbol: "chart.bar.fill",
                    tint: Color(hex: 0xAF52DE),
                    title: L("admin.statistics", "Статистика"),
                    subtitle: L("admin.row.statsSub", "Графики, топ треков и артистов")
                ) { path.append(.statistics) }

                SettingsDivider()

                AdminSectionRow(
                    symbol: "megaphone.fill",
                    tint: Color(hex: 0x30B0C7),
                    title: L("admin.broadcast", "Рассылка"),
                    subtitle: L("admin.row.broadcastSub", "Уведомление всем пользователям")
                ) { path.append(.broadcast) }

                SettingsDivider()

                AdminSectionRow(
                    symbol: "list.bullet.rectangle.portrait.fill",
                    tint: Color(hex: 0x8E8E93),
                    title: L("admin.journal", "Журнал действий"),
                    subtitle: L("admin.row.journalSub", "Кто что менял в Випке")
                ) { path.append(.journal) }
            }
        }
    }

    private var problemGroupsCount: Int? {
        let recent = problems.filter {
            $0.level == "error" && $0.happenedAt > Date().addingTimeInterval(-86_400)
        }
        let groups = Set(recent.map(\.message)).count
        return groups > 0 ? groups : nil
    }

    private func reload() async {
        isLoading = true
        failure = nil
        defer { isLoading = false }

        async let loadedStats = LaxifyAPI.shared.adminStats()
        async let loadedProblems = LaxifyAPI.shared.adminDiagnostics(level: "error", limit: 300)

        do {
            stats = try await loadedStats
        } catch APIError.server(_, let detail) {
            failure = detail
        } catch {
            failure = L("admin.failed", "Сервер не ответил. Потяните вниз, чтобы повторить")
        }
        problems = (try? await loadedProblems) ?? problems
    }
}

// MARK: - People

private struct AdminPeopleScreen: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all, active, new, banned, admins
        var id: String { rawValue }

        @MainActor
        var title: String {
            switch self {
            case .all: L("admin.filter.all", "Все")
            case .active: L("admin.filter.active", "Активные")
            case .new: L("admin.filter.new", "Новые")
            case .banned: L("admin.filter.banned", "Заблокированные")
            case .admins: L("admin.filter.admins", "Админы")
            }
        }
    }

    @State private var users: [LaxifyAPI.AdminUserDTO] = []
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var isLoading = false
    @State private var failure: String?
    @State private var selected: LaxifyAPI.AdminUserDTO?

    private var shown: [LaxifyAPI.AdminUserDTO] {
        let day = Date().addingTimeInterval(-86_400)
        let week = Date().addingTimeInterval(-7 * 86_400)
        return users.filter { user in
            switch filter {
            case .all: true
            case .active: (user.lastSeenAt ?? .distantPast) > day
            case .new: user.createdAt > week
            case .banned: user.isBanned
            case .admins: user.isAdmin
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                AdminSearchField(
                    placeholder: L("admin.search", "Имя, ник или почта"),
                    text: $query
                ) { Task { await reload() } }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Filter.allCases) { item in
                            AdminChip(
                                title: item.title,
                                count: count(for: item),
                                isOn: filter == item
                            ) { filter = item }
                        }
                    }
                }

                if let failure { AdminNotice(text: failure) }

                if isLoading && users.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }

                ForEach(shown) { user in
                    Button { selected = user } label: { AdminPersonRow(user: user) }
                        .buttonStyle(.plain)
                }

                if !isLoading && shown.isEmpty && failure == nil {
                    AdminNotice(text: L("admin.empty", "Никого не нашлось"))
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.bottom, 60)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await reload() }
        .adminScreen(title: L("admin.people", "Люди"))
        .task { await reload() }
        .sheet(item: $selected) { user in
            AdminUserSheet(user: user) { await reload() } onClose: { selected = nil }
        }
    }

    private func count(for item: Filter) -> Int? {
        guard item != .all else { return users.isEmpty ? nil : users.count }
        let day = Date().addingTimeInterval(-86_400)
        let week = Date().addingTimeInterval(-7 * 86_400)
        let value = users.filter { user in
            switch item {
            case .all: true
            case .active: (user.lastSeenAt ?? .distantPast) > day
            case .new: user.createdAt > week
            case .banned: user.isBanned
            case .admins: user.isAdmin
            }
        }.count
        return value > 0 ? value : nil
    }

    private func reload() async {
        isLoading = true
        failure = nil
        defer { isLoading = false }
        do {
            users = try await LaxifyAPI.shared.adminUsers(query: query, limit: 200)
        } catch APIError.server(_, let detail) {
            failure = detail
        } catch {
            failure = L("admin.failed", "Сервер не ответил. Потяните вниз, чтобы повторить")
        }
    }
}

private struct AdminPersonRow: View {
    let user: LaxifyAPI.AdminUserDTO

    var body: some View {
        HStack(spacing: 12) {
            CachedImage(url: user.avatarURL, displaySize: 90) {
                Circle()
                    .fill(LaxifyPalette.surfaceElevated)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(LaxifyPalette.textTertiary)
                    }
            }
            .frame(width: 48, height: 48)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(user.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                        .lineLimit(1)

                    if user.isAdmin {
                        AdminBadge(text: L("admin.badge.admin", "Админ"), tint: Color(hex: 0xFFD60A), dark: true)
                    }
                    if user.isBanned {
                        AdminBadge(text: L("admin.badge.banned", "Бан"), tint: Color(hex: 0xFF453A))
                    }
                }

                Text("@\(user.username)" + ((user.email?.isEmpty == false) ? " · \(user.email!)" : ""))
                    .font(.system(size: 13))
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(seenLine)
                    .font(.system(size: 12))
                    .foregroundStyle(isOnlineRecently ? Color(hex: 0x34C759) : LaxifyPalette.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LaxifyPalette.textTertiary)
        }
        .padding(12)
        .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
    }

    private var isOnlineRecently: Bool {
        (user.lastSeenAt ?? .distantPast) > Date().addingTimeInterval(-15 * 60)
    }

    private var seenLine: String {
        let joined = L("admin.joined", "с нами с") + " " + AdminFormat.day.string(from: user.createdAt)
        guard let seen = user.lastSeenAt else { return joined }
        if isOnlineRecently { return L("admin.onlineNow", "в сети") + " · " + joined }
        return L("admin.seen", "был(а)") + " " + AdminFormat.relative(seen) + " · " + joined
    }
}

// MARK: - Problems

/// What is going wrong, grouped by what went wrong.
///
/// A fault that happened eighty times is one problem, not eighty rows. The
/// groups are ordered by how often they happen, so the thing worth fixing
/// first is at the top; a group opens onto its occurrences, with the full
/// context of each, and can be exported as a file.
private struct AdminProblemsScreen: View {
    private enum Level: String, CaseIterable, Identifiable {
        case error, warn, all
        var id: String { rawValue }

        @MainActor
        var title: String {
            switch self {
            case .error: L("admin.diag.errors", "Ошибки")
            case .warn: L("admin.diag.warnings", "Предупреждения")
            case .all: L("admin.diag.all", "Всё")
            }
        }

        var query: String? { self == .all ? nil : rawValue }
    }

    struct ProblemGroup: Identifiable {
        let message: String
        let category: String
        let level: String
        let rows: [LaxifyAPI.AdminDiagnosticRow]
        var id: String { level + category + message }
        var last: Date { rows.map(\.happenedAt).max() ?? .distantPast }
        var devices: Int { Set(rows.map(\.sessionId)).count }
    }

    @State private var level: Level = .error
    @State private var rows: [LaxifyAPI.AdminDiagnosticRow] = []
    @State private var isLoading = false
    @State private var failure: String?

    private var groups: [ProblemGroup] {
        Dictionary(grouping: rows) { "\($0.level)|\($0.category)|\($0.message)" }
            .values
            .compactMap { items in
                guard let first = items.first else { return nil }
                return ProblemGroup(message: first.message, category: first.category, level: first.level, rows: items)
            }
            .sorted { $0.rows.count == $1.rows.count ? $0.last > $1.last : $0.rows.count > $1.rows.count }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $level) {
                    ForEach(Level.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                if !rows.isEmpty {
                    Text(
                        "\(rows.count) " + L("admin.diag.records", "записей") + " · "
                            + "\(groups.count) " + L("admin.diag.kinds", "видов")
                    )
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .padding(.top, 2)
                }

                if let failure { AdminNotice(text: failure) }

                if isLoading && rows.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }

                ForEach(groups) { group in
                    NavigationLink {
                        AdminProblemDetailScreen(group: group)
                    } label: {
                        AdminProblemGroupRow(group: group)
                    }
                    .buttonStyle(.plain)
                }

                if !isLoading && rows.isEmpty && failure == nil {
                    AdminNotice(text: L("admin.noData", "Ничего не случилось — и это хорошо"))
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.bottom, 60)
        }
        .refreshable { await reload() }
        .adminScreen(title: L("admin.problems", "Ошибки"))
        .task(id: level) { await reload() }
    }

    private func reload() async {
        isLoading = true
        failure = nil
        defer { isLoading = false }
        do {
            rows = try await LaxifyAPI.shared.adminDiagnostics(level: level.query, limit: 300)
        } catch APIError.server(_, let detail) {
            failure = detail
        } catch {
            failure = L("admin.failed", "Сервер не ответил. Потяните вниз, чтобы повторить")
        }
    }
}

private struct AdminProblemGroupRow: View {
    let group: AdminProblemsScreen.ProblemGroup

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(group.rows.count)")
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .frame(minWidth: 44)
                .padding(.vertical, 8)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(group.message)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                Text(
                    group.category + " · "
                        + L("admin.diag.last", "последний раз") + " " + AdminFormat.relative(group.last)
                        + " · " + "\(group.devices) " + L("admin.diag.sessions", "сессий")
                )
                .font(.system(size: 12))
                .foregroundStyle(LaxifyPalette.textTertiary)
                .lineLimit(2)
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LaxifyPalette.textTertiary)
                .padding(.top, 10)
        }
        .padding(12)
        .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
    }

    private var tint: Color {
        switch group.level {
        case "error": Color(hex: 0xFF453A)
        case "warn": Color(hex: 0xFF9F0A)
        default: LaxifyPalette.textSecondary
        }
    }
}

private struct AdminProblemDetailScreen: View {
    let group: AdminProblemsScreen.ProblemGroup

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                Text(group.message)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)

                ForEach(group.rows.sorted { $0.happenedAt > $1.happenedAt }) { entry in
                    AdminOccurrenceRow(entry: entry)
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.bottom, 60)
        }
        .adminScreen(title: group.category)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let file = export() {
                    ShareLink(item: file) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    /// The whole group as a readable text file, for pasting into a chat.
    private func export() -> URL? {
        var lines = [
            "Laxify — \(group.message)",
            "Выгружено: \(AdminFormat.full.string(from: Date()))",
            "Случаев: \(group.rows.count)",
            ""
        ]
        for entry in group.rows.sorted(by: { $0.happenedAt > $1.happenedAt }) {
            lines.append("[\(entry.level.uppercased())] \(AdminFormat.full.string(from: entry.happenedAt))")
            for (key, value) in entry.context.sorted(by: { $0.key < $1.key }) {
                lines.append("    \(key): \(value)")
            }
            var tail: [String] = []
            if let device = entry.deviceModel { tail.append(device) }
            if let version = entry.appVersion { tail.append("v\(version)") }
            if let ms = entry.durationMs { tail.append("\(ms) мс") }
            if !tail.isEmpty { lines.append("    — " + tail.joined(separator: " · ")) }
            lines.append("")
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("laxify-ошибка.txt")
        return (try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)) != nil
            ? url : nil
    }
}

private struct AdminOccurrenceRow: View {
    let entry: LaxifyAPI.AdminDiagnosticRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(AdminFormat.full.string(from: entry.happenedAt))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textSecondary)
                Spacer()
                if let ms = entry.durationMs {
                    Text("\(ms) мс")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.accent)
                }
            }

            // Where a track, a title or an error string lives — the part that
            // turns "something failed" into something fixable.
            ForEach(entry.context.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(key)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.textTertiary)
                        .frame(width: 80, alignment: .leading)
                    Text(value)
                        .font(.system(size: 12))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            let tail = [entry.deviceModel, entry.appVersion.map { "v\($0)" }].compactMap { $0 }
            if !tail.isEmpty {
                Text(tail.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(LaxifyPalette.textTertiary)
            }
        }
        .padding(12)
        .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Statistics

private struct AdminStatisticsScreen: View {
    @State private var stats: LaxifyAPI.AdminStatsDTO?
    @State private var isLoading = false
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let failure { AdminNotice(text: failure) }

                if let stats {
                    AdminHeadline(
                        total: stats.usersTotal,
                        activeWeek: stats.usersActive7d,
                        activeDay: stats.usersActive24h,
                        newToday: stats.usersToday
                    )

                    AdminBars(title: L("admin.playsChart", "Прослушивания, 14 дней"), values: stats.playsByDay)
                    AdminBars(title: L("admin.signups", "Регистрации, 14 дней"), values: stats.signupsByDay)

                    AdminRanked(title: L("admin.topTracks", "Топ треков"), rows: stats.topTracks)
                    AdminRanked(title: L("admin.topArtists", "Топ артистов"), rows: stats.topArtists)

                    AdminStatGrid(
                        title: L("admin.people", "Люди"),
                        items: [
                            .init(L("admin.usersTotal", "Всего"), stats.usersTotal),
                            .init(L("admin.usersToday", "За сутки"), stats.usersToday),
                            .init(L("admin.users7d", "За неделю"), stats.users7d),
                            .init(L("admin.users30d", "За месяц"), stats.users30d),
                            .init(L("admin.active24h", "Заходили за сутки"), stats.usersActive24h),
                            .init(L("admin.active7d", "Заходили за неделю"), stats.usersActive7d),
                            .init(L("admin.banned", "Заблокированы"), stats.usersBanned),
                            .init(L("admin.admins", "Админы"), stats.usersAdmin),
                            .init(L("admin.withAvatar", "С аватаркой"), stats.usersWithAvatar),
                            .init(L("admin.neverPlayed", "Ни разу не слушали"), stats.usersNeverPlayed)
                        ]
                    )

                    AdminStatGrid(
                        title: L("admin.listening", "Прослушивания"),
                        items: [
                            .init(L("admin.playsTotal", "Всего"), stats.playsTotal),
                            .init(L("admin.plays24h", "За сутки"), stats.plays24h),
                            .init(L("admin.plays7d", "За неделю"), stats.plays7d),
                            .init(L("admin.minutes", "Минут"), stats.minutesTotal),
                            .init(L("admin.tracks", "Разных треков"), stats.distinctTracks),
                            .init(L("admin.artists", "Разных артистов"), stats.distinctArtists)
                        ]
                    )

                    AdminStatGrid(
                        title: L("admin.content", "Контент"),
                        items: [
                            .init(L("admin.favorites", "В избранном"), stats.favoritesTotal),
                            .init(L("admin.playlists", "Плейлистов"), stats.playlistsTotal),
                            .init(L("admin.comments", "Комментариев"), stats.commentsTotal),
                            .init(L("admin.downloads", "Загрузок"), stats.downloadsTotal),
                            .init(L("admin.devices", "Устройств"), stats.devicesTotal),
                            .init(L("admin.notifications", "Уведомлений"), stats.notificationsTotal)
                        ]
                    )
                } else if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.bottom, 60)
        }
        .refreshable { await reload() }
        .adminScreen(title: L("admin.statistics", "Статистика"))
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        failure = nil
        defer { isLoading = false }
        do {
            stats = try await LaxifyAPI.shared.adminStats()
        } catch APIError.server(_, let detail) {
            failure = detail
        } catch {
            failure = L("admin.failed", "Сервер не ответил. Потяните вниз, чтобы повторить")
        }
    }
}

// MARK: - Broadcast

private struct AdminBroadcastScreen: View {
    var body: some View {
        AdminBroadcastForm()
            .adminScreen(title: L("admin.broadcast", "Рассылка"))
    }
}

// MARK: - Journal

/// Who did what, in words.
///
/// Sign-ins are the bulk of the log and almost never what the operator is
/// looking for, so they are hidden until asked for.
private struct AdminJournalScreen: View {
    @State private var rows: [LaxifyAPI.AdminLogRow] = []
    @State private var showsSignIns = false
    @State private var isLoading = false
    @State private var failure: String?

    private var shown: [LaxifyAPI.AdminLogRow] {
        showsSignIns ? rows : rows.filter { $0.action.hasPrefix("admin.") }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                Toggle(L("admin.journal.signIns", "Показывать входы в аккаунты"), isOn: $showsSignIns)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .tint(LaxifyPalette.accent)
                    .padding(14)
                    .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                if let failure { AdminNotice(text: failure) }

                if isLoading && rows.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }

                ForEach(shown) { entry in
                    let meaning = AdminAction(code: entry.action)
                    HStack(spacing: 12) {
                        Image(systemName: meaning.symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(meaning.tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(meaning.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(LaxifyPalette.textPrimary)
                                .lineLimit(1)
                            Text((entry.actor.map { "@\($0)" } ?? "—") + " · " + AdminFormat.relative(entry.createdAt))
                                .font(.system(size: 12))
                                .foregroundStyle(LaxifyPalette.textSecondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 6)
                    }
                    .padding(12)
                    .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                if !isLoading && shown.isEmpty && failure == nil {
                    AdminNotice(text: L("admin.noData", "Пока нечего показать"))
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.bottom, 60)
        }
        .refreshable { await reload() }
        .adminScreen(title: L("admin.journal", "Журнал действий"))
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        failure = nil
        defer { isLoading = false }
        do {
            rows = try await LaxifyAPI.shared.adminLog(limit: 300)
        } catch APIError.server(_, let detail) {
            failure = detail
        } catch {
            failure = L("admin.failed", "Сервер не ответил. Потяните вниз, чтобы повторить")
        }
    }
}

/// An audit code, said the way a person would say it.
private struct AdminAction {
    let title: String
    let symbol: String
    let tint: Color

    @MainActor
    init(code: String) {
        let meaning: (String, String, Color) = switch code {
        case "admin.ban": (L("admin.act.ban", "Заблокировал пользователя"), "nosign", Color(hex: 0xFF453A))
        case "admin.unban": (L("admin.act.unban", "Разблокировал пользователя"), "checkmark.circle.fill", Color(hex: 0x34C759))
        case "admin.set_admin": (L("admin.act.setAdmin", "Изменил права админа"), "star.fill", Color(hex: 0xFFD60A))
        case "admin.delete_user": (L("admin.act.delete", "Удалил аккаунт"), "trash.fill", Color(hex: 0xFF453A))
        case "admin.logout_all": (L("admin.act.logoutAll", "Завершил все сессии пользователя"), "rectangle.portrait.and.arrow.right", Color(hex: 0xFF9F0A))
        case "admin.clear_history": (L("admin.act.clearHistory", "Очистил историю прослушиваний"), "clock.arrow.circlepath", Color(hex: 0xFF9F0A))
        case "admin.notify": (L("admin.act.notify", "Отправил уведомление"), "bell.fill", LaxifyPalette.accent)
        case "admin.broadcast": (L("admin.act.broadcast", "Сделал рассылку"), "megaphone.fill", Color(hex: 0x30B0C7))
        case "admin.set_min_version": (L("admin.act.minVersion", "Изменил минимальную версию"), "arrow.up.circle.fill", Color(hex: 0xAF52DE))
        case "admin.token_add": (L("admin.act.tokenAdd", "Добавил токен"), "key.fill", Color(hex: 0x8E8E93))
        case "admin.token_delete": (L("admin.act.tokenDelete", "Удалил токен"), "key.slash", Color(hex: 0x8E8E93))
        case "auth.sign_in", "login.email": (L("admin.act.signIn", "Вход в аккаунт"), "person.crop.circle.badge.checkmark", Color(hex: 0x8E8E93))
        case "auth.sign_up": (L("admin.act.signUp", "Регистрация"), "person.crop.circle.badge.plus", Color(hex: 0x34C759))
        case "login.failed": (L("admin.act.loginFailed", "Неудачная попытка входа"), "exclamationmark.lock.fill", Color(hex: 0xFF9F0A))
        case "auth.link.google", "auth.link.telegram": (L("admin.act.link", "Привязал способ входа"), "link", Color(hex: 0x8E8E93))
        case "email.bound", "email.changed": (L("admin.act.email", "Изменил почту"), "envelope.fill", Color(hex: 0x8E8E93))
        default: (code, "circle.fill", Color(hex: 0x8E8E93))
        }
        title = meaning.0
        symbol = meaning.1
        tint = meaning.2
    }
}

// MARK: - Shared pieces

private extension View {
    /// Every pushed screen in the panel: the app's background, and the system
    /// navigation bar with its back button and swipe-back, which is the most
    /// ordinary way to be able to get back out of something.
    func adminScreen(title: String) -> some View {
        self
            .background(LaxifyPalette.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(LaxifyPalette.background, for: .navigationBar)
    }
}

private struct AdminSectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(LaxifyPalette.textSecondary)
            .textCase(.uppercase)
            .kerning(0.5)
            .padding(.leading, 4)
    }
}

private struct AdminSummaryTile: View {
    let value: String
    let title: String
    let detail: String?
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)

                Text(value)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                        .lineLimit(2)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(LaxifyPalette.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AdminSectionRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    var badge: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(tint, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                    Text(subtitle)
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 13, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(hex: 0xFF453A), in: Capsule())
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textTertiary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AdminSearchField: View {
    let placeholder: String
    @Binding var text: String
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LaxifyPalette.textTertiary)

            TextField(placeholder, text: $text)
                .font(.system(size: 15))
                .foregroundStyle(LaxifyPalette.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit(onSubmit)

            if !text.isEmpty {
                Button {
                    text = ""
                    onSubmit()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(LaxifyPalette.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct AdminChip: View {
    let title: String
    var count: Int?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if let count {
                    Text("\(count)")
                        .monospacedDigit()
                        .opacity(0.7)
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isOn ? .white : LaxifyPalette.textSecondary)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(isOn ? LaxifyPalette.accent : LaxifyPalette.surface, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct AdminBadge: View {
    let text: String
    let tint: Color
    var dark = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(dark ? .black : .white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint, in: Capsule())
    }
}

private struct AdminNotice: View {
    let text: String

    var body: some View {
        Text(text)
            .font(LaxifyTypography.footnote)
            .foregroundStyle(LaxifyPalette.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
    }
}

// MARK: - Building blocks

/// The operator's own clock — a registration time only means something next
/// to the day they are having.
enum AdminFormat {
    /// "5 минут назад", "вчера" — how recent something is, which is what the
    /// operator wants to know far more often than the exact timestamp.
    @MainActor
    static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    @MainActor
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = .current
        formatter.unitsStyle = .full
        return formatter
    }()

    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("ddMMyy")
        return formatter
    }()

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("HHmm")
        return formatter
    }()

    static let full: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

struct AdminStat: Identifiable {
    let title: String
    let value: Int
    var id: String { title }

    init(_ title: String, _ value: Int) {
        self.title = title
        self.value = value
    }
}

/// The top of the overview: the whole service in one card.
///
/// Two figures carry it. The total says how big this is; the share that came
/// back this week says whether it is alive — a thousand accounts of which
/// twelve return is a very different service from a hundred of which sixty do,
/// and a grid of equal-weight numbers hides that difference completely.
private struct AdminHeadline: View {
    let total: Int
    let activeWeek: Int
    let activeDay: Int
    let newToday: Int

    private var share: Double {
        guard total > 0 else { return 0 }
        return min(Double(activeWeek) / Double(total), 1)
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 2) {
                Text("\(total)")
                    .font(.system(size: 52, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .contentTransition(.numericText())

                Text(L("admin.usersTotal", "Всего аккаунтов"))
                    .font(.system(size: 13))
                    .foregroundStyle(LaxifyPalette.textSecondary)
            }

            // The bar is the point: a proportion read at a glance, rather than
            // two numbers the reader has to divide themselves.
            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(LaxifyPalette.separator)

                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [LaxifyPalette.accent, Color(hex: 0x5AC8FA)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(6, geo.size.width * share))
                            .animation(.spring(response: 0.6, dampingFraction: 0.85), value: share)
                    }
                }
                .frame(height: 10)

                HStack {
                    Text("\(activeWeek) \(L("admin.active7d", "за неделю"))")
                        .foregroundStyle(LaxifyPalette.accent)
                    Spacer()
                    Text("\(Int((share * 100).rounded()))%")
                        .foregroundStyle(LaxifyPalette.textSecondary)
                        .monospacedDigit()
                }
                .font(.system(size: 12, weight: .semibold))
            }

            HStack(spacing: 0) {
                pill(L("admin.active24h", "За сутки"), activeDay)
                Divider().frame(height: 30).overlay(LaxifyPalette.separator)
                pill(L("admin.usersToday", "Новых"), newToday)
            }
        }
        .padding(20)
        .background(
            LaxifyPalette.surface,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }

    private func pill(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(LaxifyPalette.textPrimary)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(LaxifyPalette.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The lever behind "Вышло обновление".
///
/// Reads and writes `min_supported_version` directly — an empty floor blocks
/// nobody, which is the state this should sit in until the day a build is
/// genuinely retired. Nothing here needs a fresh app release to take effect.
private struct AdminVersionGateCard: View {
    @State private var current = ""
    @State private var draft = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var result: String?

    private var isDirty: Bool { draft.trimmingCharacters(in: .whitespaces) != current }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(LaxifyPalette.accent)
                Text(L("admin.minVersion", "Минимальная версия"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                Spacer()
                if isLoading { ProgressView() }
            }

            Text(current.isEmpty
                 ? L("admin.minVersion.none", "Сейчас пускает любую версию")
                 : "\(L("admin.minVersion.active", "Требует не ниже")) \(current)")
                .font(.system(size: 12))
                .foregroundStyle(LaxifyPalette.textSecondary)

            HStack(spacing: 8) {
                TextField(L("admin.minVersion.placeholder", "например 1.2"), text: $draft)
                    .keyboardType(.decimalPad)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        LaxifyPalette.surfaceElevated,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

                Button {
                    save()
                } label: {
                    if isSaving {
                        ProgressView().tint(.white)
                    } else {
                        Text(L("common.save", "Сохранить"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .glassEffect(.regular.tint(LaxifyPalette.accent).interactive(), in: .capsule)
                .disabled(!isDirty || isSaving)
                .opacity(isDirty ? 1 : 0.45)
            }

            if let result {
                Text(result)
                    .font(.system(size: 11))
                    .foregroundStyle(LaxifyPalette.textTertiary)
            }
        }
        .padding(16)
        .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task {
            current = (try? await LaxifyAPI.shared.adminReadMinVersion()) ?? ""
            draft = current
            isLoading = false
        }
    }

    private func save() {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                current = try await LaxifyAPI.shared.adminSetMinVersion(
                    draft.trimmingCharacters(in: .whitespaces)
                )
                draft = current
                result = L("admin.minVersion.saved", "Сохранено")
            } catch {
                result = L("admin.failed", "Сервер не ответил")
            }
        }
    }
}

/// A block of counts, two to a row. Numbers first, because that is what is
/// being read; the words are there to say which number it is.
private struct AdminStatGrid: View {
    let title: String
    let items: [AdminStat]

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(LaxifyPalette.textTertiary)
                .padding(.horizontal, 4)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(item.value)")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(LaxifyPalette.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)

                        Text(item.title)
                            .font(.system(size: 11))
                            .foregroundStyle(LaxifyPalette.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        LaxifyPalette.surface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                }
            }
        }
    }
}

/// Fourteen days as fourteen bars. Enough to see a shape without pretending
/// to be a charting library.
private struct AdminBars: View {
    let title: String
    let values: [LaxifyAPI.AdminDayCount]

    private var peak: Int { max(values.map(\.count).max() ?? 1, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(LaxifyPalette.textTertiary)
                .padding(.horizontal, 4)

            if values.isEmpty {
                Text(L("admin.noData", "Пока нечего показать"))
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(
                        LaxifyPalette.surface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
            } else {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(values) { entry in
                        VStack(spacing: 4) {
                            Text("\(entry.count)")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(LaxifyPalette.textTertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)

                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(LaxifyPalette.accent)
                                .frame(height: max(4, 76 * CGFloat(entry.count) / CGFloat(peak)))

                            Text(String(entry.day.suffix(2)))
                                .font(.system(size: 9))
                                .foregroundStyle(LaxifyPalette.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(12)
                .background(
                    LaxifyPalette.surface,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            }
        }
    }
}

/// A short list of tracks with what was done to them and when.
private struct AdminTrackList: View {
    let title: String
    let rows: [LaxifyAPI.AdminPlayRow]
    let showsTime: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(LaxifyPalette.textTertiary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(LaxifyPalette.textPrimary)
                                .lineLimit(1)
                            Text(row.artistName)
                                .font(.system(size: 12))
                                .foregroundStyle(LaxifyPalette.textSecondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 6)

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(AdminFormat.full.string(from: row.playedAt))
                                .font(.system(size: 11))
                                .foregroundStyle(LaxifyPalette.textTertiary)

                            if showsTime {
                                Text(
                                    row.completed
                                        ? L("admin.toTheEnd", "до конца")
                                        : "\(Int(row.secondsPlayed)) \(L("unit.sec", "с"))"
                                )
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(
                                    row.completed ? LaxifyPalette.accent : LaxifyPalette.textTertiary
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    if row.id != rows.last?.id {
                        SettingsDivider(inset: 14)
                    }
                }
            }
            .background(
                LaxifyPalette.surface,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
    }
}

private struct AdminRanked: View {
    let title: String
    let rows: [LaxifyAPI.AdminNamedCount]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(LaxifyPalette.textTertiary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(LaxifyPalette.textTertiary)
                            .frame(width: 20, alignment: .trailing)

                        Text(row.name)
                            .font(.system(size: 14))
                            .foregroundStyle(LaxifyPalette.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 6)

                        Text("\(row.count)")
                            .font(.system(size: 14, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(LaxifyPalette.textSecondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)

                    if row.id != rows.last?.id {
                        SettingsDivider(inset: 44)
                    }
                }

                if rows.isEmpty {
                    Text(L("admin.noData", "Пока нечего показать"))
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(LaxifyPalette.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                }
            }
            .background(
                LaxifyPalette.surface,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
    }
}

/// The circle every notice goes out with, picked once and reused for both
/// a broadcast and a single notify.
///
/// A notification with no icon of its own falls back to the app's own mark —
/// there is no reason for the client to ever draw a bare bell or a sparkle
/// where a person could look for who this is from.
private struct AdminIconPicker: View {
    @Binding var iconURL: String?

    @State private var item: PhotosPickerItem?
    @State private var isUploading = false

    var body: some View {
        HStack(spacing: 12) {
            PhotosPicker(selection: $item, matching: .images) {
                ZStack {
                    if let iconURL, let url = URL(string: iconURL) {
                        CachedImage(url: url, displaySize: 120) {
                            Color.clear
                        }
                    } else {
                        Image("LaxifyLogo")
                            .resizable()
                            .scaledToFit()
                            .padding(10)
                    }

                    if isUploading {
                        ZStack {
                            Circle().fill(.black.opacity(0.45))
                            ProgressView().tint(.white)
                        }
                    }
                }
                .frame(width: 44, height: 44)
                .background(LaxifyPalette.surfaceElevated, in: Circle())
                .clipShape(Circle())
                .overlay { Circle().stroke(LaxifyPalette.separator, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .disabled(isUploading)

            VStack(alignment: .leading, spacing: 2) {
                Text(L("admin.icon", "Иконка уведомления"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                Text(iconURL == nil
                     ? L("admin.icon.default", "Сейчас — значок Laxify")
                     : L("admin.icon.custom", "Своя картинка"))
                    .font(.system(size: 11))
                    .foregroundStyle(LaxifyPalette.textSecondary)
            }

            Spacer()

            if iconURL != nil {
                Button {
                    iconURL = nil
                } label: {
                    Text(L("common.delete", "Удалить"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: item) { _, newValue in
            guard let newValue else { return }
            Task { await upload(newValue) }
        }
    }

    private func upload(_ item: PhotosPickerItem) async {
        isUploading = true
        defer { isUploading = false; self.item = nil }

        guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else { return }
        if let url = try? await LaxifyAPI.shared.uploadMedia(
            data, filename: "notify-icon.jpg", mimeType: "image/jpeg"
        ) {
            iconURL = url.absoluteString
        }
    }
}

// MARK: - Broadcast

/// One notice to everyone at once.
private struct AdminBroadcastForm: View {
    @State private var title = ""
    @State private var body_ = ""
    @State private var iconURL: String?
    @State private var onlyActive = false
    @State private var isBusy = false
    @State private var result: String?
    @State private var showsConfirmation = false

    private var canSend: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !isBusy
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text(L("admin.broadcast.note", "Уведомление придёт всем, кто не заблокирован. Отменить рассылку нельзя."))
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                AdminIconPicker(iconURL: $iconURL)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        LaxifyPalette.surface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )

                TextField(L("admin.notify.title", "Заголовок"), text: $title)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .background(
                        LaxifyPalette.surface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )

                TextField(L("admin.notify.body", "Текст"), text: $body_, axis: .vertical)
                    .lineLimit(4...10)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .background(
                        LaxifyPalette.surface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )

                Toggle(L("admin.onlyActive", "Только тем, кто что-то слушал"), isOn: $onlyActive)
                    .font(.system(size: 15))
                    .tint(LaxifyPalette.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        LaxifyPalette.surface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )

                Button {
                    showsConfirmation = true
                } label: {
                    HStack(spacing: 8) {
                        if isBusy { ProgressView().tint(.white) }
                        Text(L("admin.broadcast.send", "Разослать"))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .glassEffect(.regular.tint(LaxifyPalette.accent).interactive(), in: .capsule)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.45)

                if let result {
                    Text(result)
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.bottom, 120)
        }
        .scrollDismissesKeyboard(.interactively)
        .confirmationDialog(
            L("admin.broadcast.confirm", "Разослать всем?"),
            isPresented: $showsConfirmation,
            titleVisibility: .visible
        ) {
            Button(L("admin.broadcast.send", "Разослать"), role: .destructive) { send() }
            Button(L("common.cancel", "Отмена"), role: .cancel) {}
        }
    }

    private func send() {
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                result = try await LaxifyAPI.shared.adminBroadcast(
                    title: title.trimmingCharacters(in: .whitespaces),
                    body: body_,
                    onlyActive: onlyActive,
                    iconUrl: iconURL
                )
                title = ""
                body_ = ""
                iconURL = nil
            } catch APIError.server(_, let detail) {
                result = detail
            } catch {
                result = L("admin.failed", "Сервер не ответил")
            }
        }
    }
}

// MARK: - One person

/// Everything known about one account, and everything that can be done to it.
private struct AdminUserSheet: View {
    let user: LaxifyAPI.AdminUserDTO
    var onChanged: () async -> Void
    var onClose: () -> Void

    @State private var stats: LaxifyAPI.AdminUserStatsDTO?
    @State private var activity: LaxifyAPI.AdminActivityDTO?
    @State private var showsClearHistory = false
    @State private var noticeTitle = ""
    @State private var noticeBody = ""
    @State private var noticeIconURL: String?
    @State private var isBusy = false
    @State private var result: String?
    @State private var isBanned: Bool
    @State private var isAdmin: Bool
    @State private var showsDelete = false
    @State private var activityTab: ActivityTab = .plays

    private enum ActivityTab: String, CaseIterable, Identifiable {
        case plays, favorites
        var id: String { rawValue }

        @MainActor
        var title: String {
            switch self {
            case .plays: L("admin.recentPlays", "Прослушивания")
            case .favorites: L("admin.theirFavorites", "Избранное")
            }
        }
    }

    init(
        user: LaxifyAPI.AdminUserDTO,
        onChanged: @escaping () async -> Void,
        onClose: @escaping () -> Void
    ) {
        self.user = user
        self.onChanged = onChanged
        self.onClose = onClose
        _isBanned = State(initialValue: user.isBanned)
        _isAdmin = State(initialValue: user.isAdmin)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    facts
                    figures
                    activityLists
                    notifier
                    actions

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
        .task {
            // Both at once: two sequential round trips over a phone
            // connection is twice as long spent looking at a spinner.
            async let counted = LaxifyAPI.shared.adminUserStats(userId: user.id)
            async let recent = LaxifyAPI.shared.adminActivity(userId: user.id)
            stats = try? await counted
            activity = try? await recent
        }
        .confirmationDialog(
            L("admin.delete.confirm", "Удалить аккаунт навсегда?"),
            isPresented: $showsDelete,
            titleVisibility: .visible
        ) {
            Button(L("common.delete", "Удалить"), role: .destructive) { deleteAccount() }
            Button(L("common.cancel", "Отмена"), role: .cancel) {}
        } message: {
            Text(L("admin.delete.note", "Вместе с ним пропадут его избранное, история и плейлисты"))
        }
        .confirmationDialog(
            L("admin.clearHistory.confirm", "Очистить историю прослушиваний?"),
            isPresented: $showsClearHistory,
            titleVisibility: .visible
        ) {
            Button(L("common.delete", "Удалить"), role: .destructive) { clearHistory() }
            Button(L("common.cancel", "Отмена"), role: .cancel) {}
        } message: {
            Text(L("admin.clearHistory.note", "Аккаунт останется, пропадёт только статистика"))
        }
    }

    /// What they have actually been doing — the lists behind the counts.
    @ViewBuilder
    private var activityLists: some View {
        if let activity {
            // A tab rather than two stacked lists — thirty rows of plays
            // sitting directly above thirty rows of favourites was the
            // "very dense" complaint in one screenshot, and nobody reads
            // both at once anyway.
            if !activity.recentPlays.isEmpty || !activity.favorites.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $activityTab) {
                        ForEach(ActivityTab.allCases) { entry in
                            Text(entry.title).tag(entry)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch activityTab {
                    case .plays:
                        if activity.recentPlays.isEmpty {
                            emptyActivityNote(L("admin.noData", "Пока нечего показать"))
                        } else {
                            AdminTrackList(
                                title: L("admin.recentPlays", "Прослушивания"),
                                rows: activity.recentPlays,
                                showsTime: true
                            )
                        }
                    case .favorites:
                        if activity.favorites.isEmpty {
                            emptyActivityNote(L("admin.noData", "Пока нечего показать"))
                        } else {
                            AdminTrackList(
                                title: L("admin.theirFavorites", "Избранное"),
                                rows: activity.favorites,
                                showsTime: false
                            )
                        }
                    }
                }
            }

            if !activity.devices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("admin.devicesList", "Устройства").uppercased())
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(0.6)
                        .foregroundStyle(LaxifyPalette.textTertiary)
                        .padding(.horizontal, 4)

                    VStack(spacing: 0) {
                        ForEach(activity.devices) { device in
                            HStack(spacing: 10) {
                                Image(systemName: device.revoked ? "iphone.slash" : "iphone")
                                    .font(.system(size: 14))
                                    .foregroundStyle(
                                        device.revoked ? LaxifyPalette.textTertiary : LaxifyPalette.accent
                                    )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(LaxifyPalette.textPrimary)
                                        .lineLimit(1)
                                    Text(device.appVersion.map { "v\($0)" } ?? "—")
                                        .font(.system(size: 11))
                                        .foregroundStyle(LaxifyPalette.textTertiary)
                                }

                                Spacer(minLength: 6)

                                Text(AdminFormat.day.string(from: device.lastSeenAt ?? device.createdAt))
                                    .font(.system(size: 11))
                                    .foregroundStyle(LaxifyPalette.textTertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)

                            if device.id != activity.devices.last?.id {
                                SettingsDivider(inset: 38)
                            }
                        }
                    }
                    .background(
                        LaxifyPalette.surface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                }
            }

            if !activity.searches.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("admin.searchesList", "Что искал").uppercased())
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(0.6)
                        .foregroundStyle(LaxifyPalette.textTertiary)
                        .padding(.horizontal, 4)

                    WordFlowLayout(horizontalSpacing: 6, lineSpacing: 6) {
                        ForEach(activity.searches, id: \.self) { entry in
                            Text(entry)
                                .font(.system(size: 12))
                                .foregroundStyle(LaxifyPalette.textSecondary)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(LaxifyPalette.surface, in: Capsule())
                        }
                    }
                }
            }
        }
    }

    private func emptyActivityNote(_ text: String) -> some View {
        Text(text)
            .font(LaxifyTypography.footnote)
            .foregroundStyle(LaxifyPalette.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var facts: some View {
        VStack(spacing: 0) {
            fact(L("admin.handle", "Юзернейм"), "@\(user.username)")
            SettingsDivider()
            fact(L("settings.email", "Почта"), user.email ?? "—")
            SettingsDivider()
            fact(L("admin.registered", "Регистрация"), AdminFormat.full.string(from: user.createdAt))
            if let seen = user.lastSeenAt {
                SettingsDivider()
                fact(L("admin.lastSeen", "Был в сети"), AdminFormat.full.string(from: seen))
            }
            if let reason = user.banReason, isBanned {
                SettingsDivider()
                fact(L("admin.banReason", "Причина блокировки"), reason)
            }
        }
        .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(LaxifyPalette.textSecondary)
            Spacer(minLength: 10)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LaxifyPalette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(14)
    }

    @ViewBuilder
    private var figures: some View {
        if let stats {
            AdminStatGrid(
                title: L("admin.hisNumbers", "Его цифры"),
                items: [
                    .init(L("admin.favorites", "В избранном"), stats.favorites),
                    .init(L("admin.disliked", "Не нравится"), stats.disliked),
                    .init(L("admin.playsTotal", "Прослушиваний"), stats.playsTotal),
                    .init(L("admin.plays7d", "За неделю"), stats.plays7d),
                    .init(L("admin.plays24h", "За сутки"), stats.plays24h),
                    .init(L("admin.minutes", "Минут"), stats.minutesTotal),
                    .init(L("admin.tracks", "Разных треков"), stats.distinctTracks),
                    .init(L("admin.artists", "Разных артистов"), stats.distinctArtists),
                    .init(L("admin.completed", "Дослушал до конца"), stats.completedPlays),
                    .init(L("admin.daysWithMusic", "Дней с музыкой"), stats.daysWithMusic),
                    .init(L("admin.playlists", "Плейлистов"), stats.playlists),
                    .init(L("admin.playlistTracks", "Треков в плейлистах"), stats.playlistTracks),
                    .init(L("admin.downloads", "Скачано"), stats.downloads),
                    .init(L("admin.devices", "Устройств"), stats.devices),
                    .init(L("admin.comments", "Комментариев"), stats.comments),
                    .init(L("admin.searches", "Поисков"), stats.searches),
                    .init(L("admin.followers", "Подписчиков"), stats.followers),
                    .init(L("admin.following", "Подписок"), stats.following),
                    .init(L("admin.notifications", "Уведомлений"), stats.notifications),
                    .init(L("admin.unread", "Непрочитанных"), stats.unreadNotifications)
                ]
            )

            VStack(spacing: 0) {
                if let first = stats.firstPlayAt {
                    fact(L("admin.firstPlay", "Первый трек"), AdminFormat.full.string(from: first))
                    SettingsDivider()
                }
                if let last = stats.lastPlayAt {
                    fact(L("admin.lastPlay", "Последний трек"), AdminFormat.full.string(from: last))
                    SettingsDivider()
                }
                fact(L("admin.topArtist", "Любимый артист"), stats.topArtist ?? "—")
                SettingsDivider()
                fact(L("admin.topTrack", "Любимый трек"), stats.topTrack ?? "—")
            }
            .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            ProgressView().padding(.vertical, 20)
        }
    }

    private var notifier: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("admin.notify", "Отправить уведомление"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LaxifyPalette.textPrimary)

            AdminIconPicker(iconURL: $noticeIconURL)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    LaxifyPalette.surfaceElevated,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )

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

            Button(action: send) {
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
        .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 10) {
            pill(
                isAdmin
                    ? L("admin.revokeAdmin", "Снять права админа")
                    : L("admin.grantAdmin", "Выдать права админа"),
                tint: Color(hex: 0xFFD60A),
                action: toggleAdmin
            )

            pill(
                L("admin.logoutAll", "Завершить все сессии"),
                tint: LaxifyPalette.textPrimary,
                action: logoutEverywhere
            )

            pill(
                L("admin.clearHistory", "Очистить историю"),
                tint: .orange,
                action: { showsClearHistory = true }
            )

            if !user.isAdmin {
                pill(
                    isBanned ? L("admin.unban", "Разблокировать") : L("admin.ban", "Заблокировать"),
                    tint: isBanned ? LaxifyPalette.accent : .red,
                    action: toggleBan
                )

                pill(
                    L("admin.delete", "Удалить аккаунт"),
                    tint: .red,
                    action: { showsDelete = true }
                )
            } else {
                Text(L("admin.cannotBan", "Администратора нельзя заблокировать или удалить"))
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func pill(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .glassEffect(.regular.tint(tint.opacity(0.12)).interactive(), in: .capsule)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    // MARK: - Doing things

    private func send() {
        let title = noticeTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }

        run {
            try await LaxifyAPI.shared.adminNotify(
                userId: user.id, title: title, body: noticeBody, iconUrl: noticeIconURL
            )
            noticeTitle = ""
            noticeBody = ""
            noticeIconURL = nil
            result = L("admin.notify.sent", "Отправлено")
        }
    }

    private func toggleBan() {
        run {
            if isBanned {
                try await LaxifyAPI.shared.adminUnban(userId: user.id)
            } else {
                try await LaxifyAPI.shared.adminBan(
                    userId: user.id, reason: L("admin.ban.reason", "Нарушение правил")
                )
            }
            isBanned.toggle()
            await onChanged()
        }
    }

    private func toggleAdmin() {
        run {
            try await LaxifyAPI.shared.adminSetAdmin(userId: user.id, isAdmin: !isAdmin)
            isAdmin.toggle()
            await onChanged()
        }
    }

    private func deleteAccount() {
        run {
            try await LaxifyAPI.shared.adminDeleteUser(userId: user.id)
            await onChanged()
            onClose()
        }
    }

    /// The gentler cousin of a ban: every session ends, the account stays.
    private func logoutEverywhere() {
        run {
            result = try await LaxifyAPI.shared.adminLogoutEverywhere(userId: user.id)
            activity = try? await LaxifyAPI.shared.adminActivity(userId: user.id)
        }
    }

    private func clearHistory() {
        run {
            result = try await LaxifyAPI.shared.adminClearHistory(userId: user.id)
            stats = try? await LaxifyAPI.shared.adminUserStats(userId: user.id)
            activity = try? await LaxifyAPI.shared.adminActivity(userId: user.id)
        }
    }

    /// Every action here fails the same way and reports it the same way, so
    /// the reporting lives in one place.
    private func run(_ work: @escaping () async throws -> Void) {
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                try await work()
            } catch APIError.server(_, let detail) {
                result = detail
            } catch {
                result = L("admin.failed", "Сервер не ответил")
            }
        }
    }
}
