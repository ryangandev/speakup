#if DEBUG
import Foundation
import Observation

/// Debug builds only, `-debug.speechLog`: every utterance and tone the drive plays, with its
/// drive-clock time, so a UI test can assert on what was said without hearing it.
///
/// Task 6 shows `text` in a Debug-only `drive.spokenLog` element. The same lines are
/// appended to `drive-spoken-log.txt` in the app's temporary directory; the file starts
/// empty for each log.
///
/// Lines look like `12.34 say: What worked: you answered first.`, `13.10 tone: start recording`
/// and `14.00 cancelled`.
@MainActor
@Observable
final class SpokenLog {
    enum Kind: Sendable, Equatable {
        case speech, tone, cancelled
    }

    struct Entry: Sendable, Equatable, Identifiable {
        let id: Int
        let kind: Kind
        let text: String
        /// Seconds on the drive clock when it starts playing.
        let time: TimeInterval

        var line: String {
            let stamp = String(format: "%.2f", time)
            switch kind {
            case .speech: return "\(stamp) say: \(text)"
            case .tone: return "\(stamp) tone: \(text)"
            case .cancelled: return "\(stamp) cancelled"
            }
        }
    }

    nonisolated static var defaultFileURL: URL {
        FileManager.default.temporaryDirectory.appending(path: "drive-spoken-log.txt")
    }

    private(set) var entries: [Entry] = []
    @ObservationIgnored let fileURL: URL?

    /// The log as one line per entry.
    var text: String { entries.map(\.line).joined(separator: "\n") }

    init(fileURL: URL? = SpokenLog.defaultFileURL) {
        self.fileURL = fileURL
        if let fileURL { try? Data().write(to: fileURL) }
    }

    func append(_ kind: Kind, _ text: String, at time: TimeInterval) {
        let entry = Entry(id: entries.count, kind: kind, text: text, time: time)
        entries.append(entry)
        guard let fileURL, let data = (entry.line + "\n").data(using: .utf8),
            let handle = try? FileHandle(forWritingTo: fileURL)
        else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
#endif
