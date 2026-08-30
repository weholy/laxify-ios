import SwiftUI
import WidgetKit

/// A plain shortcut to the app — the Laxify mark, on the Lock Screen or the
/// Home Screen. Tapping it opens the app. No timeline: nothing here changes.
struct LaxifyLogoWidget: Widget {
    let kind = "LaxifyLogoWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LogoProvider()) { _ in
            LaxifyLogoView()
                .widgetURL(URL(string: "laxify://open"))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Laxify")
        .description("Открыть Laxify")
        .supportedFamilies([.accessoryCircular, .systemSmall])
    }
}

struct LogoEntry: TimelineEntry {
    let date: Date
}

struct LogoProvider: TimelineProvider {
    func placeholder(in context: Context) -> LogoEntry { LogoEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (LogoEntry) -> Void) {
        completion(LogoEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LogoEntry>) -> Void) {
        // One entry, never refreshed — a logo doesn't have a schedule.
        completion(Timeline(entries: [LogoEntry(date: .now)], policy: .never))
    }
}

private struct LaxifyLogoView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image("WidgetLogo")
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            }
        default:
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.09, green: 0.09, blue: 0.12), .black],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image("WidgetLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 68, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }
}
