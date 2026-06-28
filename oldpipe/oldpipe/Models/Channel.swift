import Foundation

struct Channel {
    let id: String           // UC...
    let name: String
    let thumbnailURL: String

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
