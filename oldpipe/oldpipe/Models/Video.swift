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
}
