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
