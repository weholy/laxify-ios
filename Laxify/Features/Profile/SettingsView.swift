import SwiftUI
import UIKit

/// Settings, as a short list that opens into the thing you picked.
///
/// Everything on one screen meant scrolling past three groups to reach the
/// fourth. Four entries that each open their own page is faster to read and
/// leaves room inside each one to say what a switch actually does.
struct SettingsView: View {
    var onClose: () -> Void

    @State private var session = SessionStore.shared
    @State private var showsSignOutConfirmation = false
    @State private var isSigningOut = false

    private enum Page: String, Identifiable {
        case language
        case info
        case privacy
        case about
        case account
        case appearance
        case export
        case diagnostics

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .language: "settings.language"
            case .info: "settings.info"
            case .privacy: "settings.privacy"
            case .about: "settings.about"
            case .account: "settings.account"
            case .appearance: "settings.appearance"
            case .export: "settings.export"
            case .diagnostics: "settings.diagnostics"
            }
        }

        var subtitleKey: String { titleKey + ".sub" }

        var title: String {
            switch self {
            case .language: "Язык"
            case .info: "Информация"
            case .privacy: "Конфиденциальность"
            case .about: "О себе"
            case .account: "Аккаунт"
            case .appearance: "Дизайн"
            case .export: "Выгрузка артистов"
            case .diagnostics: "Диагностика"
            }
        }

        var subtitle: String {
            switch self {
            case .language: "Язык приложения"
            case .info: "Telegram-канал, поддержать проект"
            case .privacy: "Кто видит ваш профиль и что вы слушаете"
            case .about: "Пара строк для вашей страницы"
            case .account: "Имя пользователя и сессии"
            case .appearance: "Тема и подписи в панели"
            case .export: "Список исполнителей файлом"
            case .diagnostics: "Что не работает и почему"
            }
        }
    }

    @State private var page: Page?

    var body: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                SettingsHeader(title: L("settings.title", "Настройки"), onBack: onClose)

                ScrollView {
                    VStack(spacing: 12) {
                        // .info is hidden for now — re-add to this list to show it.
                        let entries: [Page] = [.language, .privacy, .about, .account, .appearance]
                        ForEach(entries) { entry in
                            SettingsCard { entryRow(entry) }
                        }

                        signOutButton
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, LaxifyMetrics.screenPadding)
                    .padding(.top, 4)
                    .padding(.bottom, 120)
                }
            }
        }
        .fullScreenCover(item: $page) { entry in
            switch entry {
            case .language:
                LanguageSettingsView { page = nil }
            case .info:
                InfoSettingsView { page = nil }
            case .privacy:
                PrivacySettingsView { page = nil }
            case .about:
                AboutSettingsView { page = nil }
            case .account:
                AccountSettingsView { page = nil }
            case .appearance:
                AppearanceSettingsView { page = nil }
            case .export:
                CatalogExportView { page = nil }
            case .diagnostics:
                DiagnosticsView { page = nil }
            }
        }
        .confirmationDialog(
            L("settings.signout.confirm", "Точно хотите выйти?"),
            isPresented: $showsSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button(L("settings.signout", "Выйти"), role: .destructive) { signOut() }
            Button(L("settings.signout.stay", "Остаться"), role: .cancel) {}
        }
    }

    private func entryRow(_ entry: Page) -> some View {
        Button {
            page = entry
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L(entry.titleKey, entry.title))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.textPrimary)

                    Text(L(entry.subtitleKey, entry.subtitle))
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textTertiary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 17)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var signOutButton: some View {
        Button {
            showsSignOutConfirmation = true
        } label: {
            HStack(spacing: 8) {
                if isSigningOut {
                    ProgressView().tint(.red)
                }
                Text(isSigningOut ? L("settings.signingOut", "Выходим…") : L("settings.signout", "Выйти из аккаунта"))
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .glassEffect(.regular.tint(.red.opacity(0.12)).interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(isSigningOut)
    }

    private func signOut() {
        isSigningOut = true
        Task {
            await session.signOut()
            isSigningOut = false
        }
    }
}

// MARK: - Privacy

struct PrivacySettingsView: View {
    var onBack: () -> Void

    @State private var session = SessionStore.shared
    @State private var isProfilePublic = true
    @State private var isStatsPublic = false
    @State private var status: String?

    var body: some View {
        SettingsPage(title: L("settings.privacy", "Конфиденциальность"), status: status, onBack: onBack) {
            SettingsGroup(footer: L("privacy.publicProfile.sub", "Вас смогут найти по имени и увидеть ваши плейлисты")) {
                SettingsToggle(title: L("privacy.publicProfile", "Открытый профиль"), isOn: $isProfilePublic)
                    .onChange(of: isProfilePublic) { _, value in
                        save(isProfilePublic: value)
                    }
            }

            SettingsGroup(footer: L("privacy.showListening.sub", "Сколько вы слушаете и какие треки — будет видно в профиле")) {
                SettingsToggle(title: L("privacy.showListening", "Показывать, что слушаю"), isOn: $isStatsPublic)
                    .onChange(of: isStatsPublic) { _, value in
                        save(isStatsPublic: value)
                    }
            }
        }
        .onAppear {
            isProfilePublic = session.user?.isProfilePublic ?? true
            isStatsPublic = session.user?.isStatsPublic ?? false
        }
    }

    private func save(isProfilePublic: Bool? = nil, isStatsPublic: Bool? = nil) {
        Task {
            let failure = await session.updateProfile(
                isProfilePublic: isProfilePublic,
                isStatsPublic: isStatsPublic
            )

            if let failure {
                flash(failure)
                // Put the switches back where the server still has them,
                // rather than leaving a state that was never saved.
                self.isProfilePublic = session.user?.isProfilePublic ?? true
                self.isStatsPublic = session.user?.isStatsPublic ?? false
            } else {
                flash(L("privacy.saved", "Сохранено"))
            }
        }
    }

    private func flash(_ message: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { status = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.25)) { status = nil }
        }
    }
}

// MARK: - About

struct AboutSettingsView: View {
    var onBack: () -> Void

    @State private var session = SessionStore.shared
    @State private var bio = ""
    @State private var saved = ""
    @State private var status: String?
    @FocusState private var isEditing: Bool

    private let limit = 160

    var body: some View {
        SettingsPage(title: L("settings.about", "О себе"), status: status, onBack: onBack) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("about.hint", "Эти строки увидят те, кто откроет ваш профиль"))
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(LaxifyPalette.textSecondary)

                    TextField(L("about.placeholder", "Расскажите о себе"), text: $bio, axis: .vertical)
                        .font(.system(size: 16))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                        .lineLimit(3...6)
                        .focused($isEditing)

                    Text("\(bio.count) / \(limit)")
                        .font(.system(size: 12))
                        .foregroundStyle(bio.count > limit ? .red : LaxifyPalette.textTertiary)
                }
                .padding(16)
            }

            if bio != saved {
                Button {
                    isEditing = false
                    save()
                } label: {
                    Text(L("common.save", "Сохранить"))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(LaxifyPalette.textPrimary, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(bio.count > limit)
                .opacity(bio.count > limit ? 0.45 : 1)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: bio != saved)
        .onAppear {
            bio = session.user?.bio ?? ""
            saved = bio
            isEditing = true
        }
    }

    private func save() {
        let value = String(bio.prefix(limit))
        Task {
            let failure = await session.updateProfile(bio: value)
            if let failure {
                flash(failure)
            } else {
                saved = value
                bio = value
                flash(L("privacy.saved", "Сохранено"))
            }
        }
    }

    private func flash(_ message: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { status = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.25)) { status = nil }
        }
    }
}

// MARK: - Account

struct AccountSettingsView: View {
    var onBack: () -> Void

    @State private var session = SessionStore.shared
    @State private var isEditPresented = false
    @State private var showsLogoutAll = false
    @State private var status: String?

    private var user: BackendUser? { session.user }

    var body: some View {
        SettingsPage(title: L("settings.account", "Аккаунт"), status: status, onBack: onBack) {
            SettingsCard {
                Button {
                    UIPasteboard.general.string = user?.username
                    flash(L("account.copied", "Скопировано"))
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("account.username", "Имя пользователя"))
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(LaxifyPalette.textPrimary)
                            Text("@\(user?.username ?? "")")
                                .font(LaxifyTypography.footnote)
                                .foregroundStyle(LaxifyPalette.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundStyle(LaxifyPalette.textTertiary)
                    }
                    .padding(16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                SettingsDivider()

                SettingsRow(
                    title: L("account.name", "Имя и фото"),
                    description: user?.displayName ?? "—"
                ) {
                    isEditPresented = true
                }
            }

            SettingsCard {
                SettingsRow(
                    title: L("account.logoutAll", "Выйти на всех устройствах"),
                    description: L("account.logoutAll.sub", "Завершит все сессии, включая эту")
                ) {
                    showsLogoutAll = true
                }
            }
        }
        .fullScreenCover(isPresented: $isEditPresented) {
            EditProfileView { isEditPresented = false }
        }
        .confirmationDialog(
            L("account.logoutAll", "Выйти на всех устройствах"),
            isPresented: $showsLogoutAll,
            titleVisibility: .visible
        ) {
            Button(L("account.logoutAll.confirm", "Выйти везде"), role: .destructive) {
                Task {
                    _ = try? await LaxifyAPI.shared.signOutEverywhere()
                    await session.signOut()
                }
            }
            Button(L("common.cancel", "Отмена"), role: .cancel) {}
        }
    }

    private func flash(_ message: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { status = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.25)) { status = nil }
        }
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    var onBack: () -> Void

    @State private var appearance = AppearanceSettings.shared

    var body: some View {
        SettingsPage(title: L("settings.appearance", "Дизайн"), status: nil, onBack: onBack) {
            SettingsGroup {
                ForEach(AppearanceSettings.Theme.allCases, id: \.self) { theme in
                    themeRow(theme)
                    if theme != AppearanceSettings.Theme.allCases.last {
                        SettingsDivider()
                    }
                }
            }

            SettingsGroup(footer: L("appearance.hideLabels.sub", "Оставить в нижней панели только иконки")) {
                SettingsToggle(
                    title: L("appearance.hideLabels", "Скрыть подписи в панели"),
                    isOn: Binding(
                        get: { appearance.hideTabLabels },
                        set: { appearance.hideTabLabels = $0 }
                    )
                )
            }
        }
    }

    private func themeRow(_ theme: AppearanceSettings.Theme) -> some View {
        let isSelected = appearance.theme == theme

        return Button {
            withAnimation(.snappy(duration: 0.25)) { appearance.theme = theme }
        } label: {
            HStack(spacing: 14) {
                ThemePreview(theme: theme)

                VStack(alignment: .leading, spacing: 3) {
                    Text(theme.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(LaxifyPalette.textPrimary)

                    Text(theme.explanation)
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                }

                Spacer(minLength: 4)
            }
            .padding(16)
            .overlay(alignment: .trailing) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(LaxifyPalette.accent)
                        .padding(.trailing, 16)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A miniature of the app, so a theme can be recognised rather than read.
private struct ThemePreview: View {
    let theme: AppearanceSettings.Theme

    var body: some View {
        ZStack {
            switch theme {
            case .light:
                panel(.white, bar: Color(white: 0.88))
            case .dark:
                panel(.black, bar: Color(white: 0.24))
            case .system:
                // Split down the middle, which is what "follow the system"
                // amounts to without knowing what the system is set to.
                HStack(spacing: 0) {
                    panel(.white, bar: Color(white: 0.88))
                    panel(.black, bar: Color(white: 0.24))
                }
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: LaxifyMetrics.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LaxifyMetrics.cardCornerRadius, style: .continuous)
                .stroke(LaxifyPalette.separator, lineWidth: 1)
        }
    }

    private func panel(_ background: Color, bar: Color) -> some View {
        background.overlay(alignment: .bottom) {
            Capsule()
                .fill(bar)
                .frame(height: 6)
                .padding(.horizontal, 5)
                .padding(.bottom, 6)
        }
    }
}

// MARK: - Shared pieces

/// The frame every settings page shares: a header, a scrolling body, and a
/// place for the short confirmation that something was saved.
struct SettingsPage<Content: View>: View {
    let title: String
    var status: String?
    var onBack: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                SettingsHeader(title: title, onBack: onBack)

                ScrollView {
                    VStack(spacing: 16) {
                        content()
                    }
                    .padding(.horizontal, LaxifyMetrics.screenPadding)
                    .padding(.bottom, 120)
                }
                .scrollDismissesKeyboard(.interactively)
            }

            if let status {
                VStack {
                    Spacer()
                    Text(status)
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(LaxifyPalette.textPrimary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, 40)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
    }
}

struct SettingsHeader: View {
    let title: String
    var onBack: () -> Void

    var body: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .frame(width: 46, height: 46)
                    .glassEffect(.regular.interactive(), in: .circle)
                    // Interactive glass otherwise swallows taps that miss the
                    // glyph; re-declare the whole circle as the hit region.
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(LaxifyPalette.textPrimary)

            Spacer()

            // Balances the back button so the title sits centred.
            Color.clear.frame(width: 46, height: 46)
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.bottom, 14)
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            LaxifyPalette.surface,
            in: RoundedRectangle(cornerRadius: LaxifyMetrics.settingsCardCornerRadius, style: .continuous)
        )
    }
}

/// One section of a Telegram-style grouped list: an optional uppercase header
/// above the block, the rounded block itself, and an optional grey footer
/// line below it — both outside the rounded rectangle.
struct SettingsGroup<Content: View>: View {
    var header: String?
    var footer: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let header {
                Text(header.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .tracking(0.4)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }

            SettingsCard { content() }

            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }
        }
    }
}

struct SettingsToggle: View {
    let title: String
    /// Kept for callers that still pass it, but the grouped pattern puts the
    /// explanation in a footer under the card instead.
    var description: String = ""
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(LaxifyPalette.textPrimary)

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(LaxifyPalette.accent)
        }
        .padding(16)
    }
}

struct SettingsRow: View {
    let title: String
    let description: String
    var badge: String?
    var showsChevron = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(LaxifyPalette.textPrimary)

                        if let badge {
                            Text(badge)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.orange.opacity(0.15), in: Capsule())
                        }
                    }

                    Text(description)
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.textTertiary)
                }
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!showsChevron)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(LaxifyPalette.separator)
            .frame(height: 1)
            .padding(.leading, 16)
    }
}
