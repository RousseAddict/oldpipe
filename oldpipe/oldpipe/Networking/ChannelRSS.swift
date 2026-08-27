import Foundation

// MARK: - ChannelRSS
// Reads a channel's public Atom feed:
//     https://www.youtube.com/feeds/videos.xml?channel_id=UC...
// This is a plain XML GET — no innertube, no clientVersion, no visitorData, no poToken — so it
// is immune to every bot gate that makes the player path fragile, and it cannot go stale the way
// a pinned clientVersion does.
//
// Why we want it: the feed carries an EXACT publish date (`<published>`) for each of its ~15 most
// recent uploads, and it lists Shorts alongside regular videos (measured 2026-08-27: 10 of 15
// entries on a Shorts-heavy channel were Shorts, distinguishable by their `/shorts/<id>` link).
// The innertube Shorts tab carries no date at all — `shortsLockupViewModel` has no date field —
// which is why the home Shorts feed had to fall back to a shuffle for ordering.
//
// Only the dates are extracted. Title/description/view count are also in the feed but every
// screen already has those from innertube, which additionally supplies duration (the feed does
// not), so the feed is a supplement to the browse call and not a replacement for it.
//
// XMLParser is NSXMLParser (iOS 2+) and safe here. Namespaces are left unprocessed, so element
// names arrive qualified ("yt:videoId"), which is what we match on.

class ChannelRSS {

    // Static parse queue (one reused thread) — never create a DispatchQueue per call.
    private static let parseQueue = DispatchQueue(label: "com.oldpipe.rssparse")

    // Fetches the feed and returns [videoId: publishEpochSeconds]. Empty on any failure —
    // callers treat a missing date as "unknown" and keep their existing fallback ordering.
    static func fetchPublishDates(channelId: String, priority: Bool = false,
                                  completion: @escaping ([String: Double]) -> Void) {
        // A channel id is exactly "UC" + 22 url-safe chars. Checking the shape also keeps the
        // value from being able to inject anything into the query string.
        guard channelId.count == 24, channelId.hasPrefix("UC") else { completion([:]); return }
        let url = "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelId)"
        CurlFetcher.fetchData(url: url, priority: priority) { data in
            guard let data = data, !data.isEmpty else {
                DebugLog.log("ChannelRSS", "feed \(channelId) — no response")
                completion([:])
                return
            }
            parseQueue.async {
                let map = ChannelRSS.parseDates(data)
                DispatchQueue.main.async {
                    DebugLog.log("ChannelRSS", "feed \(channelId) — \(map.count) dated entry(ies) from \(data.count) bytes")
                    completion(map)
                }
            }
        }
    }

    static func parseDates(_ data: Data) -> [String: Double] {
        let parser = XMLParser(data: data)
        let handler = DateCollector()
        parser.delegate = handler
        parser.parse()
        return handler.dates
    }

    // MARK: - ISO 8601 → epoch seconds
    // The feed emits a fixed-width "2026-08-23T16:00:04+00:00" (or a trailing "Z"). Parsing it by
    // hand rather than with a DateFormatter avoids relying on ISO-8601 format specifiers, whose
    // support varies across the OS versions we ship to, and needs no locale.
    static func epochFromISO8601(_ s: String) -> Double {
        let b = Array(s.utf8)
        guard b.count >= 19 else { return 0 }
        func num(_ start: Int, _ len: Int) -> Int? {
            var v = 0
            for i in start..<(start + len) {
                let c = b[i]
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard let year = num(0, 4), let month = num(5, 2), let day = num(8, 2),
              let hour = num(11, 2), let minute = num(14, 2), let second = num(17, 2),
              month >= 1, month <= 12, day >= 1, day <= 31 else { return 0 }

        // Timezone suffix: "Z" (or absent) = UTC, otherwise "+HH:MM" / "-HH:MM".
        var offset = 0
        if b.count >= 25, b[19] == 43 || b[19] == 45 {
            if let oh = num(20, 2), let om = num(23, 2) {
                offset = (oh * 3600 + om * 60) * (b[19] == 45 ? -1 : 1)
            }
        }

        let days = daysFromCivil(year, month, day)
        return Double(days * 86400 + hour * 3600 + minute * 60 + second - offset)
    }

    // Days between 1970-01-01 and the given proleptic-Gregorian date (Howard Hinnant's
    // days_from_civil). Pure integer arithmetic — no calendar API involved.
    private static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400                                             // [0, 399]
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1  // [0, 365]
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy                     // [0, 146096]
        return era * 146097 + doe - 719468
    }
}

// Collects one (yt:videoId, published) pair per <entry>. Both tags also exist outside an entry
// at feed level, so everything is gated on being inside one. Character data can be delivered in
// several chunks, hence the accumulating buffer.
private class DateCollector: NSObject, XMLParserDelegate {
    var dates: [String: Double] = [:]

    private var inEntry = false
    private var videoId = ""
    private var published = ""
    private var buffer: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "entry":
            inEntry = true
            videoId = ""
            published = ""
        case "yt:videoId", "published":
            if inEntry { buffer = "" }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if buffer != nil { buffer! += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "yt:videoId":
            if let b = buffer { videoId = b.trimmingCharacters(in: .whitespacesAndNewlines) }
            buffer = nil
        case "published":
            if let b = buffer { published = b.trimmingCharacters(in: .whitespacesAndNewlines) }
            buffer = nil
        case "entry":
            inEntry = false
            if !videoId.isEmpty {
                let ts = ChannelRSS.epochFromISO8601(published)
                if ts > 0 { dates[videoId] = ts }
            }
        default:
            break
        }
    }
}
