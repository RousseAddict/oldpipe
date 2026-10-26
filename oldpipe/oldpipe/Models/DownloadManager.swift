import Foundation

// MARK: - DownloadManager
// Persists downloaded videos to Documents/downloads/<id>.mp4 and tracks metadata
// in UserDefaults so they can be replayed offline and managed in DownloadsVC.

class DownloadManager {

    private static let defaultsKey = "downloaded_videos"
    private static let positionsKey = "playback_positions"
    private static let watchedKey = "watched_videos"

    // Documents/downloads — Documents is NOT auto-purged (unlike Caches), so offline
    // content survives. NSSearchPathForDirectoriesInDomains resolved once (static let).
    private static let dirPath: String = {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        let dir = (docs as NSString).appendingPathComponent("downloads")
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir,
                                                     withIntermediateDirectories: true, attributes: nil)
        }
        return dir
    }()

    // MARK: - Storage layout
    //
    // Two shapes live side by side, because the two download paths produce different things:
    //
    //   .progressive  downloads/<id>.mp4      one muxed file, copied byte-for-byte (itag 18).
    //   .hls          downloads/<id>/         index.m3u8 + seg<i>.ts, transmuxed at download
    //                                         time by OfflineDownloader. The only way to store
    //                                         >360p, which innertube serves as separate
    //                                         video-only + audio-only DASH streams.
    //
    // Every entry predating the HLS path is .progressive and keeps working untouched.
    enum Kind { case none, progressive, hls }

    static func filePath(for videoId: String) -> String {
        return (dirPath as NSString).appendingPathComponent("\(videoId).mp4")
    }

    // Directory holding an HLS download's playlist + segments.
    static func bundleDir(for videoId: String) -> String {
        return (dirPath as NSString).appendingPathComponent(videoId)
    }

    private static func playlistPath(for videoId: String) -> String {
        return (bundleDir(for: videoId) as NSString).appendingPathComponent("index.m3u8")
    }

    // Which shape is on disk for this video, if any. A progressive file wins when both exist
    // (it can only happen mid-switch, and the .mp4 is the one that plays without the proxy).
    static func kind(for videoId: String) -> Kind {
        if FileManager.default.fileExists(atPath: filePath(for: videoId)) { return .progressive }
        if FileManager.default.fileExists(atPath: playlistPath(for: videoId)) { return .hls }
        return .none
    }

    // Something is present on disk (may be a complete OR partial download).
    static func fileExists(_ videoId: String) -> Bool {
        return kind(for: videoId) != .none
    }

    // "Downloaded" = fully finished AND present. Partial downloads are NOT playable
    // offline, so they don't count here (VideoPlayerVC will re-stream / re-download).
    static func isDownloaded(_ videoId: String) -> Bool {
        return fileExists(videoId) && isComplete(videoId)
    }

    // Whether the registered download finished. Legacy entries (no flag) = complete.
    static func isComplete(_ videoId: String) -> Bool {
        guard let entry = rawList().first(where: { ($0["id"] as? String) == videoId }) else { return false }
        if let n = entry["complete"] as? NSNumber { return n.boolValue }
        return true
    }

    // Register metadata after a successful download (most-recent first, de-duplicated).
    static func register(_ video: Video) {
        store(video, complete: true)
    }

    // Register a started-but-unfinished download so it shows in DownloadsVC while in
    // progress (and remains visible, flagged incomplete, if it fails midway).
    static func registerPartial(_ video: Video) {
        if isComplete(video.id) { return }   // don't downgrade an already-complete entry
        store(video, complete: false)
    }

    // The quality an entry was downloaded at ("360p", "720p"...), "" for entries written before
    // quality was selectable. Shown in DownloadsVC and used by the download modal to mark the
    // tier already on disk.
    static func qualityLabel(for videoId: String) -> String {
        guard let entry = rawList().first(where: { ($0["id"] as? String) == videoId }) else { return "" }
        return (entry["dl_quality"] as? String) ?? ""
    }

    // True when this download holds AUDIO ONLY. Stored rather than inferred, because an
    // audio-only bundle is byte-shaped exactly like a video one. The player uses it to keep the
    // thumbnail on screen instead of showing an empty black video area.
    // NSNumber-boxed: a direct `as? Bool` returns nil on the 5.1.5 runtime.
    static func isAudioOnly(_ videoId: String) -> Bool {
        guard let entry = rawList().first(where: { ($0["id"] as? String) == videoId }) else { return false }
        return ((entry["dl_audio"] as? NSNumber)?.boolValue) ?? false
    }

    // `quality` nil = keep whatever the existing entry recorded. That is what lets register()
    // flip the complete flag at the end of a download without wiping the quality that
    // startHLSDownload stored when it began.
    private static func store(_ video: Video, complete: Bool, quality: String? = nil,
                              audioOnly: Bool? = nil) {
        var list = rawList()
        let existing = list.first { ($0["id"] as? String) == video.id }
        list.removeAll { ($0["id"] as? String) == video.id }
        var dict = video.toDict()
        dict["complete"] = complete
        if let q = quality {
            dict["dl_quality"] = q
        } else if let q = existing?["dl_quality"] as? String {
            dict["dl_quality"] = q
        }
        if let a = audioOnly {
            dict["dl_audio"] = a
        } else if let a = existing?["dl_audio"] {
            dict["dl_audio"] = a
        }
        list.insert(dict, at: 0)
        UserDefaults.standard.set(list, forKey: defaultsKey)
        UserDefaults.standard.synchronize()
    }

    // Delete whichever shape is on disk. Both are attempted: a quality switch can briefly leave
    // a stale .mp4 next to a new bundle, and leaving either behind would strand the bytes.
    private static func removeFiles(_ videoId: String) {
        try? FileManager.default.removeItem(atPath: filePath(for: videoId))
        try? FileManager.default.removeItem(atPath: bundleDir(for: videoId))
    }

    static func remove(_ videoId: String) {
        // Stop an in-flight transfer FIRST. Without this, deleting a downloading row leaves
        // OfflineDownloader writing segments into the directory we just deleted — and its
        // completion would then re-register the entry the user asked us to remove.
        cancelDownload(videoId)
        PhotoExporter.shared.downloadRemoved(videoId)   // same reason: it reads the files deleted below
        removeFiles(videoId)
        var list = rawList()
        list.removeAll { ($0["id"] as? String) == videoId }
        UserDefaults.standard.set(list, forKey: defaultsKey)
        clearPosition(for: videoId)
        clearWatched(videoId)
        UserDefaults.standard.synchronize()
    }

    // How to play a completed download. A progressive file plays straight off disk; an HLS
    // bundle has to go back through StreamProxy, because AVPlayer on iOS 6/7 will not open a
    // playlist from a file:// URL. Either way there is no network involved — callers treat
    // both as local (no reconnect watchdog). nil = nothing playable for this id.
    //
    // Centralised here so the player VC and StreamResolver can't drift on which shape is which.
    static func playbackURL(for videoId: String) -> URL? {
        switch kind(for: videoId) {
        case .none:        return nil
        case .progressive: return URL(fileURLWithPath: filePath(for: videoId))
        case .hls:         return StreamProxy.shared.offlineHLSURL(dir: bundleDir(for: videoId))
        }
    }

    // Free space on the Documents volume, in bytes. 0 when it can't be determined (in which
    // case callers skip the "not enough room" warning rather than blocking a download).
    static func freeDiskBytes() -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: dirPath),
              let n = (attrs[.systemFreeSize] as? NSNumber)?.int64Value else { return 0 }
        return n
    }

    // MARK: - Download lifecycle (manager-owned, so a transfer survives navigation)

    // id → latest progress 0..1 for an in-flight download. Touched only on the main thread
    // (CurlFetcher dispatches both its progress and completion callbacks to main), so no lock.
    private static var inFlight: [String: Float] = [:]

    static func isDownloading(_ videoId: String) -> Bool { return inFlight[videoId] != nil }
    static func progress(for videoId: String) -> Float { return inFlight[videoId] ?? 0 }

    // Owns the whole transfer + completion. Because the manager (not a VC) holds the
    // completion, the download still registers as complete after you navigate away.
    // No-op if this id is already downloading.
    static func startDownload(_ video: Video, url: String, quality: String = "360p",
                              captions: [CaptionTrack] = []) {
        if inFlight[video.id] != nil { return }
        let path = filePath(for: video.id)
        removeFiles(video.id)             // drop an HLS bundle left by a previous quality
        OfflineDownloader.saveCaptionsOnly(captions, for: video.id)
        store(video, complete: false, quality: quality, audioOnly: false)  // visible (Incomplete) while in progress
        inFlight[video.id] = 0
        CurlFetcher.downloadToFile(url: url, outputPath: path, progress: { p in
            inFlight[video.id] = p
        }) { success in
            inFlight[video.id] = nil
            if success { register(video) } // on failure the partial entry remains (Incomplete)
            PhotoExporter.shared.downloadFinished(video, success: success)
        }
    }

    // >360p download: hands off to OfflineDownloader, which transmuxes the DASH video+audio
    // pair into downloads/<id>/ segment by segment. Same ownership rule as startDownload — the
    // manager holds the completion, so the transfer survives navigating away from the player.
    //
    // Re-downloading at a DIFFERENT quality wipes the old bundle first (its segments belong to
    // another itag and would be silently reused by the resume check). Re-downloading at the
    // SAME quality deliberately keeps them: that is the resume path.
    static func startHLSDownload(_ video: Video, videoStream: VideoStream, audioStream: VideoStream,
                                 quality: String, captions: [CaptionTrack] = []) {
        if inFlight[video.id] != nil { return }
        if qualityLabel(for: video.id) != quality {
            removeFiles(video.id)
        } else {
            try? FileManager.default.removeItem(atPath: filePath(for: video.id))
        }
        store(video, complete: false, quality: quality, audioOnly: false)
        inFlight[video.id] = 0
        OfflineDownloader.start(video: video, videoStream: videoStream, audioStream: audioStream,
                                captions: captions,
                                progress: { p in
            inFlight[video.id] = p
        }) { success in
            inFlight[video.id] = nil
            if success { store(video, complete: true, quality: quality, audioOnly: false) }
            PhotoExporter.shared.downloadFinished(video, success: success)
        }
    }

    // Audio-only download (itag 140). Same bundle shape as a video download — the entry's
    // dl_audio flag is what tells playback to keep the artwork on screen.
    static func startAudioDownload(_ video: Video, audioStream: VideoStream, quality: String,
                                   captions: [CaptionTrack] = []) {
        if inFlight[video.id] != nil { return }
        // Any previous download of this video held different content (video, or another
        // bitrate), so its segments must not be reused by the resume check.
        if qualityLabel(for: video.id) != quality || !isAudioOnly(video.id) {
            removeFiles(video.id)
        }
        store(video, complete: false, quality: quality, audioOnly: true)
        inFlight[video.id] = 0
        OfflineDownloader.startAudio(video: video, audioStream: audioStream, captions: captions,
                                     progress: { p in
            inFlight[video.id] = p
        }) { success in
            inFlight[video.id] = nil
            if success { store(video, complete: true, quality: quality, audioOnly: true) }
        }
    }

    // Stop an in-flight download. Only the HLS path can actually be interrupted mid-transfer;
    // a progressive copy runs inside one curl call and is left to finish.
    static func cancelDownload(_ videoId: String) {
        guard inFlight[videoId] != nil else { return }
        OfflineDownloader.cancel(videoId)
    }

    // MARK: - Resume playback position (seconds)

    private static func positionsDict() -> [String: Any] {
        return UserDefaults.standard.dictionary(forKey: positionsKey) ?? [:]
    }

    // Stored as NSNumber — read via .doubleValue (the iOS 6 / Swift 5.1.5 runtime
    // returns nil for a direct `as? Double` cast).
    static func position(for videoId: String) -> Double {
        return (positionsDict()[videoId] as? NSNumber)?.doubleValue ?? 0
    }

    static func savePosition(_ seconds: Double, for videoId: String) {
        var d = positionsDict()
        d[videoId] = seconds
        UserDefaults.standard.set(d, forKey: positionsKey)
        clearWatched(videoId)   // a mid-video position means it's in progress again
    }

    static func clearPosition(for videoId: String) {
        var d = positionsDict()
        d[videoId] = nil
        UserDefaults.standard.set(d, forKey: positionsKey)
    }

    // MARK: - Watched (fully played to the end)

    // Marked when playback reaches the end (see VideoPlayer). The resume position is
    // cleared so it replays from the start, but the "watched" flag persists so DownloadsVC
    // can show a full progress bar. Cleared again as soon as a new mid-video position saves.
    static func markWatched(_ videoId: String) {
        clearPosition(for: videoId)
        var ids = (UserDefaults.standard.array(forKey: watchedKey) as? [String]) ?? []
        if !ids.contains(videoId) { ids.append(videoId) }
        UserDefaults.standard.set(ids, forKey: watchedKey)
    }

    static func isWatched(_ videoId: String) -> Bool {
        let ids = (UserDefaults.standard.array(forKey: watchedKey) as? [String]) ?? []
        return ids.contains(videoId)
    }

    static func clearWatched(_ videoId: String) {
        var ids = (UserDefaults.standard.array(forKey: watchedKey) as? [String]) ?? []
        ids.removeAll { $0 == videoId }
        UserDefaults.standard.set(ids, forKey: watchedKey)
    }

    // Delete every downloaded file and clear all download-related state, including
    // playback positions and watched flags for streamed-only videos (Settings → Reset All).
    static func clearAll() {
        for id in inFlight.keys { OfflineDownloader.cancel(id) }
        for entry in rawList() {
            if let id = entry["id"] as? String { removeFiles(id) }
        }
        inFlight.removeAll()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: positionsKey)
        UserDefaults.standard.removeObject(forKey: watchedKey)
        UserDefaults.standard.synchronize()
    }

    // All videos whose files still exist on disk (complete OR partial).
    static func all() -> [Video] {
        return rawList().compactMap { Video.from(dict: $0) }
            .filter { fileExists($0.id) }
    }

    // Human-readable size on disk, e.g. "11.4 MB". For an HLS bundle this sums every segment,
    // so it stays meaningful while a download is still filling the directory. DownloadsVC
    // precomputes it once per reload rather than per cell (it walks the directory).
    static func fileSizeText(for videoId: String) -> String {
        let bytes = Double(diskBytes(for: videoId))
        guard bytes > 0 else { return "" }
        return String(format: "%.1f MB", bytes / (1024.0 * 1024.0))
    }

    // Bytes on disk for whichever shape this download is (0 = nothing there).
    static func diskBytes(for videoId: String) -> Int64 {
        switch kind(for: videoId) {
        case .none:        return 0
        case .progressive: return byteSize(filePath(for: videoId))
        case .hls:         return bundleByteSize(for: videoId)
        }
    }

    // Total bytes of an HLS bundle (playlist + every segment written so far).
    static func bundleByteSize(for videoId: String) -> Int64 {
        let dir = bundleDir(for: videoId)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return 0 }
        var total: Int64 = 0
        for name in names {
            total += byteSize((dir as NSString).appendingPathComponent(name))
        }
        return total
    }

    // NSNumber-boxed read: a direct `as? Int64` returns nil on the 5.1.5 runtime (iOS 6).
    private static func byteSize(_ path: String) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let n = (attrs[.size] as? NSNumber)?.int64Value else { return 0 }
        return n
    }

    private static func rawList() -> [[String: Any]] {
        return (UserDefaults.standard.array(forKey: defaultsKey) as? [[String: Any]]) ?? []
    }
}
