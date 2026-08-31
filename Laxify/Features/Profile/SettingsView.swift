import SwiftUI
import PhotosUI
import UIKit

/// Settings, as one page: who you are at the top, then three short blocks —
/// the account, what the app does, and the two things you can act on.
///
/// Nothing here opens a screen to change one word. The name and the handle go
/// through the system's own rename alert, so the list you were reading is
/// still behind it.
struct SettingsView: View {
    var onClose: () -> Void

    @Environment(\.openURL) private var openURL

    @State private var session = SessionStore.shared
    var localization = LocalizationManager.shared
    var interface = InterfaceSettings.shared
    var background = ProfileBackgroundStore.shared

    @State private var showsSignOutConfirmation = false
    @State private var isSigningOut = false
    @State private var avatarItem: PhotosPickerItem?
    @State private var backgroundItem: PhotosPickerItem?
    @State private var isUploadingAvatar = false
    @State private var linked: LaxifyAPI.LinkedMethodsDTO?
    @State private var status: String?

    private var user: BackendUser? { session.user }

    /// The screens that still earn one.
    private enum Page: String, Identifiable {
        case language
        case privacy
        case admin
        case export
        case diagnostics
        case info

        var id: String { rawValue }
    }

    /// The one-line things, edited in the system's rename alert.
    private enum Field: String, Identifiable {
        case username
        case name

        var id: String { rawValue }
    }

    @State private var page: Page?
    @State private var field: Field?
    @State private var draft = ""

    var body: some View {
        ZStack(alignment: .top) {
            LaxifyPalette.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    identity
                        .padding(.bottom, 6)

                    accountGroup
                    preferencesGroup
                    actionsGroup

                    footer
                        .padding(.top, 22)
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
        .onChange(of: backgroundItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    background.set(data)
                }
                backgroundItem = nil
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
        .alert(
            field.map { title($0) } ?? "",
            isPresented: Binding(get: { field != nil }, set: { if !$0 { field = nil } }),
            presenting: field
        ) { entry in
            TextField(placeholder(entry), text: $draft)
                .textInputAutocapitalization(entry == .username ? .never : .words)
                .autocorrectionDisabled(entry == .username)

            Button(L("common.cancel", "Отмена"), role: .cancel) {}
            Button(L("common.save", "Сохранить")) { save(entry) }
        } message: { entry in
            Text(hint(entry))
        }
        .fullScreenCover(item: $page) { entry in
            switch entry {
            case .language:
                LanguageSettingsView { page = nil }
            case .privacy:
                PrivacySettingsView { page = nil }
            case .admin:
                AdminPanelView { page = nil }
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
                        // Grey and small: a badge on a photograph is a hint,
                        // not the loudest thing on the page.
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 26, height: 26)
                            .background(Color(white: 0.28), in: Circle())
                            .overlay {
                                Circle().stroke(LaxifyPalette.background, lineWidth: 2)
                            }
                            .contentShape(Circle())
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

            // The name under the picture is the control for changing it —
            // the pencil next to a second name would say the same thing twice.
            Button {
                draft = user?.displayName ?? ""
                field = .name
            } label: {
                VStack(spacing: 3) {
                    HStack(spacing: 6) {
                        Text(user?.displayName ?? "")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(LaxifyPalette.textPrimary)
                            .lineLimit(1)

                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(LaxifyPalette.textTertiary)
                    }

                    Text("@\(user?.username ?? "")")
                        .font(LaxifyTypography.subheadline)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
            // Without an identity of its own `AsyncImage` keeps the picture it
            // already fetched, which is why a new avatar used to appear only
            // after leaving the screen and coming back.
            .id(url)
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
            ) {
                draft = user?.username ?? ""
                field = .username
            }

            SettingsDivider(inset: Self.rowLabelInset)

            SettingsLineRow(
                icon: "envelope",
                title: L("settings.email", "Почта"),
                maskedValue: user?.email
            )

            SettingsDivider(inset: Self.rowLabelInset)

            SettingsLineRow(
                logo: signIn.logo,
                title: signIn.title,
                subtitle: L("settings.signedIn.value", "Вход выполнен")
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

            PhotosPicker(selection: $backgroundItem, matching: .images) {
                SettingsLineRow(
                    icon: "photo",
                    title: L("settings.background", "Фон профиля"),
                    value: background.image == nil
                        ? L("settings.background.none", "Нет")
                        : L("settings.background.set", "Свой"),
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)
            .contextMenu {
                if background.image != nil {
                    Button(L("profile.bg.remove", "Убрать фон"), role: .destructive) {
                        background.clear()
                    }
                }
            }

            SettingsDivider(inset: Self.rowLabelInset)

            SettingsLineRow(
                icon: "textformat.size",
                title: L("settings.hideLabels", "Скрыть подписи в панели"),
                toggle: Binding(
                    get: { interface.hideTabLabels },
                    set: { interface.hideTabLabels = $0 }
                )
            )

            SettingsDivider(inset: Self.rowLabelInset)

            SettingsLineRow(
                icon: "lock",
                title: L("settings.privacy", "Конфиденциальность"),
                showsChevron: true
            ) { page = .privacy }
        }
    }

    private var actionsGroup: some View {
        SettingsCard {
            // Only an operator sees this, and only because the server says so
            // — the flag comes down on the profile, not out of a list of
            // addresses baked into the app.
            if user?.isAdmin == true {
                SettingsLineRow(
                    icon: "crown",
                    title: L("settings.admin", "VIP-панель"),
                    showsChevron: true,
                    tint: Color(hex: 0xFFD60A)
                ) { page = .admin }

                SettingsDivider(inset: Self.rowLabelInset)
            }

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
                "Telegram"
            )
        case "email":
            return (
                AnyView(
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.accent)
                ),
                L("settings.email", "Почта")
            )
        default:
            return (AnyView(GoogleLogoView(size: 20)), "Google")
        }
    }

    /// Dividers start where the labels do, not under the glyphs.
    private static let rowLabelInset: CGFloat = 52

    private var footer: some View {
        HStack(spacing: 7) {
            // A long press here is the way back into the diagnostics log,
            // which has no business taking a row of its own.
            Text("Laxify v \(AppVersion.short) (Beta)")
                .onLongPressGesture(minimumDuration: 1.2) { page = .diagnostics }

            Text("·")

            Button {
                openURL(AppLinks.contact)
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

    // MARK: - The rename alert

    private func title(_ entry: Field) -> String {
        switch entry {
        case .username: L("settings.username", "Юзернейм")
        case .name: L("settings.name", "Имя")
        }
    }

    private func hint(_ entry: Field) -> String {
        switch entry {
        case .username: L("settings.username.hint", "По нему вас находят в поиске")
        case .name: L("settings.name.hint", "Так вас видят на вашей странице")
        }
    }

    private func placeholder(_ entry: Field) -> String {
        switch entry {
        case .username: "username"
        case .name: L("settings.name", "Имя")
        }
    }

    private func save(_ entry: Field) {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2 else { return }

        Task {
            let failure: String?
            switch entry {
            case .username:
                failure = await session.updateProfile(username: value.lowercased())
            case .name:
                failure = await session.updateProfile(displayName: value)
            }
            flash(failure ?? L("privacy.saved", "Сохранено"))
        }
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
            } else {
                // The server is the authority on what the record now says;
                // pulling it back is what makes every screen agree at once.
                await session.refreshUser()
                flash(L("settings.photo.saved", "Фото обновлено"))
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
/// currently set to. A `subtitle` stacks under the title instead — for the
/// sign-in row, where "Вход выполнен" is a state and not a value you set.
/// Rows without an action are read-only and don't highlight.
private struct SettingsLineRow: View {
    var icon: String?
    var logo: AnyView?
    var title: String
    var subtitle: String?
    var value: String?
    /// Shown as dots until tapped. For the address, which is the one thing on
    /// this page worth not leaving open on a screen.
    var maskedValue: String?
    var showsChevron = false
    var tint: Color?
    var isBusy = false
    var toggle: Binding<Bool>?
    var action: (() -> Void)?

    init(
        icon: String? = nil,
        logo: AnyView? = nil,
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        maskedValue: String? = nil,
        showsChevron: Bool = false,
        tint: Color? = nil,
        isBusy: Bool = false,
        toggle: Binding<Bool>? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.logo = logo
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.maskedValue = maskedValue
        self.showsChevron = showsChevron
        self.tint = tint
        self.isBusy = isBusy
        self.toggle = toggle
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
        HStack(spacing: 12) {
            ZStack {
                if let logo {
                    logo
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(tint ?? LaxifyPalette.textSecondary)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint ?? LaxifyPalette.textPrimary)
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(LaxifyPalette.textSecondary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            if isBusy {
                ProgressView().tint(tint ?? LaxifyPalette.textSecondary)
            }

            if let maskedValue {
                MaskedValue(value: maskedValue)
            }

            if let value {
                Text(value)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.75)
            }

            if let toggle {
                Toggle("", isOn: toggle)
                    .labelsHidden()
                    .tint(LaxifyPalette.accent)
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textTertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, subtitle == nil ? 13 : 11)
        .contentShape(Rectangle())
    }
}

/// A value under a lid — dots until you tap it, the text after.
///
/// The same idea as Telegram's spoiler, for the same reason: an address is
/// readable over a shoulder, and nothing on this page needs to be.
private struct MaskedValue: View {
    let value: String

    @State private var isRevealed = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isRevealed.toggle() }
        } label: {
            Group {
                if isRevealed {
                    Text(value)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .minimumScaleFactor(0.7)
                } else {
                    HStack(spacing: 3) {
                        ForEach(0..<dotCount, id: \.self) { _ in
                            Circle()
                                .fill(LaxifyPalette.textSecondary)
                                .frame(width: 4, height: 4)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Enough dots to read as hidden text, never so many that they crowd the
    /// label — the real length is not worth leaking either.
    private var dotCount: Int { min(max(value.count, 8), 12) }
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
