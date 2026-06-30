import Foundation

// MARK: - DownloadManager
// Persists downloaded videos to Documents/downloads/<id>.mp4 and tracks metadata
// in UserDefaults so they can be replayed offline and managed in DownloadsVC.

class DownloadManager {

    private static let defaultsKey = "downloaded_videos"
    private static let positionsKey = "playback_positions"

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

    // Register metadata after a successful download (most-recent first, de-duplicated)
    static func register(_ video: Video) {
        store(video, complete: true)
    }

    // Register a started-but-unfinished download so it shows in DownloadsVC while in
    // progress (and remains visible, flagged incomplete, if it fails midway).
    static func registerPartial(_ video: Video) {
        if isComplete(video.id) { return }   // don't downgrade an already-complete entry
        store(video, complete: false)
    }

    private static func store(_ video: Video, complete: Bool) {
        var list = rawList()
        list.removeAll { ($0["id"] as? String) == video.id }
        var dict = video.toDict()
        dict["complete"] = complete
        list.insert(dict, at: 0)
        UserDefaults.standard.set(list, forKey: defaultsKey)
        UserDefaults.standard.synchronize()
    }

    static func remove(_ videoId: String) {
        try? FileManager.default.removeItem(atPath: filePath(for: videoId))
        var list = rawList()
        list.removeAll { ($0["id"] as? String) == videoId }
        UserDefaults.standard.set(list, forKey: defaultsKey)
        clearPosition(for: videoId)
        UserDefaults.standard.synchronize()
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
    }

    static func clearPosition(for videoId: String) {
        var d = positionsDict()
        d[videoId] = nil
        UserDefaults.standard.set(d, forKey: positionsKey)
    }

    // All videos whose files still exist on disk — complete OR partial.
    static func all() -> [Video] {
        return rawList().compactMap { Video.from(dict: $0) }.filter { fileExists($0.id) }
    }

    // Human-readable file size, e.g. "11.4 MB"
    static func fileSizeText(for videoId: String) -> String {
        let path = filePath(for: videoId)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let bytes = (attrs[.size] as? NSNumber)?.doubleValue else { return "" }
        let mb = bytes / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb)
    }

    private static func rawList() -> [[String: Any]] {
        return (UserDefaults.standard.array(forKey: defaultsKey) as? [[String: Any]]) ?? []
    }
}
