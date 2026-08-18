import Foundation

// MARK: - YoutubeAPI
// Accesses YouTube via the internal innertube API.
// YouTube gates most innertube clients behind attestation (poToken/integrity). The ones that
// still work without it:
//   - WEB     : for search — returns twoColumnSearchResultsRenderer
//   - ANDROID : player, first leg — the only un-gated client that still returns a MUXED format
//               (itag 18), which direct play, downloads and Chromecast all need. Its
//               adaptiveFormats are SABR-only (no `url`), so it yields 360p and nothing else.
//   - IOS     : player, second leg — every adaptive tier with a plain url (what the HLS
//               transmuxer needs), but `formats[]` is always empty, so no muxed format.
// The two are COMPLEMENTARY, not alternatives: their stream lists are merged (see resolveStreams).
// For both mobile clients only a CURRENT clientVersion is accepted — a stale version comes back
// FAILED_PRECONDITION, which is what made ANDROID look permanently dead in earlier notes.
// ANDROID_VR was dropped in 2026-08: bot-gated (LOGIN_REQUIRED) on effectively every video.
// All network calls go through CurlFetcher (libcurl + OpenSSL) for GCM cipher support on iOS 6.

class YoutubeAPI {

    // Visitor identity token. The player gates behind LOGIN_REQUIRED without it.
    // Captured from any innertube responseContext; bootstrapped on demand if absent.
    private static var cachedVisitorData = ""

    private static let baseURL = "https://www.youtube.com/youtubei/v1"

    // WEB client — used for search. Direct browser-style request.
    private static let webClient: [String: Any] = [
        "clientName": "WEB",
        "clientVersion": "2.20240304.00.00",
        "hl": "en",
        "gl": "US"
    ]
    private static let webUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

    // ANDROID client — first player leg. Supplies the muxed itag 18 (plain url, no cipher, no
    // poToken) that direct play, downloads and Chromecast depend on. Nothing else about the
    // request matters for passing the bot check: the gate keys off clientVersion ALONE — the
    // endpoint host, visitorData, cpn and even a mismatched User-Agent are all irrelevant.
    // So this version string is the one line to bump when the player starts failing.
    private static let androidClient: [String: Any] = [
        "clientName": "ANDROID",
        "clientVersion": "21.03.36",
        "platform": "MOBILE",
        "osName": "Android",
        "osVersion": "16",
        "androidSdkVersion": 36,
        "hl": "en",
        "gl": "US"
    ]
    private static let androidUserAgent =
        "com.google.android.youtube/21.03.36 (Linux; U; Android 15; US) gzip"

    // IOS client — second player leg, source of every adaptive tier (134/135/136/137/140...)
    // with a plain url, which is what the HLS transmux pipeline needs for >360p. `formats[]` is
    // always empty here, so it can never supply a muxed stream. Same version rule as ANDROID:
    // a stale clientVersion returns FAILED_PRECONDITION, so bump this line when HD breaks.
    private static let iosClient: [String: Any] = [
        "clientName": "IOS",
        "clientVersion": "20.03.02",
        "deviceMake": "Apple",
        "deviceModel": "iPhone16,2",
        "osName": "iPhone",
        "osVersion": "18.2.1.22C161",
        "hl": "en",
        "gl": "US"
    ]
    private static let iosUserAgent =
        "com.google.ios.youtube/20.03.02 (iPhone16,2; U; CPU iOS 18_2_1 like Mac OS X)"

    private static let jsonHeaders = [
        "Content-Type: application/json",
        "Accept-Language: en-US,en;q=0.9"
    ]

    // Static parse queue (one reused thread) — never create DispatchQueue per call.
    private static let parseQueue = DispatchQueue(label: "com.oldpipe.ytparse")
    // Dedicated parse lane for the player path. The feed parses many large channel-browse
    // responses on parseQueue (serial); routing the player's parse through its own queue
    // means stream resolution never waits behind a backed-up feed-parse queue — the real
    // cause of "tap a video while the feed loads → stuck on loading for 30-40s".
    private static let playerParseQueue = DispatchQueue(label: "com.oldpipe.ytparse.player")
    // Dedicated parse lane for USER-INITIATED browse/search/related requests (priority:true).
    // Same reasoning as playerParseQueue: getting the bytes fast via the high-priority network
    // lane isn't enough — the parse must also skip the serial parseQueue that the background
    // feed jams with many large channel-browse parses. Without this, tapping a channel (or
    // searching) mid-feed-load returns bytes quickly but the PARSE waits 30-40s behind the feed.
    private static let interactiveParseQueue = DispatchQueue(label: "com.oldpipe.ytparse.interactive")

    private static func body(client: [String: Any], extra: [String: Any]) -> [String: Any] {
        var b: [String: Any] = ["context": ["client": client]]
        for (k, v) in extra { b[k] = v }
        return b
    }

    // MARK: - Search

    static func search(query: String, completion: @escaping ([Video]) -> Void) {
        let payload = body(client: webClient, extra: ["query": query])
        guard let jsonStr = toJSON(payload) else { completion([]); return }
        let url = "\(baseURL)/search?prettyPrint=false"
        // Search is always user-initiated — use the high-priority lane so it preempts
        // any in-flight background feed load (see CurlFetcher feedTurnstile).
        CurlFetcher.postJSON(url: url, body: jsonStr, headers: jsonHeaders,
                             userAgent: webUserAgent, timeout: 30, priority: true) { data in
            guard let data = data else { completion([]); return }
            // Parse off main thread, on the interactive lane (search is always user-initiated).
            interactiveParseQueue.async {
                let results = parseSearchResults(data)
                DispatchQueue.main.async { completion(results) }
            }
        }
    }

    // MARK: - Player (stream URLs + video details)

    // completion: (streams, video details, full description text, failure reason, caption tracks)
    // failure reason is empty when streams came back; otherwise it is a user-facing
    // explanation of why there is nothing to play (bot check, paid, live, network...).
    static func getStreams(videoId: String, completion: @escaping ([VideoStream], Video?, String, String, [CaptionTrack]) -> Void) {
        if cachedVisitorData.isEmpty {
            bootstrapVisitorData { resolveStreams(videoId: videoId, completion: completion) }
        } else {
            resolveStreams(videoId: videoId, completion: completion)
        }
    }

    // Two-leg resolution. ANDROID answers first and is the ONLY source of a muxed itag 18, but
    // its adaptiveFormats are SABR-only, so it alone would cap every video at 360p and kill the
    // quality sheet. The IOS leg supplies the adaptive tiers and the two lists are MERGED — so
    // downstream code finds both a progressive stream (direct play / download / cast) and the
    // fMP4 tiers (HLS transmux) exactly as it did when ANDROID_VR returned both in one response.
    // Second request is conditional, not unconditional: if YouTube ever restores plain urls to
    // ANDROID's adaptiveFormats this collapses back to a single round trip on its own.
    // Refreshing visitorData is NOT a fix for a gated response and is never attempted — the gate
    // is per-video and server-side, and fires with a freshly minted token and with none at all.
    private static func resolveStreams(videoId: String,
                                       completion: @escaping ([VideoStream], Video?, String, String, [CaptionTrack]) -> Void) {
        performPlayer(videoId: videoId, useIOS: false) { streams, video, desc, failure, captions in
            // !isProgressive == carries initRange/indexRange == usable by the HLS transmuxer.
            if streams.contains(where: { !$0.isProgressive }) {
                completion(streams, video, desc, failure, captions)
                return
            }
            DebugLog.log("YoutubeAPI", "ANDROID gave \(streams.count) stream(s), no adaptive tier id=\(videoId) — adding the IOS client")
            performPlayer(videoId: videoId, useIOS: true) { iosStreams, iosVideo, iosDesc, iosFailure, iosCaptions in
                // Prefer the ANDROID leg's metadata; fall back to IOS's when ANDROID came back
                // empty-handed (gated video, livestream, or a failed request).
                let merged = streams + iosStreams
                completion(merged,
                           video ?? iosVideo,
                           desc.isEmpty ? iosDesc : desc,
                           merged.isEmpty ? (failure.isEmpty ? iosFailure : failure) : "",
                           captions.isEmpty ? iosCaptions : captions)
            }
        }
    }

    // One player request against one client. Returns whatever that client gave, with no retry —
    // chaining the clients is resolveStreams' job.
    private static func performPlayer(videoId: String, useIOS: Bool,
                                      completion: @escaping ([VideoStream], Video?, String, String, [CaptionTrack]) -> Void) {
        var client = useIOS ? iosClient : androidClient
        // visitorData is a WEB-issued identity. Not required to pass the bot check (verified),
        // but harmless and it keeps the response context consistent across our requests.
        if !useIOS, !cachedVisitorData.isEmpty { client["visitorData"] = cachedVisitorData }
        let payload = body(client: client, extra: ["videoId": videoId])
        guard let jsonStr = toJSON(payload) else { completion([], nil, "", "Could not build request", []); return }
        let url = "\(baseURL)/player?prettyPrint=false"
        CurlFetcher.postJSON(url: url, body: jsonStr, headers: jsonHeaders,
                             userAgent: useIOS ? iosUserAgent : androidUserAgent,
                             timeout: 30, priority: true) { data in
            guard let data = data else {
                DebugLog.log("YoutubeAPI", "player request id=\(videoId) — no response (network/TLS)")
                completion([], nil, "", "Network error — no response from YouTube", [])
                return
            }
            playerParseQueue.async {
                let (streams, video, desc, status, failure, captions) = parsePlayerResponse(data, videoId: videoId)
                DispatchQueue.main.async {
                    DebugLog.log("YoutubeAPI", "\(useIOS ? "IOS" : "ANDROID") player id=\(videoId) status=\(status) streams=\(streams.count)")
                    completion(streams, video, desc, failure, captions)
                }
            }
        }
    }

    // MARK: - Channel (videos + metadata)

    // completion: (videos, channel metadata, continuation token for next page or nil)
    // priority: true routes through the high-priority lane (preempts the background feed).
    // The HomeVC feed loop leaves it false; user-initiated channel navigation passes true.
    static func getChannelVideos(channelId: String, priority: Bool = false, completion: @escaping ([Video], Channel?, String?) -> Void) {
        // params "EgZ2aWRlb3PyBgQKAjoA" = the channel's "Videos" tab.
        let payload = body(client: webClient, extra: ["browseId": channelId, "params": "EgZ2aWRlb3PyBgQKAjoA"])
        guard let jsonStr = toJSON(payload) else { completion([], nil, nil); return }
        let url = "\(baseURL)/browse?prettyPrint=false"
        CurlFetcher.postJSON(url: url, body: jsonStr, headers: jsonHeaders,
                             userAgent: webUserAgent, timeout: 30, priority: priority) { data in
            guard let data = data else { completion([], nil, nil); return }
            (priority ? interactiveParseQueue : parseQueue).async {
                let result = parseChannelResponse(data, channelId: channelId)
                DispatchQueue.main.async { completion(result.0, result.1, result.2) }
            }
        }
    }

    // completion: (shorts videos, continuation token for next page or nil)
    static func getChannelShorts(channelId: String, priority: Bool = false, completion: @escaping ([Video], String?) -> Void) {
        // params "EgZzaG9ydHPyBgUKA5oBAA%3D%3D" = the channel's "Shorts" tab.
        let payload = body(client: webClient, extra: ["browseId": channelId, "params": "EgZzaG9ydHPyBgUKA5oBAA%3D%3D"])
        guard let jsonStr = toJSON(payload) else { completion([], nil); return }
        let url = "\(baseURL)/browse?prettyPrint=false"
        CurlFetcher.postJSON(url: url, body: jsonStr, headers: jsonHeaders,
                             userAgent: webUserAgent, timeout: 30, priority: priority) { data in
            guard let data = data else { completion([], nil); return }
            (priority ? interactiveParseQueue : parseQueue).async {
                let result = parseChannelResponse(data, channelId: channelId)
                DispatchQueue.main.async { completion(result.0, result.2) }
            }
        }
    }

    // Fetch the next page of a channel's videos using a continuation token.
    // completion: (more videos, next continuation token or nil)
    static func getChannelContinuation(token: String, channelName: String, priority: Bool = false, completion: @escaping ([Video], String?) -> Void) {
        let payload = body(client: webClient, extra: ["continuation": token])
        guard let jsonStr = toJSON(payload) else { completion([], nil); return }
        let url = "\(baseURL)/browse?prettyPrint=false"
        CurlFetcher.postJSON(url: url, body: jsonStr, headers: jsonHeaders,
                             userAgent: webUserAgent, timeout: 30, priority: priority) { data in
            guard let data = data else { completion([], nil); return }
            (priority ? interactiveParseQueue : parseQueue).async {
                let result = parseContinuation(data, channelName: channelName)
                DispatchQueue.main.async { completion(result.0, result.1) }
            }
        }
    }

    // MARK: - Related videos (Next endpoint)

    // Related ("Up next") videos for a watch page. WEB client returns the related panel
    // under twoColumnWatchNextResults.secondaryResults as lockupViewModel items.
    static func getRelated(videoId: String, priority: Bool = false, completion: @escaping ([Video]) -> Void) {
        let payload = body(client: webClient, extra: ["videoId": videoId])
        guard let jsonStr = toJSON(payload) else { completion([]); return }
        let url = "\(baseURL)/next?prettyPrint=false"
        CurlFetcher.postJSON(url: url, body: jsonStr, headers: jsonHeaders,
                             userAgent: webUserAgent, timeout: 30, priority: priority) { data in
            guard let data = data else { completion([]); return }
            (priority ? interactiveParseQueue : parseQueue).async {
                let results = parseRelated(data, excludeId: videoId)
                DispatchQueue.main.async { completion(results) }
            }
        }
    }

    private static func parseRelated(_ data: Data, excludeId: String) -> [Video] {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return []
        }
        captureVisitorData(root)
        // The related panel lives under the secondaryResults column; walking just that
        // subtree avoids picking up the primary (currently-playing) video's own renderer.
        let twoCol = dict(dict(root["contents"])?["twoColumnWatchNextResults"])
        let secondary = twoCol?["secondaryResults"]
        var seen = Set<String>()
        seen.insert(excludeId)   // never list the video we're already watching
        var results: [Video] = []
        collectVideoItems(secondary, fallbackChannelId: "", fallbackChannelName: "", seen: &seen, into: &results)
        return results
    }

    // Fetch a visitor identity token via a lightweight WEB search call.
    private static func bootstrapVisitorData(_ done: @escaping () -> Void) {
        let payload = body(client: webClient, extra: ["query": "youtube"])
        guard let jsonStr = toJSON(payload) else { done(); return }
        let url = "\(baseURL)/search?prettyPrint=false"
        CurlFetcher.postJSON(url: url, body: jsonStr, headers: jsonHeaders,
                             userAgent: webUserAgent, timeout: 20, priority: true) { data in
            if let data = data,
               let root = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                captureVisitorData(root)
            }
            done()
        }
    }

    private static func captureVisitorData(_ root: [String: Any]) {
        guard cachedVisitorData.isEmpty,
              let rc = dict(root["responseContext"]),
              let vd = str(rc["visitorData"]), !vd.isEmpty else { return }
        cachedVisitorData = vd
    }

    // MARK: - JSON helpers

    private static func toJSON(_ obj: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // "1234567" → "1.2M". The player returns a raw integer view count string.
    private static func formatViewCount(_ raw: String) -> String {
        guard let n = Double(raw) else { return raw }
        switch n {
        case 1_000_000_000...: return String(format: "%.1fB", n / 1_000_000_000)
        case 1_000_000...:     return String(format: "%.1fM", n / 1_000_000)
        case 1_000...:         return String(format: "%.1fK", n / 1_000)
        default:               return raw
        }
    }

    // Safe traversal helpers
    private static func dict(_ obj: Any?) -> [String: Any]? { return obj as? [String: Any] }
    private static func arr(_ obj: Any?) -> [[String: Any]]? { return obj as? [[String: Any]] }
    private static func str(_ obj: Any?) -> String? { return obj as? String }

    // MARK: - Search response parsing

    private static func parseSearchResults(_ data: Data) -> [Video] {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return []
        }

        captureVisitorData(root)

        // Path through the twoColumnSearchResultsRenderer (WEB client)
        let contents = dict(root["contents"])
        let twoCol = dict(contents?["twoColumnSearchResultsRenderer"])
        let primary = dict(twoCol?["primaryContents"])
        let sectionList = dict(primary?["sectionListRenderer"])
        let sections = arr(sectionList?["contents"])

        // Find itemSectionRenderer in sections (may not be the first item)
        var items: [[String: Any]] = []
        for section in (sections ?? []) {
            if let itemSection = dict(section["itemSectionRenderer"]),
               let sectionItems = arr(itemSection["contents"]) {
                items = sectionItems
                break
            }
        }

        var results: [Video] = []
        for item in items {
            guard let vr = dict(item["videoRenderer"]) else { continue }
            if let v = videoFromRenderer(vr, fallbackChannelId: "") { results.append(v) }
        }
        return results
    }

    // Build a Video from a videoRenderer / gridVideoRenderer dict.
    // Extracts the channel's UC... id from the byline navigationEndpoint when present.
    private static func videoFromRenderer(_ vr: [String: Any], fallbackChannelId: String) -> Video? {
        guard let videoId = str(vr["videoId"]), !videoId.isEmpty else { return nil }

        let title = str(arr(dict(vr["title"])?["runs"])?.first?["text"])
            ?? str(dict(vr["title"])?["simpleText"])
            ?? ""

        let byline = dict(vr["longBylineText"]) ?? dict(vr["shortBylineText"])
        let bylineRun = arr(byline?["runs"])?.first
        let channel = str(bylineRun?["text"]) ?? ""

        // channelId via navigationEndpoint.browseEndpoint.browseId
        var channelId = fallbackChannelId
        if let nav = dict(bylineRun?["navigationEndpoint"]),
           let browse = dict(nav["browseEndpoint"]),
           let bid = str(browse["browseId"]), !bid.isEmpty {
            channelId = bid
        }

        // Always use the canonical mqdefault.jpg. The renderer's own thumbnail URLs from
        // the WEB client are often .webp (which UIImage can't decode on iOS 6) or carry
        // expiring query params — both render blank, hence missing search thumbnails.
        let thumbURL = "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg"

        let duration = str(dict(vr["lengthText"])?["simpleText"]) ?? ""
        let views = str(dict(vr["shortViewCountText"])?["simpleText"])
            ?? str(arr(dict(vr["shortViewCountText"])?["runs"])?.first?["text"])
            ?? ""
        let published = str(dict(vr["publishedTimeText"])?["simpleText"]) ?? ""

        return Video(id: videoId, title: title, channelName: channel, channelId: channelId,
                     thumbnailURL: thumbURL, durationText: duration, viewCountText: views,
                     publishedText: published,
                     publishedTimestamp: Video.timestamp(fromRelative: published))
    }

    // Build a Video from a lockupViewModel (the format channel/browse pages now use
    // instead of videoRenderer). Only handles video lockups (skips playlist/channel).
    private static func videoFromLockup(_ lm: [String: Any], fallbackChannelId: String, fallbackChannelName: String) -> Video? {
        if let ct = str(lm["contentType"]), !ct.contains("VIDEO") { return nil }
        guard let videoId = str(lm["contentId"]), !videoId.isEmpty else { return nil }

        let meta = dict(dict(lm["metadata"])?["lockupMetadataViewModel"])
        let title = str(dict(meta?["title"])?["content"]) ?? ""

        // metadataRows: row 0 is the channel name; a later row is [views, published-date].
        // Any part that's neither a view-count nor a relative date is taken as the channel.
        var views = ""
        var published = ""
        var channel = ""
        if let rows = arr(dict(dict(meta?["metadata"])?["contentMetadataViewModel"])?["metadataRows"]) {
            for row in rows {
                if let parts = arr(row["metadataParts"]) {
                    for part in parts {
                        guard let t = str(dict(part["text"])?["content"]), !t.isEmpty else { continue }
                        if t.contains("view") {
                            if views.isEmpty { views = t }
                        } else if t.contains("ago") || t.contains("Streamed") {
                            if published.isEmpty { published = t }
                        } else if channel.isEmpty {
                            channel = t
                        }
                    }
                }
            }
        }

        var duration = ""
        findDurationBadge(lm["contentImage"], into: &duration)

        // Prefer the page fallback (e.g. on a channel page every video shares one channel);
        // otherwise use the channel parsed from the lockup (the related-videos case).
        let channelName = fallbackChannelName.isEmpty ? channel : fallbackChannelName
        var channelId = fallbackChannelId
        if channelId.isEmpty { channelId = findChannelBrowseId(lm) ?? "" }

        let thumbURL = "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg"
        return Video(id: videoId, title: title, channelName: channelName, channelId: channelId,
                     thumbnailURL: thumbURL, durationText: duration, viewCountText: views,
                     publishedText: published,
                     publishedTimestamp: Video.timestamp(fromRelative: published))
    }

    // Build a Video from a shortsLockupViewModel (the channel "Shorts" tab format).
    // Shorts have no duration badge; title/views come from overlayMetadata, and the
    // videoId lives under the reel-watch tap command.
    private static func videoFromShortsLockup(_ sm: [String: Any], fallbackChannelId: String, fallbackChannelName: String) -> Video? {
        // videoId: onTap.innertubeCommand.reelWatchEndpoint.videoId
        var videoId = ""
        if let cmd = dict(dict(sm["onTap"])?["innertubeCommand"]),
           let reel = dict(cmd["reelWatchEndpoint"]),
           let vid = str(reel["videoId"]), !vid.isEmpty {
            videoId = vid
        }
        if videoId.isEmpty {
            // Fallback: entityId is "shorts-shelf-item-<videoId>"
            if let eid = str(sm["entityId"]), let r = eid.range(of: "shorts-shelf-item-") {
                videoId = String(eid[r.upperBound...])
            }
        }
        guard !videoId.isEmpty else { return nil }

        let overlay = dict(sm["overlayMetadata"])
        let title = str(dict(overlay?["primaryText"])?["content"]) ?? ""
        let views = str(dict(overlay?["secondaryText"])?["content"]) ?? ""

        let thumbURL = "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg"
        return Video(id: videoId, title: title, channelName: fallbackChannelName, channelId: fallbackChannelId,
                     thumbnailURL: thumbURL, durationText: "", viewCountText: views, publishedText: "")
    }

    // Find the first browseId that looks like a channel id (UC…) anywhere in a subtree.
    // In a lockupViewModel the only UC id is the channel's (under the avatar's onTap command).
    private static func findChannelBrowseId(_ obj: Any?) -> String? {
        if let d = obj as? [String: Any] {
            if let bid = str(d["browseId"]), bid.hasPrefix("UC") { return bid }
            for (_, v) in d { if let r = findChannelBrowseId(v) { return r } }
        } else if let a = obj as? [Any] {
            for v in a { if let r = findChannelBrowseId(v) { return r } }
        }
        return nil
    }

    // Find the first thumbnailBadgeViewModel.text that looks like a duration ("0:30").
    private static func findDurationBadge(_ obj: Any?, into out: inout String) {
        if !out.isEmpty { return }
        if let d = obj as? [String: Any] {
            if let badge = dict(d["thumbnailBadgeViewModel"]),
               let t = str(badge["text"]), t.contains(":") {
                out = t; return
            }
            for (_, v) in d { findDurationBadge(v, into: &out); if !out.isEmpty { return } }
        } else if let a = obj as? [Any] {
            for v in a { findDurationBadge(v, into: &out); if !out.isEmpty { return } }
        }
    }

    // Recursively walk a JSON subtree, building Videos from any videoRenderer /
    // gridVideoRenderer / lockupViewModel encountered, in document order, de-duplicated.
    private static func collectVideoItems(_ obj: Any?, fallbackChannelId: String, fallbackChannelName: String,
                                          seen: inout Set<String>, into out: inout [Video]) {
        if let d = obj as? [String: Any] {
            if let vr = dict(d["videoRenderer"]) ?? dict(d["gridVideoRenderer"]),
               let v = videoFromRenderer(vr, fallbackChannelId: fallbackChannelId), !seen.contains(v.id) {
                seen.insert(v.id); out.append(v)
            }
            if let lm = dict(d["lockupViewModel"]),
               let v = videoFromLockup(lm, fallbackChannelId: fallbackChannelId, fallbackChannelName: fallbackChannelName),
               !seen.contains(v.id) {
                seen.insert(v.id); out.append(v)
            }
            if let sm = dict(d["shortsLockupViewModel"]),
               let v = videoFromShortsLockup(sm, fallbackChannelId: fallbackChannelId, fallbackChannelName: fallbackChannelName),
               !seen.contains(v.id) {
                seen.insert(v.id); out.append(v)
            }
            for (_, v) in d {
                collectVideoItems(v, fallbackChannelId: fallbackChannelId, fallbackChannelName: fallbackChannelName, seen: &seen, into: &out)
            }
        } else if let a = obj as? [Any] {
            for v in a {
                collectVideoItems(v, fallbackChannelId: fallbackChannelId, fallbackChannelName: fallbackChannelName, seen: &seen, into: &out)
            }
        }
    }

    // MARK: - Channel response parsing

    private static func parseChannelResponse(_ data: Data, channelId: String) -> ([Video], Channel?, String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return ([], nil, nil)
        }

        captureVisitorData(root)

        // Channel metadata
        var channel: Channel? = nil
        var channelName = ""
        if let meta = dict(dict(root["metadata"])?["channelMetadataRenderer"]) {
            channelName = str(meta["title"]) ?? ""
            let cid = str(meta["externalId"]) ?? channelId
            var avatar = ""
            if let thumbs = arr(dict(meta["avatar"])?["thumbnails"]),
               let best = thumbs.last, let tu = str(best["url"]) {
                avatar = tu
            }
            channel = Channel(id: cid, name: channelName, thumbnailURL: avatar)
            channel?.channelDescription = str(meta["description"]) ?? ""
        }

        var seen = Set<String>()
        var results: [Video] = []
        collectVideoItems(root["contents"], fallbackChannelId: channelId,
                          fallbackChannelName: channelName, seen: &seen, into: &results)
        let token = findContinuationToken(root["contents"])
        return (results, channel, token)
    }

    // Parse a browse-continuation response (next page of channel videos).
    private static func parseContinuation(_ data: Data, channelName: String) -> ([Video], String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return ([], nil)
        }
        captureVisitorData(root)
        let actions = root["onResponseReceivedActions"]
        var seen = Set<String>()
        var results: [Video] = []
        collectVideoItems(actions, fallbackChannelId: "", fallbackChannelName: channelName, seen: &seen, into: &results)
        let token = findContinuationToken(actions)
        return (results, token)
    }

    // Find the first continuationItemRenderer token in a subtree (paging cursor).
    private static func findContinuationToken(_ obj: Any?) -> String? {
        if let d = obj as? [String: Any] {
            if let cir = dict(d["continuationItemRenderer"]),
               let ce = dict(cir["continuationEndpoint"]),
               let cc = dict(ce["continuationCommand"]),
               let token = str(cc["token"]), !token.isEmpty {
                return token
            }
            for (_, v) in d { if let t = findContinuationToken(v) { return t } }
        } else if let a = obj as? [Any] {
            for v in a { if let t = findContinuationToken(v) { return t } }
        }
        return nil
    }

    // MARK: - Player response parsing

    // returns (streams, video details, description, playabilityStatus, user-facing failure
    // reason, caption tracks)
    private static func parsePlayerResponse(_ data: Data, videoId: String) -> ([VideoStream], Video?, String, String, String, [CaptionTrack]) {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            DebugLog.log("YoutubeAPI", "player response id=\(videoId) — not valid JSON (\(data.count) bytes)")
            return ([], nil, "", "", "YouTube sent an unreadable response", [])
        }

        // playabilityStatus explains WHY a video has no usable streams even on a 200 response
        // (age-restricted, region-locked, LOGIN_REQUIRED, UNPLAYABLE, live, etc.) — this is the
        // #1 signal for the "video won't play" class of reports, since the player can return
        // zero formats/adaptiveFormats with no error surfaced anywhere else in the app.
        var status = ""
        var statusReason = ""
        if let ps = dict(root["playabilityStatus"]) {
            status = str(ps["status"]) ?? ""
            statusReason = str(ps["reason"]) ?? ""
            if status != "OK" {
                DebugLog.log("YoutubeAPI", "player response id=\(videoId) playabilityStatus=\(status) reason=\"\(statusReason)\"")
            }
        }

        // Video details
        var video: Video? = nil
        var description = ""
        if let details = dict(root["videoDetails"]) {
            description = str(details["shortDescription"]) ?? ""
            let title = str(details["title"]) ?? ""
            let channel = str(details["author"]) ?? ""
            let channelId = str(details["channelId"]) ?? ""
            let vid = str(details["videoId"]) ?? videoId
            let thumbURL = "https://i.ytimg.com/vi/\(vid)/mqdefault.jpg"
            let durSecs = str(details["lengthSeconds"]).flatMap({ Int($0) }) ?? 0
            let durText = "\(durSecs / 60):\(String(format: "%02d", durSecs % 60))"
            let viewsRaw = str(details["viewCount"]) ?? ""
            let views = viewsRaw.isEmpty ? "" : "\(formatViewCount(viewsRaw)) views"
            // publishDate from microformat: "2024-01-15" → keep the YYYY-MM-DD part
            var published = ""
            if let micro = dict(dict(root["microformat"])?["playerMicroformatRenderer"]),
               let pd = str(micro["publishDate"]) {
                published = String(pd.prefix(10))
            }
            video = Video(id: vid, title: title, channelName: channel, channelId: channelId,
                          thumbnailURL: thumbURL, durationText: durText, viewCountText: views,
                          publishedText: published)
        }

        // Stream URLs
        var streams: [VideoStream] = []
        // Formats that were listed but carry no direct `url` — YouTube's SABR delivery only
        // exposes `serverAbrStreamingUrl` (a protobuf/UMP stream we cannot consume), so the
        // response looks healthy while yielding nothing playable. Counted to tell that case
        // apart from "the video is genuinely gated".
        var formatsWithoutURL = 0
        if let sd = dict(root["streamingData"]) {
            for key in ["formats", "adaptiveFormats"] {
                guard let formats = sd[key] as? [[String: Any]] else { continue }
                for fmt in formats {
                    // The IOS client lists one audio format PER language (auto-dubbed tracks)
                    // plus a DRC (compressed-loudness) duplicate of the original. Everything
                    // downstream assumes `first { itag == 140 }` IS the audio track, so keep
                    // only the original, non-DRC one — otherwise HLS playback can end up muxing
                    // a random dubbed language.
                    if let track = dict(fmt["audioTrack"]),
                       !((track["audioIsDefault"] as? NSNumber)?.boolValue ?? false) { continue }
                    if (fmt["isDrc"] as? NSNumber)?.boolValue ?? false { continue }
                    if str(fmt["url"])?.isEmpty ?? true { formatsWithoutURL += 1 }
                    guard let url = str(fmt["url"]), !url.isEmpty else { continue }
                    // NSNumber.intValue — `as? Int` bridging is unreliable on the iOS 6 / Swift 5.1.5 runtime
                    guard let itag = (fmt["itag"] as? NSNumber)?.intValue
                        ?? Int(str(fmt["itag"]) ?? "") else { continue }
                    let mime = str(fmt["mimeType"]) ?? ""
                    let quality = str(fmt["qualityLabel"]) ?? str(fmt["quality"]) ?? ""
                    // contentLength is a decimal STRING in the JSON (or occasionally an
                    // NSNumber); 0 when absent (some formats omit it). Used for size estimates.
                    let clen = Int64(str(fmt["contentLength"]) ?? "")
                        ?? (fmt["contentLength"] as? NSNumber)?.int64Value ?? 0
                    // initRange/indexRange (DASH fMP4 adaptiveFormats only) are dicts with
                    // STRING "start"/"end" values. -1 = absent (muxed format).
                    func rangeEnd(_ v: Any?) -> Int64 {
                        guard let r = v as? [String: Any] else { return -1 }
                        return Int64(str(r["end"]) ?? "")
                            ?? (r["end"] as? NSNumber)?.int64Value ?? -1
                    }
                    streams.append(VideoStream(url: url, itag: itag, mimeType: mime,
                                               quality: quality, contentLength: clen,
                                               initEnd: rangeEnd(fmt["initRange"]),
                                               indexEnd: rangeEnd(fmt["indexRange"])))
                }
            }
        }

        // Sort: prefer muxed MP4 (itag 18 = 360p, 22 = 720p) first
        streams.sort { a, b in
            let preferredItags = [18, 22, 137, 248]
            let ai = preferredItags.firstIndex(of: a.itag) ?? 99
            let bi = preferredItags.firstIndex(of: b.itag) ?? 99
            return ai < bi
        }

        // Why is there nothing to play? Reported verbatim to the user instead of the old
        // catch-all "No streams available", which hid gated/paid/bot-check cases alike.
        var failure = ""
        if streams.isEmpty {
            if !statusReason.isEmpty {
                failure = statusReason
            } else if formatsWithoutURL > 0 {
                failure = "YouTube served no direct stream for this video"
                DebugLog.log("YoutubeAPI", "id=\(videoId) SABR-only: \(formatsWithoutURL) formats, none with a url")
            } else if !status.isEmpty, status != "OK" {
                failure = "Unavailable (\(status))"
            } else {
                failure = "No streams available"
            }
        }

        // Caption tracks. Ships in the same player response as the streams, so subtitles
        // cost no extra API call — only the transcript GET once the user picks a track.
        // The ANDROID and IOS clients both label tracks with `name.runs[]` (some others use
        // `simpleText`), hence both lookups.
        var captions: [CaptionTrack] = []
        if let tracklist = dict(dict(root["captions"])?["playerCaptionsTracklistRenderer"]),
           let tracks = arr(tracklist["captionTracks"]) {
            for t in tracks {
                guard let base = str(t["baseUrl"]), !base.isEmpty else { continue }
                let lang = str(t["languageCode"]) ?? ""
                let label = str(arr(dict(t["name"])?["runs"])?.first?["text"])
                    ?? str(dict(t["name"])?["simpleText"])
                    ?? lang
                captions.append(CaptionTrack(baseUrl: base, languageCode: lang,
                                             name: label.isEmpty ? lang : label,
                                             isASR: (str(t["kind"]) ?? "") == "asr"))
            }
        }

        return (streams, video, description, status, failure, captions)
    }
}
