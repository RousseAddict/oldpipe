import Foundation

// MARK: - SubscriptionManager
// Persists subscribed channels to UserDefaults (most-recent first, de-duplicated).
// Used by HomeVC (feed), ChannelVC (subscribe toggle) and ManageSubscriptionsVC.

class SubscriptionManager {

    private static let defaultsKey = "subscribed_channels"

    static func all() -> [Channel] {
        return rawList().compactMap { Channel.from(dict: $0) }
    }

    static func isSubscribed(_ channelId: String) -> Bool {
        guard !channelId.isEmpty else { return false }
        return rawList().contains { ($0["id"] as? String) == channelId }
    }

    static func subscribe(_ channel: Channel) {
        guard !channel.id.isEmpty else { return }
        var list = rawList()
        list.removeAll { ($0["id"] as? String) == channel.id }
        list.insert(channel.toDict(), at: 0)
        UserDefaults.standard.set(list, forKey: defaultsKey)
        UserDefaults.standard.synchronize()
    }

    // Refresh a stored channel's avatar/name from a fresh API result. No-op if the channel
    // isn't subscribed or the new value is empty/unchanged. Heals subscriptions saved before
    // their avatar URL was known (the subscribe toggle can fire before the channel API returns).
    static func updateThumbnail(channelId: String, thumbnailURL: String, name: String = "") {
        guard !channelId.isEmpty, !thumbnailURL.isEmpty else { return }
        var list = rawList()
        guard let idx = list.firstIndex(where: { ($0["id"] as? String) == channelId }) else { return }
        var entry = list[idx]
        let changed = (entry["thumbnailURL"] as? String) != thumbnailURL
            || (!name.isEmpty && (entry["name"] as? String) != name)
        guard changed else { return }
        entry["thumbnailURL"] = thumbnailURL
        if !name.isEmpty { entry["name"] = name }
        list[idx] = entry
        UserDefaults.standard.set(list, forKey: defaultsKey)
        UserDefaults.standard.synchronize()
    }

    static func unsubscribe(_ channelId: String) {
        var list = rawList()
        list.removeAll { ($0["id"] as? String) == channelId }
        UserDefaults.standard.set(list, forKey: defaultsKey)
        UserDefaults.standard.synchronize()
    }

    private static func rawList() -> [[String: Any]] {
        return (UserDefaults.standard.array(forKey: defaultsKey) as? [[String: Any]]) ?? []
    }
}
