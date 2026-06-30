import Foundation

// MARK: - Playlist
// A user-created local playlist. Stores full Video metadata (not just ids) so it
// renders offline and survives a video later 404ing. Videos kept in insertion order.

struct Playlist {
    let id: String          // UUID
    var name: String
    var videos: [Video]
    let createdAt: Double    // epoch seconds

    func toDict() -> [String: Any] {
        return [
            "id": id,
            "name": name,
            "videos": videos.map { $0.toDict() },
            "createdAt": createdAt
        ]
    }

    static func from(dict: [String: Any]) -> Playlist? {
        guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
        let videoDicts = (dict["videos"] as? [[String: Any]]) ?? []
        // (createdAt read via NSNumber — `as? Double` silently fails on the 5.1.5 runtime)
        return Playlist(
            id: id,
            name: (dict["name"] as? String) ?? "",
            videos: videoDicts.compactMap { Video.from(dict: $0) },
            createdAt: (dict["createdAt"] as? NSNumber)?.doubleValue ?? 0
        )
    }
}
