import SwiftUI
import PhotosUI
import UIKit

/// Settings, as one page: who you are at the top, then three short blocks —
/// the account, what the app does, and the two things you can act on.
///
/// The earlier version was a menu of five entries that each opened a page,
/// which meant two taps to read a value that fits on the line itself. Here the
/// language, the theme and the address sit on the page; only the entries with
/// something to explain still open.
struct SettingsView: View {
    var onClose: () -> Void

    @Environment(\.openURL) private var openURL

    @State private var session = SessionStore.shared
    @State private var appearance = AppearanceSettings.shared
    var localization = LocalizationManager.shared

    @State private var showsSignOutConfirmation = false
    @State private var isSigningOut = false
    @State private var avatarItem: PhotosPickerItem?
    @State private var isUploadingAvatar = false
    @State private var linked: LaxifyAPI.LinkedMethodsDTO?
    @State private var status: String?

    private var user: BackendUser? { session.user }

    private enum Page: String, Identifiable {
        case language
        case privacy
        case about
        case account
        case appearance
        case editProfile
        case export
        case diagnostics
        case info

        var id: String { rawValue }
    }

    @State private var page: Page?

    var body: some View {
        ZStack(alignment: .top) {
            LaxifyPalette.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    identity
                        .padding(.bottom, 6)

                    accountGroup
                    preferencesGroup
                    actionsGroup

                    telegramButton
                        .padding(.top, 14)

                    footer
                        .padding(.top, 6)
                }
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                .padding(.top, 10)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)

            // Pinned rather than scrolled away: this is the only way out.
            HStack {
                Spacer()
                LaxifyCloseButton(style: .xmark, tinted: false, action: onClose)
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.top, 10)

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
        .task { linked = try? await LaxifyAPI.shared.linkedMethods() }
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task { await uploadAvatar(item) }
        }
        .confirmationDialog(
            L("settings.signout.confirm", "Точно хотите выйти?"),
            isPresented: $showsSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button(L("settings.signout", "Выйти"), role: .destructive) { signOut() }
            Button(L("settings.signout.stay", "Остаться"), role: .cancel) {}
        }
        .fullScreenCover(item: $page) { entry in
            switch entry {
            case .language:
                LanguageSettingsView { page = nil }
            case .privacy:
                PrivacySettingsView { page = nil }
            case .about:
                AboutSettingsView { page = nil }
            case .account:
                AccountSettingsView { page = nil }
            case .appearance:
                AppearanceSettingsView { page = nil }
            case .editProfile:
                EditProfileView { page = nil }
            case .export:
                CatalogExportView { page = nil }
            case .diagnostics:
                DiagnosticsView { page = nil }
            case .info:
                InfoSettingsView { page = nil }
            }
        }
    }

    // MARK: - Identity

    private var identity: some View {
        VStack(spacing: 12) {
            PhotosPicker(selection: $avatarItem, matching: .images) {
                avatarImage
                    .frame(width: 108, height: 108)
                    .clipShape(Circle())
                    .overlay { Circle().stroke(LaxifyPalette.separator, lineWidth: 1) }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .glassEffect(
                                .regular.tint(LaxifyPalette.accent).interactive(),
                                in: .circle
                            )
                            .contentShape(Circle())
                            .offset(x: 2, y: 2)
                    }
                    .overlay {
                        if isUploadingAvatar {
                            ZStack {
                                Circle().fill(.black.opacity(0.45))
                                ProgressView().tint(.white)
                            }
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(isUploadingAvatar)

            VStack(spacing: 3) {
                Text(user?.displayName ?? "")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .lineLimit(1)

                Text("@\(user?.username ?? "")")
                    .font(LaxifyTypography.subheadline)
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var avatarImage: some View {
        if let url = user?.avatarURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    avatarPlaceholder
                }
            }
        } else {
            avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(LaxifyPalette.surface)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(LaxifyPalette.textTertiary)
            }
    }

    // MARK: - Groups

    private var accountGroup: some View {
        SettingsCard {
            SettingsLineRow(
                icon: "person",
                title: L("settings.username", "Юзернейм"),
                value: user?.username,
                showsChevron: true
            ) { page = .editProfile }

            SettingsDivider(inset: Self.rowLabelInset)

            SettingsLineRow(
                icon: "envelope",
                title: L("settings.email", "Почта"),
                value: user?.email
            )

            SettingsDivider(inset: Self.rowLabelInset)

            SettingsLineRow(
                logo: signIn.logo,
                title: signIn.title,
                value: L("settings.signedIn.value", "Выполнен"),
                showsCheck: true
            )
        }
    }

    private var preferencesGroup: some View {
        SettingsCard {
            SettingsLineRow(
                icon: "globe",
                title: L("settings.language", "Язык"),
                value: "\(localization.language.flag) \(localization.language.nativeName)",
                showsChevron: true
            ) { page = .language }

            SettingsDivider(inset: Self.rowLabelInset)

            SettingsLineRow(
                icon: "paintbrush",
                title: L("settings.appearance", "Дизайн"),
                value: appearance.theme.title,
                showsChevron: true
            ) { page = .appearance }

            SettingsDivider(inset: Self.rowLabelInset)

            SettingsLineRow(
                icon: "lock",
                title: L("settings.privacy", "Конфиденциальность"),
                showsChevron: true
            ) { page = .privacy }

            SettingsDivider(inset: Self.rowLabelInset)

            SettingsLineRow(
                icon: "text.quote",
                title: L("settings.about", "О себе"),
                showsChevron: true
            ) { page = .about }

            SettingsDivider(inset: Self.rowLabelInset)

            SettingsLineRow(
                icon: "key",
                title: L("settings.account", "Аккаунт"),
                showsChevron: true
            ) { page = .account }
        }
    }

    private var actionsGroup: some View {
        SettingsCard {
            SettingsLineRow(
                icon: "heart",
                title: L("info.support", "Поддержать проект")
            ) { openURL(AppLinks.support) }

            SettingsDivider(inset: Self.rowLabelInset)

            SettingsLineRow(
                icon: "rectangle.portrait.and.arrow.right",
                title: isSigningOut
                    ? L("settings.signingOut", "Выходим…")
                    : L("settings.signout", "Выйти из аккаунта"),
                tint: .red,
                isBusy: isSigningOut
            ) {
                guard !isSigningOut else { return }
                showsSignOutConfirmation = true
            }
        }
    }

    /// The mark and the line for however this account actually signed in —
    /// Google for nearly everyone, but the row should never claim it blindly.
    private var signIn: (logo: AnyView, title: String) {
        switch linked?.primary ?? "google" {
        case "telegram":
            return (
                AnyView(TelegramLogoView(size: 21, color: Color(hex: 0x2AABEE))),
                L("settings.signedIn.telegram", "Вход через Telegram")
            )
        case "email":
            return (
                AnyView(
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.accent)
                ),
                L("settings.signedIn.email", "Вход по почте")
            )
        default:
            return (
                AnyView(GoogleLogoView(size: 20)),
                L("settings.signedIn.google", "Вход через Google")
            )
        }
    }

    /// Dividers start where the labels do, not under the glyphs.
    private static let rowLabelInset: CGFloat = 56

    // MARK: - Bottom

    private var telegramButton: some View {
        Button {
            openURL(AppLinks.telegramChannel)
        } label: {
            HStack(spacing: 10) {
                TelegramLogoView(size: 21, color: Color(hex: 0x2AABEE))
                Text("Telegram")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 16)
            .glassEffect(
                .regular.tint(Color(hex: 0x2AABEE).opacity(0.22)).interactive(),
                in: .capsule
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            // A long press here is the way back into the diagnostics log,
            // which has no business taking a row of its own.
            Text("Laxify v \(AppVersion.short) (Beta)")
                .onLongPressGesture(minimumDuration: 1.2) { page = .diagnostics }

            Text("·")

            Button {
                openURL(AppLinks.support)
            } label: {
                Text(L("settings.contact", "Связаться с нами"))
                    .font(.system(size: 13))
                    .foregroundStyle(LaxifyPalette.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 13))
        .foregroundStyle(LaxifyPalette.textTertiary)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func uploadAvatar(_ item: PhotosPickerItem) async {
        isUploadingAvatar = true
        defer { isUploadingAvatar = false; avatarItem = nil }

        guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
            flash(L("settings.photo.unreadable", "Не удалось прочитать фото"))
            return
        }
        do {
            let url = try await LaxifyAPI.shared.uploadMedia(
                data, filename: "avatar.jpg", mimeType: "image/jpeg"
            )
            if let failure = await session.updateProfile(avatarURL: url.absoluteString) {
                flash(failure)
            }
        } catch {
            flash(L("settings.photo.failed", "Не удалось загрузить фото"))
        }
    }

    private func signOut() {
        isSigningOut = true
        Task {
            await session.signOut()
            isSigningOut = false
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

/// One line of the settings list: a glyph, what the line is, and what it is
/// currently set to. Rows without an action are read-only and don't highlight.
private struct SettingsLineRow: View {
    var icon: String?
    var logo: AnyView?
    var title: String
    var value: String?
    var showsChevron = false
    var showsCheck = false
    var tint: Color?
    var isBusy = false
    var action: (() -> Void)?

    init(
        icon: String? = nil,
        logo: AnyView? = nil,
        title: String,
        value: String? = nil,
        showsChevron: Bool = false,
        showsCheck: Bool = false,
        tint: Color? = nil,
        isBusy: Bool = false,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.logo = logo
        self.title = title
        self.value = value
        self.showsChevron = showsChevron
        self.showsCheck = showsCheck
        self.tint = tint
        self.isBusy = isBusy
        self.action = action
    }

    var body: some View {
        if let action {
            Button(action: action) { line }
                .buttonStyle(SettingsRowPressStyle())
        } else {
            line
        }
    }

    private var line: some View {
        HStack(spacing: 14) {
            ZStack {
                if let logo {
                    logo
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(tint ?? LaxifyPalette.textSecondary)
                }
            }
            .frame(width: 24, height: 24)

            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint ?? LaxifyPalette.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 8)

            if isBusy {
                ProgressView().tint(tint ?? LaxifyPalette.textSecondary)
            }

            if let value {
                Text(value)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.75)
            }

            if showsCheck {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(LaxifyPalette.accent)
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textTertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }
}

private struct SettingsRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
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
            SettingsGroup(header: L("account.profile", "Профиль")) {
                Button {
                    UIPasteboard.general.string = user?.username
                    flash(L("account.copied", "Скопировано"))
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "at")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(LaxifyPalette.textSecondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("account.username", "Имя пользователя"))
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(LaxifyPalette.textPrimary)
                            Text("@\(user?.username ?? "")")
                                .font(LaxifyTypography.caption)
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

                Button { isEditPresented = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(LaxifyPalette.textSecondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("account.name", "Имя и фото"))
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(LaxifyPalette.textPrimary)
                            Text(user?.displayName ?? "—")
                                .font(LaxifyTypography.caption)
                                .foregroundStyle(LaxifyPalette.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LaxifyPalette.textTertiary)
                    }
                    .padding(16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            LinkedAccountsCard()

            SettingsGroup(header: L("account.sessions", "Сессии")) {
                SettingsRow(
                    title: L("account.logoutAll", "Выйти на всех устройствах"),
                    description: L("account.logoutAll.sub", "Завершит все сессии, включая эту"),
                    showsChevron: false
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
    /// Where the line starts. Rows with a glyph column pass the width of that
    /// column, so the rule begins under the label rather than under the icon.
    var inset: CGFloat = 16

    var body: some View {
        Rectangle()
            .fill(LaxifyPalette.separator)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}
