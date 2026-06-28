import Foundation

struct Video {
    let id: String
    let title: String
    let channelName: String
    let channelId: String      // UC... (empty if unknown)
    let thumbnailURL: String
    let durationText: String   // e.g. "3:45"
    let viewCountText: String  // e.g. "1.2M views"
    let publishedText: String  // e.g. "3 days ago" (empty if unknown)

    func toDict() -> [String: Any] {
        return [
            "id": id,
            "title": title,
            "channelName": channelName,
            "channelId": channelId,
            "thumbnailURL": thumbnailURL,
            "durationText": durationText,
            "viewCountText": viewCountText,
            "publishedText": publishedText
        ]
    }

    static func from(dict: [String: Any]) -> Video? {
        guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
        return Video(
            id: id,
            title: (dict["title"] as? String) ?? "",
            channelName: (dict["channelName"] as? String) ?? "",
            channelId: (dict["channelId"] as? String) ?? "",
            thumbnailURL: (dict["thumbnailURL"] as? String) ?? "",
            durationText: (dict["durationText"] as? String) ?? "",
            viewCountText: (dict["viewCountText"] as? String) ?? "",
            publishedText: (dict["publishedText"] as? String) ?? ""
        )
    }
}

struct VideoStream {
    let url: String
    let itag: Int
    let mimeType: String
    let quality: String
}
