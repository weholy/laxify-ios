import SwiftUI
import SwiftData

/// The Избранное tab, now a two-part library: liked tracks and playlists,
/// switched with a segmented control.
struct LibraryView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case tracks
        case playlists
        var id: String { rawValue }

        var titleKey: String { self == .tracks ? "library.tracks" : "library.playlists" }
        var fallback: String { self == .tracks ? "Треки" : "Плейлисты" }
    }

    @State private var segment: Segment = .tracks
    @Namespace private var segmentNamespace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Segment.allCases) { option in
                    let isOn = segment == option
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { segment = option }
                    } label: {
                        Text(L(option.titleKey, option.fallback))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isOn ? LaxifyPalette.textPrimary : LaxifyPalette.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background {
                                if isOn {
                                    Capsule()
                                        .fill(LaxifyPalette.surfaceElevated)
                                        .matchedGeometryEffect(id: "librarySegment", in: segmentNamespace)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(LaxifyPalette.surface, in: Capsule())
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.top, 12)
            .padding(.bottom, 8)

            switch segment {
            case .tracks:
                FavoritesView()
            case .playlists:
                PlaylistsView()
            }
        }
        .background(LaxifyPalette.background)
    }
}

struct PlaylistsView: View {
    var store = PlaylistStore.shared

    @State private var selected: PlaylistDTO?
    @State private var isCreatePresented = false

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                NewPlaylistCard { isCreatePresented = true }

                ForEach(store.playlists) { playlist in
                    Button { selected = playlist } label: {
                        PlaylistCard(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.top, 6)
            .padding(.bottom, LaxifyMetrics.tabBarHeight + LaxifyMetrics.miniPlayerHeight + 40)

            if store.playlists.isEmpty && !store.isLoading {
                Text(L("library.empty", "Создайте плейлист и складывайте в него треки —\nиз плеера или долгим нажатием на трек"))
                    .font(LaxifyTypography.footnote)
                    .foregroundStyle(LaxifyPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
        }
        .background(LaxifyPalette.background)
        .task { await store.loadIfNeeded() }
        .refreshable { await store.reload() }
        .fullScreenCover(item: $selected) { playlist in
            UserPlaylistView(playlist: playlist) { selected = nil }
        }
        .sheet(isPresented: $isCreatePresented) {
            CreatePlaylistSheet { isCreatePresented = false }
        }
    }
}

struct PlaylistCard: View {
    let playlist: PlaylistDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cover
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

            Text(playlist.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LaxifyPalette.textPrimary)
                .lineLimit(1)

            Text("\(playlist.trackCount) \(Self.tracksWord(playlist.trackCount))")
                .font(LaxifyTypography.caption)
                .foregroundStyle(LaxifyPalette.textSecondary)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var cover: some View {
        if let url = playlist.coverURL {
            AsyncCoverImage(url: url, cornerRadius: 24, displaySize: 240)
        } else {
            let seed = playlist.id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
            let hue = Double(seed % 360) / 360
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.55, brightness: 0.8),
                    Color(hue: (hue + 0.1).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.45)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .overlay {
                Image(systemName: "music.note.list")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    @MainActor
    static func tracksWord(_ n: Int) -> String {
        guard LocalizationManager.shared.language == .ru else {
            return L("unit.tracks", "треков")
        }
        let r10 = n % 10, r100 = n % 100
        if r10 == 1, r100 != 11 { return "трек" }
        if (2...4).contains(r10), !(12...14).contains(r100) { return "трека" }
        return "треков"
    }
}

struct NewPlaylistCard: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(LaxifyPalette.surface)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                            .foregroundStyle(LaxifyPalette.textTertiary)
                    }
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(LaxifyPalette.textSecondary)
                    }

                Text(L("library.newPlaylist", "Новый плейлист"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LaxifyPalette.textPrimary)
                    .lineLimit(1)

                Text("·")
                    .font(LaxifyTypography.caption)
                    .foregroundStyle(.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    LibraryView()
}
