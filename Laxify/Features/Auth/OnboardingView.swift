import SwiftUI
import PhotosUI

struct OnboardingView: View {
    let profile: UserProfile
    var onFinished: () -> Void

    @State private var name: String
    @State private var username: String
    @State private var includesBirthdate: Bool
    @State private var birthdate: Date
    @State private var avatarItem: PhotosPickerItem?
    @State private var avatarData: Data?
    @State private var appear = false

    init(profile: UserProfile, onFinished: @escaping () -> Void) {
        self.profile = profile
        self.onFinished = onFinished
        _name = State(initialValue: profile.displayName)
        _username = State(initialValue: profile.username)
        _includesBirthdate = State(initialValue: profile.birthdate != nil)
        _birthdate = State(initialValue: profile.birthdate ?? Calendar.current.date(byAdding: .year, value: -18, to: .now) ?? .now)
        _avatarData = State(initialValue: profile.avatarData)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canContinue: Bool { !trimmedName.isEmpty && !trimmedUsername.isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: LaxifyMetrics.sectionSpacing) {
                header
                avatarPicker
                fieldsSection
                birthdateSection
                continueButton
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .background(LaxifyPalette.background.ignoresSafeArea())
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                appear = true
            }
        }
        .task(id: avatarItem) {
            guard let avatarItem, let data = try? await avatarItem.loadTransferable(type: Data.self) else { return }
            avatarData = data
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Расскажи о себе")
                .font(LaxifyTypography.largeTitle)
                .foregroundStyle(LaxifyPalette.textPrimary)
            Text("Это займёт меньше минуты")
                .font(LaxifyTypography.body)
                .foregroundStyle(LaxifyPalette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(appear ? 1 : 0)
    }

    private var avatarPicker: some View {
        PhotosPicker(selection: $avatarItem, matching: .images) {
            ZStack(alignment: .bottomTrailing) {
                avatarImage
                    .frame(width: 108, height: 108)
                    .clipShape(Circle())

                Image(systemName: "camera.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(LaxifyPalette.accent, in: Circle())
                    .overlay(Circle().stroke(LaxifyPalette.background, lineWidth: 3))
            }
        }
        .buttonStyle(.plain)
        .opacity(appear ? 1 : 0)
    }

    @ViewBuilder
    private var avatarImage: some View {
        if let avatarData, let uiImage = UIImage(data: avatarData) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else if let url = profile.googleAvatarURL {
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
                    .font(.system(size: 36))
                    .foregroundStyle(LaxifyPalette.textTertiary)
            }
    }

    private var fieldsSection: some View {
        VStack(spacing: 12) {
            labeledField(title: "Имя", text: $name, placeholder: "Имя")
            labeledField(title: "Юзернейм", text: $username, placeholder: "username", prefix: "@")
        }
        .opacity(appear ? 1 : 0)
    }

    private func labeledField(title: String, text: Binding<String>, placeholder: String, prefix: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(LaxifyTypography.footnote)
                .foregroundStyle(LaxifyPalette.textSecondary)

            HStack(spacing: 4) {
                if let prefix {
                    Text(prefix)
                        .foregroundStyle(LaxifyPalette.textTertiary)
                }
                TextField(placeholder, text: text)
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .autocorrectionDisabled(prefix != nil)
                    .textInputAutocapitalization(prefix != nil ? .never : .words)
            }
            .font(LaxifyTypography.body)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .laxGlassCapsule()
        }
    }

    private var birthdateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $includesBirthdate.animation(.easeInOut(duration: 0.2))) {
                Text("Указать дату рождения")
                    .font(LaxifyTypography.body)
                    .foregroundStyle(LaxifyPalette.textPrimary)
            }
            .tint(LaxifyPalette.accent)

            if includesBirthdate {
                DatePicker("", selection: $birthdate, displayedComponents: .date)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .laxGlassCard()
        .opacity(appear ? 1 : 0)
    }

    private var continueButton: some View {
        Button {
            save()
        } label: {
            Text("Готово")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.laxifyPrimary)
        .disabled(!canContinue)
        .opacity(canContinue ? 1 : 0.5)
        .opacity(appear ? 1 : 0)
    }

    private func save() {
        profile.displayName = trimmedName
        profile.username = trimmedUsername
        profile.birthdate = includesBirthdate ? birthdate : nil
        profile.avatarData = avatarData
        profile.hasCompletedOnboarding = true
        onFinished()
    }
}
