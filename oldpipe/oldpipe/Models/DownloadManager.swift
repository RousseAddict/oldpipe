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

    static func filePath(for videoId: String) -> String {
        return (dirPath as NSString).appendingPathComponent("\(videoId).mp4")
    }

    // Temp files for the two adaptive tracks of an HD download, before they're muxed into
    // the final .mp4 (then deleted). Distinct extensions so they don't collide with the
    // final file and aren't picked up by all()/fileExists (which look for .mp4).
    private static func tempVideoPath(_ videoId: String) -> String {
        return (dirPath as NSString).appendingPathComponent("\(videoId).vpart")
    }
    private static func tempAudioPath(_ videoId: String) -> String {
        return (dirPath as NSString).appendingPathComponent("\(videoId).apart")
    }

    // The file is present on disk (may be a complete OR partial download).
    static func fileExists(_ videoId: String) -> Bool {
        return FileManager.default.fileExists(atPath: filePath(for: videoId))
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
    // quality (e.g. "720p") is stored so DownloadsVC can show an HD badge; nil keeps any
    // existing value (so completing a partial HD entry doesn't lose its quality tag).
    static func register(_ video: Video, quality: String? = nil) {
        store(video, complete: true, quality: quality)
    }

    // Register a started-but-unfinished download so it shows in DownloadsVC while in
    // progress (and remains visible, flagged incomplete, if it fails midway).
    static func registerPartial(_ video: Video) {
        if isComplete(video.id) { return }   // don't downgrade an already-complete entry
        store(video, complete: false)
    }

    // Quality tag persisted with a download ("360p"/"720p"/"1080p"), nil if untagged.
    static func quality(for videoId: String) -> String? {
        return rawList().first { ($0["id"] as? String) == videoId }?["quality"] as? String
    }

    private static func store(_ video: Video, complete: Bool, quality: String? = nil) {
        var list = rawList()
        let existingQuality = (list.first { ($0["id"] as? String) == video.id })?["quality"] as? String
        list.removeAll { ($0["id"] as? String) == video.id }
        var dict = video.toDict()
        dict["complete"] = complete
        if let q = quality ?? existingQuality { dict["quality"] = q }
        list.insert(dict, at: 0)
        UserDefaults.standard.set(list, forKey: defaultsKey)
        UserDefaults.standard.synchronize()
    }

    static func remove(_ videoId: String) {
        try? FileManager.default.removeItem(atPath: filePath(for: videoId))
        try? FileManager.default.removeItem(atPath: tempVideoPath(videoId))
        try? FileManager.default.removeItem(atPath: tempAudioPath(videoId))
        var list = rawList()
        list.removeAll { ($0["id"] as? String) == videoId }
        UserDefaults.standard.set(list, forKey: defaultsKey)
        clearPosition(for: videoId)
        clearWatched(videoId)
        UserDefaults.standard.synchronize()
    }

    // MARK: - Download lifecycle (manager-owned, so a transfer survives navigation)

    // id → latest progress 0..1 for an in-flight download. Touched only on the main thread
    // (CurlFetcher dispatches both its progress and completion callbacks to main), so no lock.
    private static var inFlight: [String: Float] = [:]

    // ids currently in the on-device mux phase of an HD download (both tracks downloaded,
    // combining into the final mp4). Still "in flight" (inFlight != nil) during this phase.
    // Touched only on the main thread (CurlFetcher + StreamMuxer callbacks land on main).
    private static var muxing: Set<String> = []

    // Short diagnostic from the most recent HD mux failure (nil after a success). Surfaced by
    // VideoPlayerVC so an on-device mux failure — which the macOS spike can't reproduce — can be
    // root-caused from the screen. Main-thread only.
    static var lastMuxError: String?

    static func isDownloading(_ videoId: String) -> Bool { return inFlight[videoId] != nil }
    static func isMuxing(_ videoId: String) -> Bool { return muxing.contains(videoId) }
    static func progress(for videoId: String) -> Float { return inFlight[videoId] ?? 0 }

    // Owns the whole transfer + completion. Because the manager (not a VC) holds the
    // completion, the download still registers as complete after you navigate away.
    // No-op if this id is already downloading.
    static func startDownload(_ video: Video, url: String) {
        if inFlight[video.id] != nil { return }
        let path = filePath(for: video.id)
        try? FileManager.default.removeItem(atPath: path)
        registerPartial(video)            // visible (flagged incomplete) while in progress
        inFlight[video.id] = 0
        CurlFetcher.downloadToFile(url: url, outputPath: path, progress: { p in
            inFlight[video.id] = p
        }) { success in
            inFlight[video.id] = nil
            if success { register(video) } // on failure the partial entry remains (Incomplete)
        }
    }

    // HD (>360p) download: fetch the H.264 video-only track and the AAC audio-only track
    // SEQUENTIALLY (never concurrently — the shipped OpenSSL 3.x serializes TLS handshakes,
    // so two parallel googlevideo transfers stall each other), then mux them on-device into
    // the final <id>.mp4. Progress is weighted by each track's byte size (video dominates);
    // the mux phase is reported separately via isMuxing(). No-op if already in flight.
    static func startDownloadHD(_ video: Video, videoStream: VideoStream,
                                audioStream: VideoStream, quality: String) {
        if inFlight[video.id] != nil { return }
        lastMuxError = nil
        let finalPath = filePath(for: video.id)
        let vTmp = tempVideoPath(video.id)
        let aTmp = tempAudioPath(video.id)
        try? FileManager.default.removeItem(atPath: finalPath)
        try? FileManager.default.removeItem(atPath: vTmp)
        try? FileManager.default.removeItem(atPath: aTmp)
        registerPartial(video)
        inFlight[video.id] = 0

        // Weight the combined progress bar by each track's byte size.
        let vBytes = Double(max(videoStream.contentLength, 1))
        let aBytes = Double(max(audioStream.contentLength, 1))
        let vWeight = Float(vBytes / (vBytes + aBytes))

        CurlFetcher.downloadToFile(url: videoStream.url, outputPath: vTmp, progress: { p in
            inFlight[video.id] = p * vWeight
        }) { vOk in
            guard vOk else {
                inFlight[video.id] = nil
                try? FileManager.default.removeItem(atPath: vTmp)
                return                              // partial entry remains (Incomplete)
            }
            CurlFetcher.downloadToFile(url: audioStream.url, outputPath: aTmp, progress: { p in
                inFlight[video.id] = vWeight + p * (1 - vWeight)
            }) { aOk in
                guard aOk else {
                    inFlight[video.id] = nil
                    try? FileManager.default.removeItem(atPath: vTmp)
                    try? FileManager.default.removeItem(atPath: aTmp)
                    return
                }
                // Both tracks present — mux into the final file (passthrough, no re-encode).
                inFlight[video.id] = 1.0
                muxing.insert(video.id)
                StreamMuxer.mux(videoPath: vTmp, audioPath: aTmp, outputPath: finalPath) { muxOk, muxErr in
                    muxing.remove(video.id)
                    inFlight[video.id] = nil
                    try? FileManager.default.removeItem(atPath: vTmp)
                    try? FileManager.default.removeItem(atPath: aTmp)
                    if muxOk {
                        lastMuxError = nil
                        register(video, quality: quality)
                    } else {
                        lastMuxError = muxErr   // surfaced by VideoPlayerVC as "Download failed — <reason>"
                    }
                    // on failure: partial entry remains, no final file → shows Incomplete
                }
            }
        }
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
        for entry in rawList() {
            if let id = entry["id"] as? String {
                try? FileManager.default.removeItem(atPath: filePath(for: id))
                try? FileManager.default.removeItem(atPath: tempVideoPath(id))
                try? FileManager.default.removeItem(atPath: tempAudioPath(id))
            }
        }
        inFlight.removeAll()
        muxing.removeAll()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: positionsKey)
        UserDefaults.standard.removeObject(forKey: watchedKey)
        UserDefaults.standard.synchronize()
    }

    // All videos whose files still exist on disk (complete OR partial), PLUS any in-flight
    // download. An HD download writes to .vpart/.apart temp files and only creates the final
    // <id>.mp4 after muxing, so it would fail the fileExists check for the whole download +
    // mux — include it via isDownloading (true until the mux completes) so it stays visible
    // in DownloadsVC throughout, exactly like a 360p download.
    static func all() -> [Video] {
        return rawList().compactMap { Video.from(dict: $0) }
            .filter { fileExists($0.id) || isDownloading($0.id) }
    }

    // Human-readable file size, e.g. "11.4 MB"
    static func fileSizeText(for videoId: String) -> String {
        let path = filePath(for: videoId)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let bytes = (attrs[.size] as? NSNumber)?.doubleValue else { return "" }
        let mb = bytes / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb)
    }

    // Format a byte count for the download-quality size estimates ("~48 MB" / "~640 KB").
    static func sizeText(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024.0 * 1024.0)
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024.0)
    }

    private static func rawList() -> [[String: Any]] {
        return (UserDefaults.standard.array(forKey: defaultsKey) as? [[String: Any]]) ?? []
    }
}
