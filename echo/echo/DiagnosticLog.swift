import Foundation
import AppKit

/// A plain text log that survives quitting, so a problem can be diagnosed without
/// hunting for a crash report.
///
/// If the app dies, the last line written says what it was in the middle of —
/// which is usually enough to place the fault.
enum DiagnosticLog {
    /// Writes happen off the main thread; everything we log is on a hot path.
    private static let queue = DispatchQueue(label: "com.echo.diagnostics", qos: .utility)

    /// Trimmed to roughly this size on launch so it can't grow forever.
    private static let maxBytes = 512 * 1024

    private static let timestampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df
    }()

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("The Yappologist", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("diagnostics.log")
    }

    // MARK: - Writing

    static func write(_ message: String) {
        let line = "\(timestampFormatter.string(from: Date()))  \(message)\n"
        queue.async {
            let url = fileURL
            guard let data = line.data(using: .utf8) else { return }

            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Called once at launch: notes the version and keeps the file from growing
    /// without bound.
    static func startSession() {
        queue.async {
            trim()
        }
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        write("──────── launched · The Yappologist \(short) (build \(build)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    private static func trim() {
        let url = fileURL
        guard let data = try? Data(contentsOf: url), data.count > maxBytes else { return }
        let keep = data.suffix(maxBytes / 2)
        try? Data(keep).write(to: url)
    }

    // MARK: - Reading

    static func recent(lines: Int = 400) -> String {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return "No log yet."
        }
        let all = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return all.suffix(lines).joined(separator: "\n")
    }

    static func clear() {
        queue.async {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    static func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recent(lines: 2000), forType: .string)
    }

    static func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    // MARK: - Formatting helpers

    static func mb(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    static func seconds(since start: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(start))
    }
}
