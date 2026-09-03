import Foundation

/// The version the app shows people.
///
/// Read from the bundle rather than written out here, so there is one place to
/// change it: `MARKETING_VERSION` in `project.yml` (both targets). The build
/// number is separate and is only interesting in diagnostics.
enum AppVersion {
    /// "1.1" — what the settings footer prints.
    static let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1"

    /// "1" — the build behind that version.
    static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    /// "1.1 (1)" — version and build together, for diagnostics.
    static var full: String { "\(short) (\(build))" }

    /// Whether `short` is older than `floor`, comparing component by
    /// component ("1.10" is newer than "1.9", not smaller).
    ///
    /// An empty or unparseable floor never blocks — "no requirement set" and
    /// "requirement I can't read" have to fail the same safe way, or a typo
    /// in Випка locks out every version at once instead of none.
    static func isOlder(than floor: String) -> Bool {
        let trimmed = floor.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        let mine = short.split(separator: ".").compactMap { Int($0) }
        let required = trimmed.split(separator: ".").compactMap { Int($0) }
        guard !mine.isEmpty, !required.isEmpty else { return false }

        for index in 0..<max(mine.count, required.count) {
            let a = index < mine.count ? mine[index] : 0
            let b = index < required.count ? required[index] : 0
            if a != b { return a < b }
        }
        return false
    }
}
