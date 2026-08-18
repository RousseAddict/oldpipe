import Foundation

// MARK: - Captions
// Subtitle support. The caption track list already ships inside the player response we fetch
// for stream URLs (captions.playerCaptionsTracklistRenderer), so offering captions costs no
// extra API call — only one GET for the chosen transcript.
//
// AVPlayer cannot render these on iOS 6: AVMediaSelectionGroup only covers tracks embedded
// in the asset / HLS playlist, and AVPlayerItemLegibleOutput is iOS 7+. So cues are drawn
// by VideoPlayerVC into a plain UILabel driven by a timer.

struct CaptionTrack {
    let baseUrl: String
    let languageCode: String
    let name: String        // display label, e.g. "English (auto-generated)"
    let isASR: Bool         // auto-generated (kind == "asr")
}

struct CaptionCue {
    let start: Double
    let end: Double
    let text: String
}

enum Captions {

    // Static serial queue — never create a DispatchQueue per call (each one spawns an OS
    // thread; the 4S runs out). Transcript parsing stays off the main thread.
    private static let parseQueue = DispatchQueue(label: "com.oldpipe.captions")

    // Fetch + parse one track's transcript. Always user-initiated, so it takes the
    // high-priority curl lane and preempts a background subscription-feed load.
    static func load(_ track: CaptionTrack, completion: @escaping ([CaptionCue]) -> Void) {
        CurlFetcher.fetchData(url: srv1URL(track.baseUrl), timeout: 20, priority: true) { data in
            guard let data = data, !data.isEmpty else {
                DebugLog.log("Captions", "fetch FAILED lang=\(track.languageCode)")
                completion([])
                return
            }
            parseQueue.async {
                let cues = parseSRV1(data)
                DebugLog.log("Captions", "lang=\(track.languageCode) bytes=\(data.count) cues=\(cues.count)")
                DispatchQueue.main.async { completion(cues) }
            }
        }
    }

    // The baseUrl YouTube hands us already ends in `fmt=srv3`, and the timedtext endpoint
    // IGNORES a second `&fmt=` — the existing one must be REPLACED. srv1 is the flat
    // `<text start="0.32" dur="14.26">line</text>` form: no per-word <s> timings and no
    // duplicated rollup lines, so it is ~3x smaller and trivial to scan.
    static func srv1URL(_ base: String) -> String {
        guard let r = base.range(of: "fmt=") else { return base + "&fmt=srv1" }
        var out = String(base[base.startIndex..<r.upperBound]) + "srv1"
        if let amp = base.range(of: "&", range: r.upperBound..<base.endIndex) {
            out += String(base[amp.lowerBound..<base.endIndex])
        }
        return out
    }

    static func parseSRV1(_ data: Data) -> [CaptionCue] {
        guard let xml = String(data: data, encoding: .utf8) else { return [] }
        var cues: [CaptionCue] = []
        var idx = xml.startIndex
        while let open = xml.range(of: "<text", range: idx..<xml.endIndex) {
            guard let gt = xml.range(of: ">", range: open.upperBound..<xml.endIndex),
                  let close = xml.range(of: "</text>", range: gt.upperBound..<xml.endIndex) else { break }
            let attrs = String(xml[open.upperBound..<gt.lowerBound])
            let body = String(xml[gt.upperBound..<close.lowerBound])
            idx = close.upperBound
            guard let start = attr(attrs, "start") else { continue }
            let dur = attr(attrs, "dur") ?? 0
            // srv1 bodies are DOUBLE-escaped (a quote arrives as "&amp;#39;"), hence two
            // decode passes. A literal ampersand is "&amp;amp;", so this stays correct.
            let text = decodeEntities(decodeEntities(body))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            cues.append(CaptionCue(start: start, end: start + max(dur, 0.5), text: text))
        }
        cues.sort { $0.start < $1.start }
        return cues
    }

    // Index of the cue covering `t`, or -1 when there is none (gap between lines).
    // `hint` is the previously active index: playback advances one cue at a time, so the
    // hot path is two comparisons and the binary search is only hit after a seek.
    static func cueIndex(at t: Double, in cues: [CaptionCue], hint: Int) -> Int {
        if cues.isEmpty { return -1 }
        if hint >= 0, hint < cues.count {
            if t >= cues[hint].start, t < cues[hint].end { return hint }
            let n = hint + 1
            if n < cues.count, t >= cues[n].start, t < cues[n].end { return n }
        }
        var lo = 0, hi = cues.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cues[mid].start > t { hi = mid - 1 } else { found = mid; lo = mid + 1 }
        }
        if found >= 0, t < cues[found].end { return found }
        return -1
    }

    // MARK: - Helpers

    private static func attr(_ attrs: String, _ name: String) -> Double? {
        guard let r = attrs.range(of: name + "=\""),
              let end = attrs.range(of: "\"", range: r.upperBound..<attrs.endIndex) else { return nil }
        return Double(String(attrs[r.upperBound..<end.lowerBound]))
    }

    // Minimal XML entity decoder. NSXMLParser would work but is heavy for two attributes
    // and a text node, and this has to run twice per cue anyway.
    static func decodeEntities(_ s: String) -> String {
        guard s.range(of: "&") != nil else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&",
               let semi = s.range(of: ";", range: i..<s.endIndex),
               s.distance(from: i, to: semi.lowerBound) <= 8 {
                let ent = String(s[s.index(after: i)..<semi.lowerBound])
                var replacement: String? = nil
                switch ent {
                case "amp":  replacement = "&"
                case "lt":   replacement = "<"
                case "gt":   replacement = ">"
                case "quot": replacement = "\""
                case "apos": replacement = "'"
                default:
                    if ent.hasPrefix("#"), let code = UInt32(String(ent.dropFirst())),
                       let u = UnicodeScalar(code) {
                        replacement = String(Character(u))
                    }
                }
                if let rep = replacement {
                    out += rep
                    i = semi.upperBound
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}
