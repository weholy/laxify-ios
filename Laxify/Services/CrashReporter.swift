import Foundation
import UIKit

/// Captures failures and ships them to the server.
///
/// A crash on someone else's phone is otherwise only knowable through a
/// description of what they saw. This records the last breadcrumbs plus a
/// stack trace to disk immediately — a crashing process has no time to make a
/// network call — and uploads whatever it finds on the next launch.
enum CrashReporter {
    private static let pendingKey = "laxify.crash.pending"
    private static let breadcrumbsKey = "laxify.crash.breadcrumbs"
    private static let maxBreadcrumbs = 40

    private struct PendingReport: Codable {
        let kind: String
        let message: String
        let detail: String?
        let occurredAt: Date
        let breadcrumbs: [String]
    }

    // MARK: - Setup

    static func install() {
        // Uncaught Swift/ObjC exceptions.
        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.store(
                kind: "crash",
                message: exception.reason ?? exception.name.rawValue,
                detail: exception.callStackSymbols.joined(separator: "\n")
            )
        }

        // Fatal signals. Handlers run in a constrained context, so this does
        // the minimum: write the record and let the default handler finish
        // the job.
        for signalCode in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            signal(signalCode) { code in
                CrashReporter.store(
                    kind: "crash",
                    message: "Сигнал \(code)",
                    detail: Thread.callStackSymbols.joined(separator: "\n")
                )
                signal(code, SIG_DFL)
                raise(code)
            }
        }

        Task { await uploadPending() }
    }

    // MARK: - Recording

    /// Adds a breadcrumb — cheap enough to call liberally, and the difference
    /// between "it crashed" and "it crashed right after X".
    static func breadcrumb(_ text: String) {
        var trail = UserDefaults.standard.stringArray(forKey: breadcrumbsKey) ?? []
        let stamp = ISO8601DateFormatter().string(from: Date())
        trail.append("\(stamp) \(text)")

        if trail.count > maxBreadcrumbs {
            trail.removeFirst(trail.count - maxBreadcrumbs)
        }
        UserDefaults.standard.set(trail, forKey: breadcrumbsKey)
    }

    /// Reports a caught error that did not bring the app down.
    static func report(_ message: String, detail: String? = nil) {
        store(kind: "error", message: message, detail: detail)
        Task { await uploadPending() }
    }

    private static func store(kind: String, message: String, detail: String?) {
        let report = PendingReport(
            kind: kind,
            message: message,
            detail: detail,
            occurredAt: Date(),
            breadcrumbs: UserDefaults.standard.stringArray(forKey: breadcrumbsKey) ?? []
        )

        var queued = loadPending()
        queued.append(report)
        // Only the most recent handful matter; older ones describe a build
        // that has probably already been replaced.
        if queued.count > 10 {
            queued.removeFirst(queued.count - 10)
        }

        if let data = try? JSONEncoder().encode(queued) {
            UserDefaults.standard.set(data, forKey: pendingKey)
            // Force it out now: a crashing process may not get another chance.
            UserDefaults.standard.synchronize()
        }
    }

    private static func loadPending() -> [PendingReport] {
        guard let data = UserDefaults.standard.data(forKey: pendingKey),
              let reports = try? JSONDecoder().decode([PendingReport].self, from: data) else {
            return []
        }
        return reports
    }

    // MARK: - Upload

    static func uploadPending() async {
        let queued = loadPending()
        guard !queued.isEmpty else { return }

        var delivered: [Int] = []

        for (index, report) in queued.enumerated() {
            let sent = await send(report)
            if sent { delivered.append(index) }
        }

        guard !delivered.isEmpty else { return }

        let remaining = queued.enumerated()
            .filter { !delivered.contains($0.offset) }
            .map(\.element)

        if let data = try? JSONEncoder().encode(remaining) {
            UserDefaults.standard.set(data, forKey: pendingKey)
        }
    }

    private static func send(_ report: PendingReport) async -> Bool {
        struct Body: Encodable {
            let kind: String
            let message: String
            let detail: String?
            let appVersion: String?
            let osVersion: String
            let deviceModel: String
            let occurredAt: Date
            let context: [String: String]
        }

        let device = await MainActor.run { UIDevice.current.model }
        let system = await MainActor.run { UIDevice.current.systemVersion }

        let body = Body(
            kind: report.kind,
            message: report.message,
            detail: report.detail,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            osVersion: system,
            deviceModel: device,
            occurredAt: report.occurredAt,
            context: ["breadcrumbs": report.breadcrumbs.joined(separator: "\n")]
        )

        return await LaxifyAPI.shared.submitDiagnostic(body)
    }
}
