import SwiftUI

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
        case privacy
        case about
        case account
        case appearance
        case export

        var id: String { rawValue }

        var title: String {
            switch self {
            case .privacy: "Конфиденциальность"
            case .about: "О себе"
            case .account: "Аккаунт"
            case .appearance: "Дизайн"
            case .export: "Выгрузка артистов"
            }
        }

        var subtitle: String {
            switch self {
            case .privacy: "Кто видит ваш профиль и что вы слушаете"
            case .about: "Пара строк для вашей страницы"
            case .account: "Почта, пароль, имя"
            case .appearance: "Светлая или тёмная тема"
            case .export: "Список исполнителей файлом"
            }
        }

    }

    @State private var page: Page?

    var body: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                SettingsHeader(title: "Настройки", onBack: onClose)

                ScrollView {
                    VStack(spacing: 12) {
                        ForEach([Page.privacy, .about, .account, .appearance, .export]) { entry in
                            entryRow(entry)
                        }

                        signOutButton
                            .padding(.top, 16)
                    }
                    .padding(.horizontal, LaxifyMetrics.screenPadding)
                    .padding(.bottom, 120)
                }
            }
        }
        .fullScreenCover(item: $page) { entry in
            switch entry {
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
            }
        }
        .confirmationDialog(
            "Точно хотите выйти?",
            isPresented: $showsSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Выйти", role: .destructive) { signOut() }
            Button("Остаться", role: .cancel) {}
        }
    }

    private func entryRow(_ entry: Page) -> some View {
        Button {
            page = entry
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(LaxifyPalette.textPrimary)

                    Text(entry.subtitle)
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(LaxifyPalette.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textTertiary)
            }
            .padding(16)
            .background(
                LaxifyPalette.surface,
                in: RoundedRectangle(cornerRadius: 32, style: .continuous)
            )
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
                Text(isSigningOut ? "Выходим…" : "Выйти из аккаунта")
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
        SettingsPage(title: "Конфиденциальность", status: status, onBack: onBack) {
            SettingsCard {
                SettingsToggle(
                    title: "Открытый профиль",
                    description: "Вас смогут найти по имени и увидеть ваши плейлисты",
                    isOn: $isProfilePublic
                )
                .onChange(of: isProfilePublic) { _, value in
                    save(isProfilePublic: value)
                }

                SettingsDivider()

                SettingsToggle(
                    title: "Показывать, что слушаю",
                    description: "Сколько вы слушаете и какие треки — будет видно в профиле",
                    isOn: $isStatsPublic
                )
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
                flash("Сохранено")
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
        SettingsPage(title: "О себе", status: status, onBack: onBack) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Эти строки увидят те, кто откроет ваш профиль")
                        .font(LaxifyTypography.footnote)
                        .foregroundStyle(LaxifyPalette.textSecondary)

                    TextField("Расскажите о себе", text: $bio, axis: .vertical)
                        .font(.system(size: 16))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                        .lineLimit(3...6)
                        .focused($isEditing)

                    Text("\(bio.count) из \(limit)")
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
                    Text("Сохранить")
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
                flash("Сохранено")
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
    @State private var showsEmailSheet = false
    @State private var showsPasswordSheet = false
    @State private var status: String?

    private var user: BackendUser? { session.user }

    var body: some View {
        SettingsPage(title: "Аккаунт", status: status, onBack: onBack) {
            SettingsCard {
                SettingsRow(
                    title: "Почта",
                    description: user?.email ?? "—",
                    badge: (user?.emailVerified ?? false) ? nil : "не подтверждена"
                ) {
                    showsEmailSheet = true
                }

                SettingsDivider()

                SettingsRow(
                    title: "Пароль",
                    description: (user?.hasPassword ?? false)
                        ? "Можно сменить в любой момент"
                        : "Задайте, чтобы входить по почте"
                ) {
                    showsPasswordSheet = true
                }

                SettingsDivider()

                SettingsRow(
                    title: "Имя пользователя",
                    description: "@\(user?.username ?? "")",
                    showsChevron: false
                ) {}
            }
        }
        .sheet(isPresented: $showsEmailSheet) {
            EmailBindingSheet { message in
                showsEmailSheet = false
                flash(message)
            }
        }
        .sheet(isPresented: $showsPasswordSheet) {
            PasswordChangeSheet { message in
                showsPasswordSheet = false
                flash(message)
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

// MARK: - Appearance

struct AppearanceSettingsView: View {
    var onBack: () -> Void

    @State private var appearance = AppearanceSettings.shared

    var body: some View {
        SettingsPage(title: "Дизайн", status: nil, onBack: onBack) {
            VStack(spacing: 12) {
                ForEach(AppearanceSettings.Theme.allCases, id: \.self) { theme in
                    themeRow(theme)
                }
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
            .background(
                LaxifyPalette.surface,
                in: RoundedRectangle(cornerRadius: 32, style: .continuous)
            )
            .overlay {
                // The outline alone says which one is chosen. A tick as well
                // was saying it twice, and in a colour that belonged to
                // nothing else on the screen.
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(
                        isSelected ? LaxifyPalette.selectionOutline : .clear,
                        lineWidth: isSelected ? 2 : 0
                    )
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
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
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
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .frame(width: 38, height: 38)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(title)
                .font(LaxifyTypography.headline)
                .foregroundStyle(LaxifyPalette.textPrimary)

            Spacer()

            // Balances the back button so the title sits centred.
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.bottom, 16)
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
            in: RoundedRectangle(cornerRadius: 32, style: .continuous)
        )
    }
}

struct SettingsToggle: View {
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(LaxifyPalette.textPrimary)

                Text(description)
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
