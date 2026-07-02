import Foundation

// MARK: - HistoryManager
// Persists the last watched videos to UserDefaults (most-recent first, de-duplicated,
// capped at maxCount so it never grows without bound). A video is recorded when playback
// actually begins (VideoPlayer.applyResumeAndPlay), so failed loads don't pollute history.
// Replaying a video promotes it back to the top instead of creating a duplicate.
// Shown by HistoryVC.

class HistoryManager {

    private static let defaultsKey = "history_videos"
    static let maxCount = 30

    static func all() -> [Video] {
        return rawList().compactMap { Video.from(dict: $0) }
    }

    // Record a played video at the top: drop any earlier entry for the same id
    // (promote-to-top, no duplicates), then trim to maxCount.
    static func record(_ video: Video) {
        guard !video.id.isEmpty else { return }
        var list = rawList()
        list.removeAll { ($0["id"] as? String) == video.id }
        list.insert(video.toDict(), at: 0)
        if list.count > maxCount { list = Array(list.prefix(maxCount)) }
        UserDefaults.standard.set(list, forKey: defaultsKey)
        UserDefaults.standard.synchronize()
    }

    static func remove(id: String) {
        var list = rawList()
        list.removeAll { ($0["id"] as? String) == id }
        UserDefaults.standard.set(list, forKey: defaultsKey)
        UserDefaults.standard.synchronize()
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.synchronize()
    }

    private static func rawList() -> [[String: Any]] {
        return (UserDefaults.standard.array(forKey: defaultsKey) as? [[String: Any]]) ?? []
    }
}
