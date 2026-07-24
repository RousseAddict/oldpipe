import Foundation

// MARK: - YoutubeAPI
// Accesses YouTube via the internal innertube API.
// As of 2024+, YouTube added attestation (poToken/integrity) to the ANDROID/IOS
// innertube clients, which now return HTTP 400 FAILED_PRECONDITION. Two clients
// still work without attestation:
//   - WEB        : for search   (returns twoColumnSearchResultsRenderer)
//   - ANDROID_VR : for player   (returns streamingData with direct, un-ciphered URLs)
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

    // ANDROID_VR client — used for the player. Still returns direct stream URLs.
    private static let vrClient: [String: Any] = [
        "clientName": "ANDROID_VR",
        "clientVersion": "1.60.19",
        "deviceModel": "Quest 3",
        "androidSdkVersion": 32,
        "osName": "Android",
        "osVersion": "12",
        "hl": "en",
        "gl": "US"
    ]
    private static let vrUserAgent =
        "com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12; GB) gzip"

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

    // completion: (streams, video details, full description text)
    static func getStreams(videoId: String, completion: @escaping ([VideoStream], Video?, String) -> Void) {
        if cachedVisitorData.isEmpty {
            bootstrapVisitorData { performPlayer(videoId: videoId, completion: completion) }
        } else {
            performPlayer(videoId: videoId, completion: completion)
        }
    }

    private static func performPlayer(videoId: String, completion: @escaping ([VideoStream], Video?, String) -> Void) {
        var client = vrClient
        if !cachedVisitorData.isEmpty { client["visitorData"] = cachedVisitorData }
        let payload = body(client: client, extra: ["videoId": videoId])
        guard let jsonStr = toJSON(payload) else { completion([], nil, ""); return }
        let url = "\(baseURL)/player?prettyPrint=false"
        CurlFetcher.postJSON(url: url, body: jsonStr, headers: jsonHeaders,
                             userAgent: vrUserAgent, timeout: 30, priority: true) { data in
            guard let data = data else { completion([], nil, ""); return }
            playerParseQueue.async {
                let (streams, video, desc) = parsePlayerResponse(data, videoId: videoId)
                DispatchQueue.main.async { completion(streams, video, desc) }
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

    private static func parsePlayerResponse(_ data: Data, videoId: String) -> ([VideoStream], Video?, String) {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            DebugLog.log("YoutubeAPI", "player response id=\(videoId) — not valid JSON (\(data.count) bytes)")
            return ([], nil, "")
        }

        // playabilityStatus explains WHY a video has no usable streams even on a 200 response
        // (age-restricted, region-locked, LOGIN_REQUIRED, UNPLAYABLE, live, etc.) — this is the
        // #1 signal for the "video won't play" class of reports, since the player can return
        // zero formats/adaptiveFormats with no error surfaced anywhere else in the app.
        if let ps = dict(root["playabilityStatus"]) {
            let status = str(ps["status"]) ?? ""
            let reason = str(ps["reason"]) ?? ""
            if status != "OK" {
                DebugLog.log("YoutubeAPI", "player response id=\(videoId) playabilityStatus=\(status) reason=\"\(reason)\"")
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
        if let sd = dict(root["streamingData"]) {
            for key in ["formats", "adaptiveFormats"] {
                guard let formats = sd[key] as? [[String: Any]] else { continue }
                for fmt in formats {
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

        return (streams, video, description)
    }
}
