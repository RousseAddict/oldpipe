import Foundation

// A single YouTube comment (top-level or reply).
//
// The WEB innertube client no longer returns the old `commentRenderer` tree: comment
// *content* now arrives as flat entities in `frameworkUpdates.entityBatchUpdate.mutations`,
// while the *display order* (and the per-thread reply token) lives separately in
// `onResponseReceivedEndpoints`. So a comment is assembled from two places — see
// YoutubeAPI.parseComments.
struct Comment {
    let id: String
    let author: String
    let text: String
    let published: String
    let likeCount: String
    let replyCount: String
    let isCreator: Bool
    let isPinned: Bool
    // Continuation token for this thread's replies ("" when the comment has none).
    // Replies themselves never carry one — they are rendered indented under their parent.
    let repliesToken: String

    // "@name · 2 years ago" header line, with the creator badge when YouTube flags it.
    var headerText: String {
        var parts: [String] = []
        parts.append(isCreator ? "\(author) \u{2022} Creator" : author)
        if !published.isEmpty { parts.append(published) }
        return parts.joined(separator: " \u{2022} ")
    }

    // "324K likes" / "" — the footer only shows a like count when there is one.
    // (likeCount is normalised by YoutubeAPI.countField: no likes arrives as a space.)
    var likeText: String {
        guard !likeCount.isEmpty else { return "" }
        return likeCount == "1" ? "1 like" : "\(likeCount) likes"
    }

    // "View 12 replies" — empty when this comment has no fetchable replies.
    var repliesText: String {
        guard !repliesToken.isEmpty, !replyCount.isEmpty else { return "" }
        return replyCount == "1" ? "View 1 reply" : "View \(replyCount) replies"
    }
}
