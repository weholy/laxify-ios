import Foundation

enum AppLogger {
    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("laxify-log.txt")
    }()

    static func log(_ message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withTime, .withColonSeparatorInTime]
        let line = "[\(formatter.string(from: .now))] \(message)\n"

        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    static func readAll() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "Логов пока нет"
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
