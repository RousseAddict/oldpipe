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

    // Identity of a track across two fetches of the same video's list. Not baseUrl — that
    // one carries signed, expiring query params and differs every time.
    var key: String { return languageCode + (isASR ? "|asr" : "") }
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

    // Fetch + parse one track's transcript. A downloaded video reads it off disk instead —
    // its baseUrl expired hours ago, and the whole point of saving them was to not need it.
    // Otherwise this is always user-initiated, so it takes the high-priority curl lane and
    // preempts a background subscription-feed load.
    static func load(_ track: CaptionTrack, videoId: String? = nil,
                     completion: @escaping ([CaptionCue]) -> Void) {
        if let id = videoId, hasOffline(id, key: track.key) {
            parseQueue.async {
                let cues = offlineCues(for: id, key: track.key) ?? []
                DebugLog.log("Captions", "offline lang=\(track.languageCode) cues=\(cues.count)")
                DispatchQueue.main.async { completion(cues) }
            }
            return
        }
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
        // Auto-generated (ASR) tracks give every line a ROLL-UP duration that deliberately
        // outlives the next line's start — YouTube's own player scrolls two lines at once.
        // We draw a single line and cueIndex() keeps a cue until its end, so leaving the
        // overlap in (3.3s on average, up to 7s) pins the caption a full line behind the
        // audio for the whole video. Trim each end back to the next start. Human-authored
        // tracks never overlap, so this is a no-op for them.
        for i in 0..<max(cues.count - 1, 0) {
            let next = cues[i + 1].start
            guard next > cues[i].start, cues[i].end > next else { continue }
            cues[i] = CaptionCue(start: cues[i].start, end: next, text: cues[i].text)
        }
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

    // MARK: - Offline storage
    //
    // A caption baseUrl is signed and expires in roughly six hours, so a downloaded video's
    // transcripts have to be fetched AT DOWNLOAD TIME and kept. They are stored as the raw
    // srv1 bytes exactly as they arrive, so parseSRV1 — including its ASR overlap trim — works
    // unchanged at playback and there is no second on-disk format to keep in step:
    //
    //   downloads/<id>/captions.json      index; carries the display name a filename cannot
    //   downloads/<id>/captions/en.srv1   one file per track, named from CaptionTrack.key
    //
    // Size is why every chosen track is simply kept rather than re-fetched: measured live, a
    // track is 0.4-5 KB against a 12-95 MB download.

    private static func captionsDir(_ videoId: String) -> String {
        return (DownloadManager.bundleDir(for: videoId) as NSString).appendingPathComponent("captions")
    }

    private static func indexPath(_ videoId: String) -> String {
        return (DownloadManager.bundleDir(for: videoId) as NSString).appendingPathComponent("captions.json")
    }

    // CaptionTrack.key uses "|" to mark an ASR track ("en|asr"); "." reads better in a filename
    // and cannot collide, since a languageCode never contains either.
    private static func fileName(for key: String) -> String {
        return key.replacingOccurrences(of: "|", with: ".") + ".srv1"
    }

    static func hasOffline(_ videoId: String, key: String) -> Bool {
        return FileManager.default.fileExists(
            atPath: (captionsDir(videoId) as NSString).appendingPathComponent(fileName(for: key)))
    }

    static func offlineCues(for videoId: String, key: String) -> [CaptionCue]? {
        let path = (captionsDir(videoId) as NSString).appendingPathComponent(fileName(for: key))
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return parseSRV1(data)
    }

    // The tracks saved alongside a download, in the order they were listed when it ran.
    // Empty for a video downloaded before captions were saved, or one with none — in both
    // cases the player simply shows no CC row, exactly as it did before.
    static func offlineTracks(for videoId: String) -> [CaptionTrack] {
        guard let data = FileManager.default.contents(atPath: indexPath(videoId)),
              let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [[String: Any]]
        else { return [] }
        var out: [CaptionTrack] = []
        for e in root {
            guard let lang = e["languageCode"] as? String else { continue }
            // NSNumber-boxed: a direct `as? Bool` returns nil on the 5.1.5 runtime.
            let asr = ((e["isASR"] as? NSNumber)?.boolValue) ?? false
            let name = (e["name"] as? String) ?? lang
            // baseUrl is deliberately empty — it is long dead, and load() reads from disk.
            out.append(CaptionTrack(baseUrl: "", languageCode: lang, name: name, isASR: asr))
        }
        return out
    }

    // BLOCKING fetch + save of the chosen tracks. Caller must already be on a background
    // queue (OfflineDownloader's). Returns how many landed; a track that fails is skipped
    // rather than failing the download — a missing subtitle is not worth losing the video to.
    // Written BEFORE the media transfer, because a multi-hour 1080p download would otherwise
    // reach this with every baseUrl expired.
    @discardableResult
    static func saveOfflineSync(_ tracks: [CaptionTrack], for videoId: String,
                                shouldAbort: () -> Bool = { false }) -> Int {
        guard !tracks.isEmpty else { return 0 }
        let dir = captionsDir(videoId)
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                     attributes: nil)
        }
        var index: [[String: Any]] = []
        for t in tracks {
            if shouldAbort() { break }
            guard let data = CurlFetcher.getSync(url: srv1URL(t.baseUrl), timeout: 20),
                  !data.isEmpty else {
                DebugLog.log("Captions", "save FAILED id=\(videoId) lang=\(t.languageCode)")
                continue
            }
            let path = (dir as NSString).appendingPathComponent(fileName(for: t.key))
            guard (data as NSData).write(toFile: path, atomically: true) else { continue }
            index.append(["languageCode": t.languageCode, "name": t.name, "isASR": t.isASR])
        }
        guard !index.isEmpty else { return 0 }
        if let data = try? JSONSerialization.data(withJSONObject: index, options: []) {
            _ = (data as NSData).write(toFile: indexPath(videoId), atomically: true)
        }
        DebugLog.log("Captions", "saved id=\(videoId) tracks=\(index.count)")
        return index.count
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
