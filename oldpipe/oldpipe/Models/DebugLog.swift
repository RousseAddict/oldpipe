import UIKit

// MARK: - DebugLog
// Opt-in in-memory breadcrumb trail for diagnosing the "video won't play from Home" class
// of bugs, which fail SILENTLY on iOS 6 (no crash dialog, no error surfaced to the user —
// see the iOS 6 gotchas in CLAUDE.md). Settings > Debug has a toggle; when off, log(_:_:)
// is a single Bool check (the @autoclosure message is never even built), so there is no
// steady-state cost on iPhone 4S. When on, callers sprinkled through the playback pipeline
// (HomeVC tap -> YoutubeAPI.getStreams -> StreamResolver -> StreamProxy -> VideoPlayer/AVPlayerItem
// status) record enough context to reconstruct what happened, and the whole trail can be
// copied to the clipboard from Settings for the user to paste back to us.
enum DebugLog {

    // Same static-serial-queue convention as CurlFetcher/AsyncImageView/VideoPlayer — never
    // spawn a queue per call; this one is created once and reused for every log() call site.
    private static let queue = DispatchQueue(label: "com.oldpipe.debuglog")
    private static var entries: [String] = []
    private static let cap = 300

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // @autoclosure means the string interpolation in `message` is never evaluated when
    // logging is disabled — just the Bool check below.
    static func log(_ category: String, _ message: @autoclosure () -> String) {
        guard AppSettings.debugLoggingEnabled else { return }
        let line = "[\(formatter.string(from: Date()))] [\(category)] \(message())"
        queue.async {
            entries.append(line)
            if entries.count > cap { entries.removeFirst(entries.count - cap) }
        }
    }

    // Text to copy to the clipboard, oldest first. Includes a small header with basic
    // device/app context so a pasted report is self-describing.
    static func exportText() -> String {
        return queue.sync {
            var header = "oldpipe debug log\n"
            header += "iOS \(UIDevice.current.systemVersion)\n"
            header += "entries: \(entries.count)\n"
            header += "----\n"
            if entries.isEmpty { return header + "(no entries yet — play a video from Home with debug logging enabled, then copy)" }
            return header + entries.joined(separator: "\n")
        }
    }

    static func clear() {
        queue.sync { entries.removeAll() }
    }

    static func count() -> Int {
        return queue.sync { entries.count }
    }
}
