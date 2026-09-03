import SwiftUI
import PhotosUI

/// The operator's panel — who is here, what they do, and what can be done
/// about them.
///
/// Reloads whenever it opens, whenever the tab changes and after every action,
/// because a stale list of people is worse than no list: a ban you have
/// already applied has to be visible or you will apply it twice.
struct AdminPanelView: View {
    var onBack: () -> Void

    private enum Tab: String, CaseIterable, Identifiable {
        case users
        case overview
        case diagnostics
        case broadcast
        case log

        var id: String { rawValue }

        @MainActor
        var title: String {
            switch self {
            case .users: L("admin.users", "Люди")
            case .overview: L("admin.overview", "Обзор")
            case .diagnostics: L("admin.diagnosticsTab", "Ошибки")
            case .broadcast: L("admin.broadcastTab", "Рассылка")
            case .log: L("admin.logTab", "Журнал")
            }
        }
    }

    @State private var tab: Tab = .users
    @State private var users: [LaxifyAPI.AdminUserDTO] = []
    @State private var stats: LaxifyAPI.AdminStatsDTO?
    @State private var diagnostics: [LaxifyAPI.AdminDiagnosticRow] = []
    @State private var diagnosticsLevel: String?
    @State private var log: [LaxifyAPI.AdminLogRow] = []
    @State private var query = ""
    @State private var isLoading = false
    @State private var failure: String?
    @State private var selected: LaxifyAPI.AdminUserDTO?

    var body: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                SettingsHeader(title: L("settings.admin", "Випка"), onBack: onBack)

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
        case .diagnostics: diagnosticsList
        case .broadcast: AdminBroadcastForm()
        case .log: logList
        }
    }

    /// Every error the app has phoned home with, newest first. This is the
    /// direct answer to "let me see every failure myself" — the data was
    /// already being collected; nothing looked at it.
    private var diagnosticsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                diagnosticsFilterRow

                if let failure { notice(failure) }

                if isLoading && diagnostics.isEmpty {
                    ProgressView().padding(.top, 40)
                }

                ForEach(diagnostics) { entry in
                    diagnosticsRow(entry)
                }

                if !isLoading && diagnostics.isEmpty && failure == nil {
                    notice(L("admin.noData", "Ничего не случилось — и это хорошо"))
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.bottom, 120)
        }
        .refreshable { await reload() }
    }

    private var diagnosticsFilterRow: some View {
        HStack(spacing: 8) {
            diagnosticsChip(L("admin.diag.all", "Все"), isOn: diagnosticsLevel == nil) {
                diagnosticsLevel = nil
                Task { await reload() }
            }
            diagnosticsChip(L("admin.diag.errors", "Ошибки"), isOn: diagnosticsLevel == "error") {
                diagnosticsLevel = "error"
                Task { await reload() }
            }
            diagnosticsChip(L("admin.diag.warnings", "Предупреждения"), isOn: diagnosticsLevel == "warn") {
                diagnosticsLevel = "warn"
                Task { await reload() }
            }
            Spacer()
        }
    }

    private func diagnosticsChip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? .white : LaxifyPalette.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    isOn ? LaxifyPalette.accent : LaxifyPalette.surface,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private func diagnosticsRow(_ entry: LaxifyAPI.AdminDiagnosticRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(diagnosticsColor(entry.level))
                    .frame(width: 7, height: 7)

                Text(entry.category)
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.4)
                    .foregroundStyle(LaxifyPalette.textTertiary)

                Spacer(minLength: 6)

                Text(AdminFormat.full.string(from: entry.happenedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(LaxifyPalette.textTertiary)
            }

            Text(entry.message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LaxifyPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // The context is where a track id or an error string lives —
            // exactly what turns "something failed" into something fixable.
            if !entry.context.isEmpty {
                WordFlowLayout(horizontalSpacing: 6, lineSpacing: 6) {
                    ForEach(entry.context.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        Text("\(key): \(value)")
                            .font(.system(size: 11))
                            .foregroundStyle(LaxifyPalette.textSecondary)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(LaxifyPalette.surfaceElevated, in: Capsule())
                    }
                }
            }

            HStack(spacing: 6) {
                if let device = entry.deviceModel {
                    Text(device)
                }
                if let version = entry.appVersion {
                    Text("v\(version)")
                }
                if let ms = entry.durationMs {
                    Text("\(ms) мс")
                        .foregroundStyle(LaxifyPalette.accent)
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(LaxifyPalette.textTertiary)
        }
        .padding(12)
        .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func diagnosticsColor(_ level: String) -> Color {
        switch level {
        case "error": .red
        case "warn": .orange
        default: LaxifyPalette.textTertiary
        }
    }

    /// Who did what in here, newest first. An admin panel with no record of
    /// its own actions is one you cannot check — including against yourself.
    private var logList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if let failure { notice(failure) }

                if isLoading && log.isEmpty {
                    ProgressView().padding(.top, 40)
                }

                ForEach(log) { entry in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.action)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(LaxifyPalette.textPrimary)
                                .lineLimit(1)

                            Text(entry.actor.map { "@\($0)" } ?? "—")
                                .font(.system(size: 12))
                                .foregroundStyle(LaxifyPalette.textSecondary)
                        }

                        Spacer(minLength: 6)

                        Text(AdminFormat.full.string(from: entry.createdAt))
                            .font(.system(size: 11))
                            .foregroundStyle(LaxifyPalette.textTertiary)
                    }
                    .padding(12)
                    .background(
                        LaxifyPalette.surface,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                }

                if !isLoading && log.isEmpty && failure == nil {
                    notice(L("admin.noData", "Пока нечего показать"))
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.bottom, 120)
        }
        .refreshable { await reload() }
    }

    // MARK: - People

    private var userList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                searchField

                if let failure { notice(failure) }

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
        .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func row(_ user: LaxifyAPI.AdminUserDTO) -> some View {
        HStack(spacing: 12) {
            CachedImage(url: user.avatarURL, displaySize: 90) {
                Circle()
                    .fill(LaxifyPalette.surfaceElevated)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(LaxifyPalette.textTertiary)
                    }
            }
            .frame(width: 42, height: 42)
            .clipShape(Circle())

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
                Text(AdminFormat.day.string(from: user.createdAt))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textSecondary)
                Text(AdminFormat.time.string(from: user.createdAt))
                    .font(.system(size: 11))
                    .foregroundStyle(LaxifyPalette.textTertiary)
            }
        }
        .padding(12)
        .background(LaxifyPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
    }

    // MARK: - Overview

    private var overviewList: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let failure { notice(failure) }

                if let stats {
                    // The two numbers an operator actually opens this for,
                    // given the room they deserve: how many people there are,
                    // and how many of them came back this week. Everything
                    // else is detail underneath.
                    AdminHeadline(
                        total: stats.usersTotal,
                        activeWeek: stats.usersActive7d,
                        activeDay: stats.usersActive24h,
                        newToday: stats.usersToday
                    )

                    AdminVersionGateCard()

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

                    AdminBars(
                        title: L("admin.signups", "Регистрации, 14 дней"),
                        values: stats.signupsByDay
                    )
                    AdminBars(
                        title: L("admin.playsChart", "Прослушивания, 14 дней"),
                        values: stats.playsByDay
                    )

                    AdminRanked(title: L("admin.topTracks", "Топ треков"), rows: stats.topTracks)
                    AdminRanked(title: L("admin.topArtists", "Топ артистов"), rows: stats.topArtists)
                } else if isLoading {
                    ProgressView().padding(.top, 40)
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.bottom, 120)
        }
        .refreshable { await reload() }
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
                stats = try await LaxifyAPI.shared.adminStats()
            case .diagnostics:
                diagnostics = try await LaxifyAPI.shared.adminDiagnostics(level: diagnosticsLevel)
            case .log:
                log = try await LaxifyAPI.shared.adminLog()
            case .broadcast:
                break
            }
        } catch APIError.server(_, let detail) {
            failure = detail
        } catch {
            failure = L("admin.failed", "Сервер не ответил. Потяните вниз, чтобы повторить")
        }
    }
}

// MARK: - Building blocks

/// The operator's own clock — a registration time only means something next
/// to the day they are having.
enum AdminFormat {
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
