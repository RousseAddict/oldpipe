import Foundation

struct Channel {
    let id: String           // UC...
    let name: String
    let thumbnailURL: String
    // Transient: the channel's "About" text. Populated from the browse response,
    // not persisted (toDict/from(dict:) omit it — subscriptions don't need it).
    var channelDescription: String = ""

    func toDict() -> [String: Any] {
        return ["id": id, "name": name, "thumbnailURL": thumbnailURL]
    }

    static func from(dict: [String: Any]) -> Channel? {
        guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
        return Channel(id: id,
                       name: (dict["name"] as? String) ?? "",
                       thumbnailURL: (dict["thumbnailURL"] as? String) ?? "")
    }
}
