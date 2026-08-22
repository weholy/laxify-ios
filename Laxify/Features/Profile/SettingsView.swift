import SwiftUI

/// Everything about the account that is not the profile itself.
///
/// Grouped into cards with the heading outside and the explanation inside,
/// so a switch is never presented without saying what it does — most of
/// these change what other people can see, which is worth being explicit
/// about rather than leaving to a two-word label.
struct SettingsView: View {
    var onClose: () -> Void

    @State private var session = SessionStore.shared
    @State private var appearance = AppearanceSettings.shared

    @State private var isProfilePublic = true
    @State private var isStatsPublic = false
    @State private var bio = ""
    @State private var savedBio = ""

    @State private var showsEmailSheet = false
    @State private var showsPasswordSheet = false
    @State private var showsSignOutConfirmation = false
    @State private var isSigningOut = false
    @State private var statusMessage: String?

    @FocusState private var isEditingBio: Bool

    private var user: BackendUser? { session.user }

    var body: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 26) {
                        privacySection
                        bioSection
                        accountSection
                        appearanceSection
                        signOutButton
                    }
                    .padding(.horizontal, LaxifyMetrics.screenPadding)
                    .padding(.bottom, 120)
                }
                .scrollDismissesKeyboard(.interactively)
            }

            if let statusMessage {
                toast(statusMessage)
            }
        }
        .task { load() }
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
        .confirmationDialog(
            "Выйти из аккаунта?",
            isPresented: $showsSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Выйти", role: .destructive) { signOut() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Загруженные треки и избранное останутся на сервере")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .frame(width: 38, height: 38)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Настройки")
                .font(LaxifyTypography.headline)
                .foregroundStyle(LaxifyPalette.textPrimary)

            Spacer()

            // Balances the back button so the title sits centred.
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.bottom, 16)
    }

    // MARK: - Sections

    private var privacySection: some View {
        SettingsSection(title: "Конфиденциальность") {
            SettingsToggle(
                title: "Открытый профиль",
                description: "Другие смогут найти вас по имени и увидеть плейлисты",
                isOn: $isProfilePublic
            )
            .onChange(of: isProfilePublic) { _, value in
                save(isProfilePublic: value)
            }

            SettingsDivider()

            SettingsToggle(
                title: "Показывать статистику",
                description: "Сколько вы слушаете и что чаще всего — будет видно в профиле",
                isOn: $isStatsPublic
            )
            .onChange(of: isStatsPublic) { _, value in
                save(isStatsPublic: value)
            }
        }
    }

    private var bioSection: some View {
        SettingsSection(title: "О себе") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Пара строк, которые увидят в вашем профиле")
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textSecondary)

                TextField("Расскажите о себе", text: $bio, axis: .vertical)
                    .font(.system(size: 16))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .lineLimit(2...4)
                    .focused($isEditingBio)

                HStack {
                    Text("\(bio.count) / 160")
                        .font(.system(size: 12))
                        .foregroundStyle(
                            bio.count > 160 ? .red : LaxifyPalette.textTertiary
                        )

                    Spacer()

                    if bio != savedBio {
                        Button("Сохранить") {
                            isEditingBio = false
                            save(bio: String(bio.prefix(160)))
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LaxifyPalette.accent)
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: bio != savedBio)
            }
            .padding(16)
        }
    }

    private var accountSection: some View {
        SettingsSection(title: "Аккаунт") {
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
                description: "Вход по почте без Google"
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

    private var appearanceSection: some View {
        SettingsSection(title: "Дизайн") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Как приложение выглядит на этом устройстве")
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textSecondary)

                Picker("Тема", selection: $appearance.theme) {
                    ForEach(AppearanceSettings.Theme.allCases, id: \.self) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(16)

            SettingsDivider()

            SettingsToggle(
                title: "Плавные переходы",
                description: "Анимации при открытии плеера и переключении экранов",
                isOn: $appearance.animationsEnabled
            )
        }
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
        .padding(.top, 4)
    }

    private func toast(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
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

    // MARK: - Actions

    private func load() {
        guard let user else { return }
        isProfilePublic = user.isProfilePublic
        isStatsPublic = user.isStatsPublic
        bio = user.bio ?? ""
        savedBio = bio
    }

    /// Saves one field. The server treats anything omitted as unchanged, so a
    /// switch does not have to send the whole profile back with it.
    private func save(
        bio: String? = nil,
        isProfilePublic: Bool? = nil,
        isStatsPublic: Bool? = nil
    ) {
        Task {
            let failure = await session.updateProfile(
                bio: bio,
                isProfilePublic: isProfilePublic,
                isStatsPublic: isStatsPublic
            )

            if let failure {
                flash(failure)
                // Put the switches back where the server still has them,
                // rather than showing a state that was not saved.
                load()
            } else if let bio {
                savedBio = bio
                flash("Сохранено")
            }
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
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            statusMessage = message
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.25)) { statusMessage = nil }
        }
    }
}

// MARK: - Building blocks

/// A titled card. The heading sits above the card rather than inside it, so
/// the group reads as a group before any of its rows do.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LaxifyPalette.textSecondary)
                .textCase(.uppercase)
                .kerning(0.4)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                content()
            }
            .background(
                LaxifyPalette.surface,
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
        }
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
