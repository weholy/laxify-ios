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
}
