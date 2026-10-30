import Foundation

struct Video {
    let id: String
    let title: String
    let channelName: String
    let channelId: String      // UC... (empty if unknown)
    let thumbnailURL: String
    let durationText: String   // e.g. "3:45"
    let viewCountText: String  // e.g. "1.2M views"
    let publishedText: String  // e.g. "3 days ago" (empty if unknown)
    // Absolute publish time (epoch seconds), captured at fetch time from the relative
    // "published" string. 0 = unknown. Persisted so a saved video's age stays current
    // instead of showing the frozen "3 days ago" text forever (see displayPublished).
    var publishedTimestamp: Double = 0

    // The published label to show. When we have an absolute timestamp, recompute the
    // relative string from now so it stays fresh; otherwise fall back to the stored text.
    var displayPublished: String {
        return publishedTimestamp > 0 ? Video.relativeString(from: publishedTimestamp) : publishedText
    }

    func toDict() -> [String: Any] {
        return [
            "id": id,
            "title": title,
            "channelName": channelName,
            "channelId": channelId,
            "thumbnailURL": thumbnailURL,
            "durationText": durationText,
            "viewCountText": viewCountText,
            "publishedText": publishedText,
            "publishedTimestamp": publishedTimestamp
        ]
    }

    static func from(dict: [String: Any]) -> Video? {
        guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
        return Video(
            id: id,
            title: (dict["title"] as? String) ?? "",
            channelName: (dict["channelName"] as? String) ?? "",
            channelId: (dict["channelId"] as? String) ?? "",
            thumbnailURL: (dict["thumbnailURL"] as? String) ?? "",
            durationText: (dict["durationText"] as? String) ?? "",
            viewCountText: (dict["viewCountText"] as? String) ?? "",
            publishedText: (dict["publishedText"] as? String) ?? "",
            // NSNumber path: numeric `as? Double` silently fails on the iOS 6 5.1.5 runtime.
            publishedTimestamp: ((dict["publishedTimestamp"] as? NSNumber)?.doubleValue) ?? 0
        )
    }

    // MARK: - Relative published-time helpers

    // Convert a YouTube relative "published" string ("3 days ago", "Streamed 2 hours ago")
    // into an absolute epoch (anchored to now, at call time). Returns 0 for an unknown /
    // non-relative string (e.g. an absolute "2024-01-15" date, which needs no refresh).
    static func timestamp(fromRelative text: String) -> Double {
        let age = ageSeconds(text)
        guard age.isFinite else { return 0 }
        return Date().timeIntervalSince1970 - age
    }

    // Approximate age in seconds of a relative string; .infinity if not parseable.
    static func ageSeconds(_ text: String) -> Double {
        let lower = text.lowercased()
        if lower.isEmpty { return .infinity }
        var digits = ""
        for ch in lower {
            if ch.isNumber { digits.append(ch) }
            else if !digits.isEmpty { break }
        }
        let num = Double(digits) ?? 1
        let unit: Double
        if lower.contains("year")        { unit = 31_536_000 }
        else if lower.contains("month")  { unit = 2_592_000 }
        else if lower.contains("week")   { unit = 604_800 }
        else if lower.contains("day")    { unit = 86_400 }
        else if lower.contains("hour")   { unit = 3_600 }
        else if lower.contains("minute") { unit = 60 }
        else if lower.contains("second") { unit = 1 }
        else { return .infinity }
        return num * unit
    }

    // Build a fresh relative string ("3 days ago") from an absolute epoch.
    static func relativeString(from ts: Double) -> String {
        let age = Date().timeIntervalSince1970 - ts
        if age < 60 { return "just now" }
        let table: [(Double, String)] = [
            (31_536_000, "year"), (2_592_000, "month"), (604_800, "week"),
            (86_400, "day"), (3_600, "hour"), (60, "minute")
        ]
        for (unit, name) in table where age >= unit {
            let n = Int(age / unit)
            return "\(n) \(name)\(n == 1 ? "" : "s") ago"
        }
        return "just now"
    }
}

struct VideoStream {
    let url: String
    let itag: Int
    let mimeType: String
    let quality: String
    // Byte size of the stream (from the player response `contentLength`), 0 if unknown.
    // Used to show "~48 MB" estimates in the download quality sheet. `var` with a default
    // keeps the synthesized memberwise init working for call sites that omit it.
    var contentLength: Int64 = 0
    // DASH adaptiveFormats only: end byte of the init segment (`initRange.end`) and of the
    // sidx segment index (`indexRange.end`). -1 when absent (muxed formats). A stream with
    // indexEnd >= 0 is fMP4 and can feed the local HLS transmux pipeline: fetching
    // bytes=0-indexEnd yields the full init+sidx head that HLSTransmuxer.parse needs.
    var initEnd: Int64 = -1
    var indexEnd: Int64 = -1

    // Progressive = one file carrying BOTH video and audio (`formats[]`, itag 18/22): directly
    // playable by AVPlayer, and the only kind a download or a Chromecast can use. Adaptive
    // formats are video-only or audio-only and must go through the HLS transmux pipeline.
    var isProgressive: Bool { return indexEnd < 0 }
}

// A seekable point inside a video. Taken from the watch page's own chapter list when YouTube
// publishes one (see YoutubeAPI.parseChapters), else parsed out of the description below.
struct Chapter: Equatable {
    let title: String
    let startSeconds: Double

    // "4:05" / "1:02:30". VideoPlayerVC.timeString never carries an hours field, which reads
    // wrong on the multi-hour videos that tend to have chapters in the first place.
    var timeLabel: String {
        let t = Int(startSeconds)
        if t >= 3600 {
            return "\(t / 3600):" + String(format: "%02d:%02d", (t % 3600) / 60, t % 60)
        }
        return "\(t / 60):" + String(format: "%02d", t % 60)
    }

    // Timestamp lines come in every shape there is — "0:00 Intro", "⌨️ (0:00) Intro",
    // "[0:00] Intro", "Intro - 0:00" — so the scan is positional rather than a pattern match:
    // find the first m:ss / h:mm:ss run on the line and treat whatever text is left over as
    // the title. Hand-rolled rather than NSRegularExpression: a plain scan has no bridging
    // surface on the Swift 5.1.5 runtime shipped for iOS 6.
    static func parse(description: String) -> [Chapter] {
        var found: [Chapter] = []
        for line in description.components(separatedBy: "\n") {
            if let c = parseLine(line) { found.append(c) }
        }
        // A lone timestamp is a reference inside a sentence ("recorded 10:30"), not a chapter
        // list. Two or more on their own lines is what an actual list looks like.
        guard found.count >= 2 else { return [] }
        found.sort { $0.startSeconds < $1.startSeconds }
        var out: [Chapter] = []
        for c in found where out.last?.startSeconds != c.startSeconds { out.append(c) }
        return out
    }

    private static func parseLine(_ line: String) -> Chapter? {
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            guard digit(chars[i]) != nil else { i += 1; continue }
            // Never start mid-number: "2024" and the "30" of "1:30" are not timestamps.
            if i > 0, digit(chars[i - 1]) != nil || chars[i - 1] == ":" { i += 1; continue }

            // Read colon-separated digit runs: 2 groups = m:ss, 3 = h:mm:ss.
            var j = i
            var groups: [(value: Int, digits: Int)] = []
            while j < chars.count {
                var n = 0
                var len = 0
                while j < chars.count, let d = digit(chars[j]) {
                    // Only a timestamp's few digits are worth a value. Int is 32 bits on armv7,
                    // so the 19-digit id in an x.com/status link used to overflow n * 10 and
                    // trap — killing the video page of any description that carries one.
                    if len < maxGroupDigits { n = n * 10 + d }
                    len += 1
                    j += 1
                }
                if len == 0 { break }
                groups.append((n, len))
                if j < chars.count, chars[j] == ":" { j += 1; continue }
                break
            }

            // A longer leading group ("12345678:00") is an id, not a time.
            let lead = groups.first.map { $0.digits <= maxGroupDigits } ?? false
            var seconds = -1.0
            if lead, groups.count == 2, groups[1].digits == 2, groups[1].value < 60 {
                seconds = Double(groups[0].value * 60 + groups[1].value)
            } else if lead, groups.count == 3, groups[1].digits == 2, groups[1].value < 60,
                      groups[2].digits == 2, groups[2].value < 60 {
                seconds = Double(groups[0].value * 3600 + groups[1].value * 60 + groups[2].value)
            }
            if seconds < 0 {
                i = j > i ? j : i + 1
                continue
            }

            // The title is the rest of the line — after the stamp when there is anything
            // there, else before it ("Intro - 0:00").
            let after = cleanTitle(String(chars[j...]))
            let title = after.isEmpty ? cleanTitle(String(chars[0..<i])) : after
            return title.isEmpty ? nil : Chapter(title: title, startSeconds: seconds)
        }
        return nil
    }

    // Longest leading group a timestamp can have: 99999 minutes or hours is already far past
    // any video, and 99999 * 3600 still fits a 32-bit Int.
    private static let maxGroupDigits = 5

    // Leftovers of whatever bracketed/bulleted the timestamp.
    private static let titleTrim = CharacterSet(charactersIn: " \t-–—:•|·*>_()[]{}\u{00A0}")

    private static func cleanTitle(_ s: String) -> String {
        return s.trimmingCharacters(in: titleTrim)
    }

    private static func digit(_ c: Character) -> Int? {
        let scalars = c.unicodeScalars
        guard scalars.count == 1, let s = scalars.first else { return nil }
        return (s.value >= 48 && s.value <= 57) ? Int(s.value - 48) : nil
    }
}
