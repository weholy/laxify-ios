import SwiftUI

struct QueueView: View {
    var onClose: () -> Void
    var player = AudioPlayerController.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, song in
                        Button {
                            player.playIndex(index)
                        } label: {
                            HStack(spacing: 10) {
                                SongRowView(song: song)

                                if index == player.currentIndex {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(LaxifyPalette.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .trackContextMenu(song: song)
                        .opacity(index == player.currentIndex ? 1 : 0.7)
                    }
                }
                .padding(.horizontal, LaxifyMetrics.screenPadding)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .background(LaxifyPalette.background.ignoresSafeArea())
            .navigationTitle("Очередь")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }
}

#Preview {
    QueueView(onClose: {})
}
