import Foundation

// MARK: - PlaylistManager
// Persists user-created local playlists to UserDefaults (key `local_playlists`).
// Newest playlist first; videos kept in insertion order (most-recently-added last),
// de-duplicated by id. Mirrors the SubscriptionManager / DownloadManager pattern.

class PlaylistManager {

    private static let defaultsKey = "local_playlists"

    static func all() -> [Playlist] {
        return rawList().compactMap { Playlist.from(dict: $0) }
    }

    static func playlist(id: String) -> Playlist? {
        return rawList().first { ($0["id"] as? String) == id }.flatMap { Playlist.from(dict: $0) }
    }

    // Create an empty playlist (inserted newest-first) and return it.
    @discardableResult
    static func create(name: String) -> Playlist {
        let playlist = Playlist(id: UUID().uuidString, name: name, videos: [],
                                createdAt: Date().timeIntervalSince1970)
        var list = rawList()
        list.insert(playlist.toDict(), at: 0)
        save(list)
        return playlist
    }

    static func rename(id: String, to name: String) {
        var list = rawList()
        for i in 0..<list.count where (list[i]["id"] as? String) == id {
            list[i]["name"] = name
        }
        save(list)
    }

    static func delete(id: String) {
        var list = rawList()
        list.removeAll { ($0["id"] as? String) == id }
        save(list)
    }

    // Remove all playlists (Settings → Reset All).
    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.synchronize()
    }

    static func contains(videoId: String, in playlistId: String) -> Bool {
        guard let pl = playlist(id: playlistId) else { return false }
        return pl.videos.contains { $0.id == videoId }
    }

    // Append to the end; if already present it's moved to the end (de-duplicated by id).
    static func add(video: Video, to playlistId: String) {
        mutateVideos(of: playlistId) { videos in
            videos.removeAll { ($0["id"] as? String) == video.id }
            videos.append(video.toDict())
        }
    }

    static func remove(videoId: String, from playlistId: String) {
        mutateVideos(of: playlistId) { videos in
            videos.removeAll { ($0["id"] as? String) == videoId }
        }
    }

    // Merge imported playlists into storage (config import). Upsert by id: an existing
    // playlist keeps its position and gains any videos not already present (de-duplicated,
    // appended in import order); a playlist with an unknown id is inserted newest-first.
    static func merge(_ playlists: [Playlist]) {
        var list = rawList()
        for pl in playlists {
            if let idx = list.firstIndex(where: { ($0["id"] as? String) == pl.id }) {
                var videos = (list[idx]["videos"] as? [[String: Any]]) ?? []
                let existing = Set(videos.compactMap { $0["id"] as? String })
                for v in pl.videos where !existing.contains(v.id) {
                    videos.append(v.toDict())
                }
                list[idx]["videos"] = videos
            } else {
                list.insert(pl.toDict(), at: 0)
            }
        }
        save(list)
    }

    // MARK: - Private

    private static func mutateVideos(of playlistId: String, _ body: (inout [[String: Any]]) -> Void) {
        var list = rawList()
        for i in 0..<list.count where (list[i]["id"] as? String) == playlistId {
            var videos = (list[i]["videos"] as? [[String: Any]]) ?? []
            body(&videos)
            list[i]["videos"] = videos
        }
        save(list)
    }

    private static func save(_ list: [[String: Any]]) {
        UserDefaults.standard.set(list, forKey: defaultsKey)
        UserDefaults.standard.synchronize()
    }

    private static func rawList() -> [[String: Any]] {
        return (UserDefaults.standard.array(forKey: defaultsKey) as? [[String: Any]]) ?? []
    }
}
