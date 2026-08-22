import SwiftUI

/// The state of a track's saved copy, in one tappable glyph.
///
/// A ring that fills as the file arrives and then resolves into a tick — one
/// shape throughout, so the transition reads as the same thing finishing
/// rather than one icon being swapped for another. Tapping starts a download,
/// cancels one in progress, or removes a saved copy.
struct DownloadIndicator: View {
    let song: Song
    var size: CGFloat = 22

    @State private var downloads = DownloadManager.shared
    @State private var tickProgress: CGFloat = 0

    private var status: DownloadManager.Status {
        downloads.status(for: song.id)
    }

    var body: some View {
        Button(action: act) {
            ZStack {
                switch status {
                case .none:
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: size, weight: .regular))
                        .foregroundStyle(LaxifyPalette.textTertiary)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))

                case .downloading(let progress):
                    ring(progress: progress)
                        .transition(.opacity)

                case .downloaded:
                    completed
                        .transition(.opacity)

                case .failed:
                    Image(systemName: "exclamationmark.arrow.circlepath")
                        .font(.system(size: size, weight: .regular))
                        .foregroundStyle(.orange)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
            .frame(width: size + 8, height: size + 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.28), value: statusKey)
        .onChange(of: statusKey) { _, key in
            // The tick draws itself once, when the download completes — not
            // every time the row scrolls back into view.
            guard key == "downloaded" else {
                tickProgress = 0
                return
            }
            withAnimation(.easeOut(duration: 0.32).delay(0.05)) {
                tickProgress = 1
            }
        }
        .onAppear {
            if statusKey == "downloaded" { tickProgress = 1 }
        }
    }

    /// Collapses the status to something comparable, so animations trigger on
    /// a real change of state rather than on every progress tick.
    private var statusKey: String {
        switch status {
        case .none: "none"
        case .downloading: "downloading"
        case .downloaded: "downloaded"
        case .failed: "failed"
        }
    }

    private func ring(progress: Double) -> some View {
        ZStack {
            Circle()
                .stroke(LaxifyPalette.separator, lineWidth: 2)

            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(
                    LaxifyPalette.accent,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: progress)

            // A stop glyph rather than a percentage: at this size a number is
            // unreadable, and the ring already says how far along it is.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(LaxifyPalette.accent)
                .frame(width: size * 0.28, height: size * 0.28)
        }
        .frame(width: size, height: size)
    }

    private var completed: some View {
        ZStack {
            Circle()
                .fill(LaxifyPalette.accent)
                .frame(width: size, height: size)

            Tick()
                .trim(from: 0, to: tickProgress)
                .stroke(
                    Color.white,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
                .frame(width: size * 0.5, height: size * 0.5)
        }
    }

    private func act() {
        switch status {
        case .none, .failed:
            downloads.download(song)
        case .downloading:
            downloads.cancel(song.id)
        case .downloaded:
            downloads.remove(song.id)
        }
    }
}

/// The tick, as a path so it can be drawn progressively.
private struct Tick: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
