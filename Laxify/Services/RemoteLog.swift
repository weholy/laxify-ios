import Foundation
import UIKit

/// Ships what the app is doing to the server.
///
/// A report that something is slow does not say which of the steps between a
/// tap and a sound took the time, and the server is fast from the server. So
/// the app measures each step itself and sends the numbers.
///
/// Batched rather than sent per line: a hundred requests to describe one
/// playback would itself be the slow thing.
actor RemoteLog {
    static let shared = RemoteLog()

    struct Entry: Encodable {
        let at: Date
        let level: String
        let category: String
        let message: String
        let durationMs: Int?
        let context: [String: String]
    }

    /// Ties every line from one launch together, so a slow playback can be
    /// read alongside what happened just before it.
    private let sessionId = UUID().uuidString

    private var pending: [Entry] = []
    private var flushTask: Task<Void, Never>?

    /// Small enough to arrive promptly, large enough that a burst of lines
    /// travels as one request.
    private let batchSize = 25
    private let flushInterval: Duration = .seconds(8)
    private let maxPending = 400

    // MARK: - Writing

    nonisolated func info(_ message: String, category: String = "app", context: [String: String] = [:]) {
        write(level: "info", category: category, message: message, durationMs: nil, context: context)
    }

    nonisolated func warn(_ message: String, category: String = "app", context: [String: String] = [:]) {
        write(level: "warn", category: category, message: message, durationMs: nil, context: context)
    }

    nonisolated func error(_ message: String, category: String = "app", context: [String: String] = [:]) {
        write(level: "error", category: category, message: message, durationMs: nil, context: context)
    }

    /// Records how long something took.
    nonisolated func timing(
        _ message: String,
        milliseconds: Int,
        category: String = "app",
        context: [String: String] = [:]
    ) {
        write(
            level: milliseconds > 3000 ? "warn" : "info",
            category: category,
            message: message,
            durationMs: milliseconds,
            context: context
        )
    }

    private nonisolated func write(
        level: String,
        category: String,
        message: String,
        durationMs: Int?,
        context: [String: String]
    ) {
        let entry = Entry(
            at: Date(),
            level: level,
            category: category,
            message: String(message.prefix(2000)),
            durationMs: durationMs,
            context: context
        )
        Task { await append(entry) }
    }

    private func append(_ entry: Entry) {
        pending.append(entry)

        // Losing the oldest lines beats growing without limit on a device
        // that has been offline for a long time.
        if pending.count > maxPending {
            pending.removeFirst(pending.count - maxPending)
        }

        if pending.count >= batchSize {
            flushTask?.cancel()
            flushTask = nil
            Task { await flush() }
            return
        }

        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }

        flushTask = Task { [flushInterval] in
            try? await Task.sleep(for: flushInterval)
            guard !Task.isCancelled else { return }
            await flush()
        }
    }

    // MARK: - Sending

    func flush() async {
        flushTask = nil

        guard !pending.isEmpty else { return }

        let batch = pending
        pending = []

        let sent = await LaxifyAPI.shared.sendLogs(
            sessionId: sessionId,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            osVersion: await UIDevice.current.systemVersion,
            deviceModel: await UIDevice.current.model,
            entries: batch
        )

        if !sent {
            // Put them back at the front so ordering survives a failure, and
            // try again on the next line rather than in a tight loop.
            pending = batch + pending
            if pending.count > maxPending {
                pending.removeFirst(pending.count - maxPending)
            }
        }
    }
}

/// Measures a sequence of steps and reports each one.
///
/// Built for the case that prompted it: a tap on a track, and the several
/// things that happen before a sound comes out. Each `mark` records the time
/// since the previous one, so the slow step is visible rather than only the
/// slow total.
struct Trace {
    private let name: String
    private let category: String
    private let started: ContinuousClock.Instant
    private var last: ContinuousClock.Instant
    private var context: [String: String]

    init(_ name: String, category: String = "playback", context: [String: String] = [:]) {
        self.name = name
        self.category = category
        self.started = ContinuousClock.now
        self.last = started
        self.context = context
    }

    /// Records a step, timed from the previous one.
    mutating func mark(_ step: String) {
        let now = ContinuousClock.now
        let elapsed = Int((last.duration(to: now)).milliseconds)
        last = now

        RemoteLog.shared.timing(
            "\(name): \(step)",
            milliseconds: elapsed,
            category: category,
            context: context
        )
    }

    /// Records the whole thing. Call once, at the end.
    func finish(_ outcome: String = "готово") {
        let total = Int((started.duration(to: ContinuousClock.now)).milliseconds)

        RemoteLog.shared.timing(
            "\(name): всего (\(outcome))",
            milliseconds: total,
            category: category,
            context: context
        )
    }
}

private extension Duration {
    var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }
}
