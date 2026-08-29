import SwiftUI

/// GIF search for comments. The grid and search bar are built; results come
/// from `GifService`, which returns nothing until a Tenor/Giphy key is set
/// on the backend and the `/gif` proxy exists.
struct GifPickerView: View {
    var onPick: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [GifItem] = []
    @State private var isLoading = false

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        ZStack {
            LaxifyPalette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button(action: { dismiss() }) {
                        Text(L("common.cancel", "Отмена")).glassPill()
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("GIF").font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(LaxifyPalette.textPrimary)
                    Spacer()
                    Color.clear.frame(width: 74, height: 1)
                }
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                .padding(.vertical, 12)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(LaxifyPalette.textTertiary)
                    TextField(L("gif.search", "Поиск GIF"), text: $query)
                        .font(.system(size: 15))
                        .onSubmit { Task { await search() } }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                .padding(.bottom, 10)

                if results.isEmpty {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 30)).foregroundStyle(LaxifyPalette.textTertiary)
                        Text(L("gif.soon", "Поиск GIF подключим вместе с бэкендом"))
                            .font(.system(size: 13))
                            .foregroundStyle(LaxifyPalette.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 40)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(results) { gif in
                                Button { onPick(gif.url) } label: {
                                    AsyncCoverImage(url: gif.previewURL, cornerRadius: 10, displaySize: 320)
                                        .frame(height: 120)
                                        .frame(maxWidth: .infinity)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, LaxifyMetrics.screenPadding)
                        .padding(.bottom, 24)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .task { await search() }
    }

    private func search() async {
        isLoading = true
        defer { isLoading = false }
        results = await GifService.shared.search(query.trimmingCharacters(in: .whitespaces))
    }
}

struct GifItem: Identifiable, Sendable {
    let id: String
    let url: URL          // the full GIF/MP4
    let previewURL: URL   // a small still
}

/// GIF search, proxied through the backend so the API key stays server-side.
actor GifService {
    static let shared = GifService()

    func search(_ query: String) async -> [GifItem] {
        guard let dtos = try? await LaxifyAPI.shared.searchGifs(query) else { return [] }
        return dtos.compactMap { dto in
            guard let url = URL(string: dto.url), let preview = URL(string: dto.previewUrl) else {
                return nil
            }
            return GifItem(id: dto.id, url: url, previewURL: preview)
        }
    }
}
