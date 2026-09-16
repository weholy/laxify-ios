import SwiftUI
import PhotosUI

/// "Сообщить об ошибке" — flag something wrong with a specific track: a
/// checklist of the failure modes actually seen (mismatched audio, mismatched
/// lyrics, won't play, …), an optional note and photo, sent to the same
/// diagnostics feed crash reports land in, plus a best-effort Telegram push.
struct ReportTrackSheet: View {
    let song: Song
    var onDone: () -> Void = {}

    @State private var selectedReasons: Set<ReportReason> = []
    @State private var message = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var isSending = false
    @State private var didSend = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        trackHeader
                        reasonList

                        if !selectedReasons.isEmpty {
                            composer
                        }
                    }
                    .padding(.horizontal, LaxifyMetrics.screenPadding)
                    .padding(.top, 4)
                    .padding(.bottom, 32)
                }
            }

            if didSend {
                confirmation
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { photoData = try? await item.loadTransferable(type: Data.self) }
        }
    }

    private var header: some View {
        HStack {
            LaxifyCloseButton(style: .xmark, tinted: false, action: onDone)

            Spacer()

            Text(L("report.title", "Сообщить об ошибке"))
                .font(LaxifyTypography.headline)
                .foregroundStyle(LaxifyPalette.textPrimary)

            Spacer()

            Color.clear.frame(width: LaxifyMetrics.controlSize, height: LaxifyMetrics.controlSize)
        }
        .padding(.horizontal, LaxifyMetrics.screenPadding)
        .padding(.vertical, 14)
    }

    private var trackHeader: some View {
        HStack(spacing: 12) {
            AsyncCoverImage(url: song.coverURL, cornerRadius: LaxifyMetrics.smallCornerRadius, displaySize: 96)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(LaxifyTypography.headline)
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .lineLimit(1)
                Text(song.artistName)
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
    }

    private var reasonList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("report.whatsWrong", "Что не так"))
                .font(LaxifyTypography.subheadline)
                .foregroundStyle(LaxifyPalette.textSecondary)

            VStack(spacing: 1) {
                ForEach(ReportReason.allCases) { reason in
                    reasonRow(reason)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: LaxifyMetrics.cardCornerRadius, style: .continuous))
        }
    }

    private func reasonRow(_ reason: ReportReason) -> some View {
        let isOn = selectedReasons.contains(reason)

        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                if isOn {
                    selectedReasons.remove(reason)
                } else {
                    selectedReasons.insert(reason)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Text(reason.title)
                    .font(LaxifyTypography.body)
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 8)

                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(isOn ? LaxifyPalette.accent : LaxifyPalette.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(LaxifyPalette.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("report.details", "Детали (необязательно)"))
                .font(LaxifyTypography.subheadline)
                .foregroundStyle(LaxifyPalette.textSecondary)

            TextField(L("report.detailsPlaceholder", "Опишите, что заметили"), text: $message, axis: .vertical)
                .font(LaxifyTypography.body)
                .foregroundStyle(LaxifyPalette.textPrimary)
                .lineLimit(3...6)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: LaxifyMetrics.smallCornerRadius, style: .continuous)
                        .fill(LaxifyPalette.surface)
                )

            photoPicker

            Button {
                Task { await send() }
            } label: {
                Group {
                    if isSending {
                        ProgressView().tint(.white)
                    } else {
                        Text(L("report.send", "Отправить"))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.laxifyPrimary)
            .disabled(isSending)

            if let errorMessage {
                Text(errorMessage)
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(.red)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var photoPicker: some View {
        HStack(spacing: 10) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                HStack(spacing: 8) {
                    if let photoData, let uiImage = UIImage(data: photoData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 26, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        Image(systemName: "camera")
                    }
                    Text(photoData == nil ? L("report.attachPhoto", "Прикрепить фото") : L("report.photoAttached", "Фото добавлено"))
                        .font(LaxifyTypography.footnote)
                }
                .foregroundStyle(LaxifyPalette.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .laxGlassCapsule(interactive: true)
            }
            .buttonStyle(.plain)

            if photoData != nil {
                Button {
                    photoData = nil
                    photoItem = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(LaxifyPalette.textTertiary)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }

    private var confirmation: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(LaxifyPalette.accent)
            Text(L("report.sent", "Спасибо, разберёмся"))
                .font(LaxifyTypography.headline)
                .foregroundStyle(LaxifyPalette.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LaxifyPalette.background)
        .transition(.opacity)
    }

    private func send() async {
        isSending = true
        errorMessage = nil

        var uploadedURL: URL?
        if let photoData {
            uploadedURL = try? await LaxifyAPI.shared.uploadMedia(
                photoData, filename: "report.jpg", mimeType: "image/jpeg"
            )
        }

        do {
            try await LaxifyAPI.shared.reportTrack(
                trackId: song.id,
                trackTitle: song.title,
                trackArtist: song.artistName,
                reasons: selectedReasons.map(\.title),
                message: message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : message,
                photoURL: uploadedURL
            )
            isSending = false
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { didSend = true }
            try? await Task.sleep(for: .seconds(1.1))
            onDone()
        } catch {
            isSending = false
            errorMessage = L("report.failed", "Не получилось отправить, попробуйте ещё раз")
        }
    }
}

enum ReportReason: String, CaseIterable, Identifiable {
    case audioMismatch
    case lyricsMismatch
    case notPlaying
    case badQuality
    case wrongInfo
    case other

    var id: String { rawValue }

    @MainActor
    var title: String {
        switch self {
        case .audioMismatch: L("report.reason.audioMismatch", "Трек не совпадает")
        case .lyricsMismatch: L("report.reason.lyricsMismatch", "Текст не совпадает с песней")
        case .notPlaying: L("report.reason.notPlaying", "Не воспроизводится")
        case .badQuality: L("report.reason.badQuality", "Плохое качество звука")
        case .wrongInfo: L("report.reason.wrongInfo", "Неверное название или исполнитель")
        case .other: L("report.reason.other", "Другое")
        }
    }
}

#Preview {
    ReportTrackSheet(song: Song(
        id: "1", title: "Название трека", artistName: "Исполнитель",
        artistId: nil, albumTitle: nil, coverURL: nil, duration: 180
    ))
}
