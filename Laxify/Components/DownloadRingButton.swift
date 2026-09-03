import SwiftUI

/// Save-for-offline, as one control that says where it has got to.
///
/// Idle it is an arrow. Running, the arrow gives way to the percentage and a
/// ring closes around the rim — the ring *is* the progress bar, so nothing
/// else on the screen has to move to make room for one. Done, a filled tick.
struct DownloadRingButton: View {
    /// 0…1 while a download is running, nil when nothing is.
    var progress: Double?
    /// Whether everything this button covers is already on the device.
    var isDone: Bool
    var diameter: CGFloat = 52
    var action: () -> Void

    private var percent: Int { Int(((progress ?? 0) * 100).rounded()) }

    var body: some View {
        Button(action: action) {
            ZStack {
                if progress != nil {
                    Circle()
                        .stroke(LaxifyPalette.separator, lineWidth: 2.5)
                        .padding(3)

                    Circle()
                        // A sliver even at zero, so the ring reads as started
                        // rather than as broken.
                        .trim(from: 0, to: max(0.015, progress ?? 0))
                        .stroke(
                            LaxifyPalette.accent,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .padding(3)
                        .animation(.linear(duration: 0.3), value: progress)

                    Text("\(percent)%")
                        .font(.system(size: 12, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(LaxifyPalette.textPrimary)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.2), value: percent)
                } else {
                    Image(systemName: isDone ? "checkmark.circle.fill" : "arrow.down")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isDone ? LaxifyPalette.accent : LaxifyPalette.textPrimary)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: diameter, height: diameter)
            .glassEffect(.regular.interactive(), in: .circle)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDone)
        .animation(.easeInOut(duration: 0.2), value: progress == nil)
    }
}

/// A round glass button around a single glyph. The favourites row is three of
/// these, and nothing else needed inventing for it.
struct CircleGlassButton: View {
    let systemImage: String
    var diameter: CGFloat = 52
    var glyphSize: CGFloat = 19
    var tint: Color?
    var accessibilityLabel: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            glyph
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Two branches rather than one expression: the glass value's type has no
    /// name worth writing here, and a conditional inside the call cannot be
    /// inferred from a leading dot.
    @ViewBuilder
    private var glyph: some View {
        let image = Image(systemName: systemImage)
            .font(.system(size: glyphSize, weight: .semibold))
            .foregroundStyle(tint == nil ? LaxifyPalette.textPrimary : .white)
            .frame(width: diameter, height: diameter)

        if let tint {
            image.glassEffect(.regular.tint(tint).interactive(), in: .circle)
        } else {
            image.glassEffect(.regular.interactive(), in: .circle)
        }
    }
}

/// The long-press menu a track carries wherever it is listed: keep it on the
/// device, or take it out of the list it is sitting in.
struct TrackContextMenu: ViewModifier {
    let song: Song
    /// What "remove" means here. Nil leaves the option out — a downloads
    /// list, for instance, removes by deleting the file.
    var removeTitle: String?
    var onRemove: (() -> Void)?

    var downloads = DownloadManager.shared

    func body(content: Content) -> some View {
        content.contextMenu {
            if downloads.isDownloaded(song.id) {
                Button(role: .destructive) {
                    downloads.remove(song.id)
                } label: {
                    Label(L("download.remove", "Удалить загрузку"), systemImage: "trash")
                }
            } else if downloads.isDownloading(song.id) {
                Button {
                    downloads.remove(song.id)
                } label: {
                    Label(L("download.cancel", "Отменить загрузку"), systemImage: "xmark")
                }
            } else {
                Button {
                    downloads.download(song)
                } label: {
                    Label(L("download.save", "Скачать"), systemImage: "arrow.down.circle")
                }
            }

            if let onRemove, let removeTitle {
                Button(role: .destructive, action: onRemove) {
                    Label(removeTitle, systemImage: "minus.circle")
                }
            }
        }
    }
}

extension View {
    func trackContextMenu(
        song: Song,
        removeTitle: String? = nil,
        onRemove: (() -> Void)? = nil
    ) -> some View {
        modifier(TrackContextMenu(song: song, removeTitle: removeTitle, onRemove: onRemove))
    }
}

/// The press Apple Music gives its transport controls.
///
/// A plain scale-down reads as the button shrinking. A spring that undershoots
/// and comes back past its resting size reads as something physical being
/// pushed — which is why the response is short and the damping low. The
/// numbers are the point: slower or better-damped and it stops feeling like a
/// button at all.
struct SquashButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(
                .interpolatingSpring(stiffness: 420, damping: 17),
                value: configuration.isPressed
            )
    }
}
