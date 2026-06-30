import UIKit

// MARK: - HomeVC
// Root VC. A feed of the latest videos from subscribed channels.
// Top-right "Search" button pushes SearchVC. Top-left "Menu" opens a slide-in
// side menu with Subscriptions + Downloads. Empty state when no subscriptions.

class HomeVC: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private var videos: [Video] = []
    private var didSetupUI = false
    private var builtChannelIds: Set<String> = []
    private var isLoading = false

    private var tableView: UITableView!
    private var statusLabel: UILabel!
    private var refreshControl: UIRefreshControl?

    // Side menu
    private var menuOverlay: UIView!
    private var menuPanel: UIView!
    private var menuOpen = false
    private let menuWidth: CGFloat = 240

    private let bg = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
    private let accent = UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 1)

    // MARK: - Feed cache (persisted) — avoids re-fetching every subscribed channel on each launch
    private static let feedCacheKey = "home_feed_cache"
    private static let feedCacheSubsKey = "home_feed_cache_subs"
    private static let feedCacheTimeKey = "home_feed_cache_time"
    private static let feedCacheTTL: TimeInterval = 1800  // 30 min — older cache refetches

    // Wipe the cached feed (Settings → Reset Cache). Subscriptions/playlists are untouched.
    static func clearFeedCache() {
        UserDefaults.standard.removeObject(forKey: feedCacheKey)
        UserDefaults.standard.removeObject(forKey: feedCacheSubsKey)
        UserDefaults.standard.removeObject(forKey: feedCacheTimeKey)
        UserDefaults.standard.synchronize()
    }

    // Return cached videos only if they were built from exactly this sub set and aren't stale.
    private static func loadFeedCache(for ids: Set<String>) -> [Video]? {
        let cachedSubs = Set((UserDefaults.standard.array(forKey: feedCacheSubsKey) as? [String]) ?? [])
        guard cachedSubs == ids else { return nil }
        let age = Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: feedCacheTimeKey)
        guard age >= 0, age < feedCacheTTL else { return nil }
        guard let dicts = UserDefaults.standard.array(forKey: feedCacheKey) as? [[String: Any]] else { return nil }
        let vids = dicts.compactMap { Video.from(dict: $0) }
        return vids.isEmpty ? nil : vids
    }

    private static func saveFeedCache(_ videos: [Video], subs ids: Set<String>) {
        UserDefaults.standard.set(videos.map { $0.toDict() }, forKey: feedCacheKey)
        UserDefaults.standard.set(Array(ids), forKey: feedCacheSubsKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: feedCacheTimeKey)
        UserDefaults.standard.synchronize()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "oldpipe"
        view.backgroundColor = bg
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Menu", style: .plain, target: self, action: #selector(toggleMenu))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Search", style: .plain, target: self, action: #selector(showSearch))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didSetupUI {
            didSetupUI = true
            setupUI()
        }
        refreshFeedIfNeeded()
    }

    private func setupUI() {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        let navH: CGFloat = 64

        tableView = UITableView(frame: CGRect(x: 0, y: 0, width: w, height: h - navH))
        tableView.backgroundColor = bg
        tableView.separatorColor = UIColor(white: 0.2, alpha: 1)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(VideoRowCell.self, forCellReuseIdentifier: VideoRowCell.reuseId)
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 60, right: 0)
        tableView.tableFooterView = UIView()   // no empty separator rows while loading/empty
        view.addSubview(tableView)

        // Pull-to-refresh (UIRefreshControl is iOS 6+; add as a subview of the plain table).
        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        tableView.addSubview(rc)
        refreshControl = rc

        statusLabel = UILabel(frame: CGRect(x: 20, y: 40, width: w - 40, height: 80))
        statusLabel.backgroundColor = .clear
        statusLabel.textColor = UIColor(white: 0.5, alpha: 1)
        statusLabel.textAlignment = .center
        statusLabel.font = UIFont.systemFont(ofSize: 15)
        statusLabel.numberOfLines = 0
        tableView.addSubview(statusLabel)
    }

    // MARK: - Side menu

    private func buildMenuIfNeeded() {
        guard menuOverlay == nil else { return }
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height

        menuOverlay = UIView(frame: CGRect(x: 0, y: 0, width: w, height: h))
        menuOverlay.backgroundColor = .clear
        menuOverlay.isHidden = true

        // Dimming button — tap outside the panel closes the menu.
        let dim = UIButton(type: .custom)
        dim.frame = menuOverlay.bounds
        dim.backgroundColor = UIColor(white: 0, alpha: 0.5)
        dim.addTarget(self, action: #selector(closeMenu), for: .touchUpInside)
        menuOverlay.addSubview(dim)

        menuPanel = UIView(frame: CGRect(x: -menuWidth, y: 0, width: menuWidth, height: h))
        menuPanel.backgroundColor = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        menuOverlay.addSubview(menuPanel)

        // Accent header band with the app name + tagline.
        let band = UIView(frame: CGRect(x: 0, y: 0, width: menuWidth, height: 110))
        band.backgroundColor = accent
        menuPanel.addSubview(band)

        let header = UILabel(frame: CGRect(x: 18, y: 62, width: menuWidth - 36, height: 30))
        header.backgroundColor = .clear
        header.textColor = .white
        header.font = UIFont.boldSystemFont(ofSize: 24)
        header.text = "oldpipe"
        band.addSubview(header)

        let items: [(String, Selector)] = [
            ("Subscriptions", #selector(menuSubscriptions)),
            ("Playlists", #selector(menuPlaylists)),
            ("Downloads", #selector(menuDownloads)),
            ("Settings", #selector(menuSettings))
        ]
        var y: CGFloat = 110
        let rowH: CGFloat = 54
        for (titleText, sel) in items {
            let btn = UIButton(type: .custom)
            btn.frame = CGRect(x: 0, y: y, width: menuWidth, height: rowH)
            btn.contentHorizontalAlignment = .left
            btn.contentEdgeInsets = UIEdgeInsets(top: 0, left: 24, bottom: 0, right: 0)
            btn.setTitle(titleText, for: .normal)
            btn.setTitleColor(UIColor(white: 0.92, alpha: 1), for: .normal)
            btn.setTitleColor(accent, for: .highlighted)
            btn.titleLabel?.font = UIFont.systemFont(ofSize: 16)
            btn.addTarget(self, action: sel, for: .touchUpInside)
            menuPanel.addSubview(btn)

            // accent leading tab
            let tab = UIView(frame: CGRect(x: 0, y: y + 14, width: 4, height: rowH - 28))
            tab.backgroundColor = accent
            menuPanel.addSubview(tab)

            // bottom separator
            let sep = UIView(frame: CGRect(x: 0, y: y + rowH - 0.5, width: menuWidth, height: 0.5))
            sep.backgroundColor = UIColor(white: 1, alpha: 0.08)
            menuPanel.addSubview(sep)

            y += rowH
        }

        let footer = UILabel(frame: CGRect(x: 18, y: h - 50, width: menuWidth - 36, height: 18))
        footer.backgroundColor = .clear
        footer.textColor = UIColor(white: 0.4, alpha: 1)
        footer.font = UIFont.systemFont(ofSize: 11)
        footer.text = "v1.0"
        menuPanel.addSubview(footer)

        view.addSubview(menuOverlay)
    }

    @objc private func toggleMenu() {
        if menuOpen { closeMenu() } else { openMenu() }
    }

    private func openMenu() {
        buildMenuIfNeeded()
        menuOverlay.isHidden = false
        menuOpen = true
        UIView.animate(withDuration: 0.25) {
            self.menuPanel.frame.origin.x = 0
        }
    }

    @objc private func closeMenu() {
        guard menuOverlay != nil else { return }
        menuOpen = false
        UIView.animate(withDuration: 0.25, animations: {
            self.menuPanel.frame.origin.x = -self.menuWidth
        }, completion: { _ in
            self.menuOverlay.isHidden = true
        })
    }

    @objc private func menuSubscriptions() {
        closeMenu()
        navigationController?.pushViewController(ManageSubscriptionsVC(), animated: true)
    }

    @objc private func menuPlaylists() {
        closeMenu()
        navigationController?.pushViewController(PlaylistsVC(), animated: true)
    }

    @objc private func menuDownloads() {
        closeMenu()
        navigationController?.pushViewController(DownloadsVC(), animated: true)
    }

    @objc private func menuSettings() {
        closeMenu()
        navigationController?.pushViewController(SettingsVC(), animated: true)
    }

    @objc private func showSearch() {
        navigationController?.pushViewController(SearchVC(), animated: true)
    }

    // MARK: - Feed

    private func refreshFeedIfNeeded() {
        let subs = SubscriptionManager.all()
        let ids = Set(subs.map { $0.id })

        if subs.isEmpty {
            videos = []
            builtChannelIds = []
            statusLabel?.text = "No subscriptions yet.\nTap Search, open a channel, and tap Subscribe."
            statusLabel?.isHidden = false
            tableView?.reloadData()
            return
        }

        // Dirty flag: skip refetch if the subscription set is unchanged.
        guard ids != builtChannelIds, !isLoading else { return }
        builtChannelIds = ids

        // Persisted cache: serve the saved feed instantly (no network) if it was built from
        // this exact sub set and is still fresh. Pull-to-refresh bypasses this.
        if let cached = HomeVC.loadFeedCache(for: ids) {
            videos = cached
            statusLabel?.isHidden = !cached.isEmpty
            tableView?.reloadData()
            return
        }
        loadFeed(channels: subs)
    }

    // Pull-to-refresh: force a refetch even when the subscription set is unchanged.
    @objc private func handleRefresh() {
        let subs = SubscriptionManager.all()
        if subs.isEmpty || isLoading {
            refreshControl?.endRefreshing()
            refreshFeedIfNeeded()
            return
        }
        builtChannelIds = Set(subs.map { $0.id })
        loadFeed(channels: subs, isRefresh: true)
    }

    private func loadFeed(channels: [Channel], isRefresh: Bool = false) {
        isLoading = true
        // On a pull-to-refresh keep the current rows visible (spinner shows progress);
        // on a fresh load clear and show the loading label.
        if !isRefresh {
            videos = []
            tableView?.reloadData()
            statusLabel?.text = "Loading subscriptions..."
            statusLabel?.isHidden = false
        }

        var collected: [[Video]] = Array(repeating: [], count: channels.count)
        var remaining = channels.count

        for (idx, channel) in channels.enumerated() {
            YoutubeAPI.getChannelVideos(channelId: channel.id) { [weak self] vids, fresh, _ in
                guard let self = self else { return }
                // Heal the stored avatar/name from the fresh channel result (fixes blank
                // icons in ManageSubscriptionsVC for subs saved before their avatar was known).
                if let c = fresh {
                    SubscriptionManager.updateThumbnail(channelId: channel.id,
                                                        thumbnailURL: c.thumbnailURL, name: c.name)
                }
                // Keep newest few per channel (channel browse returns newest-first).
                collected[idx] = Array(vids.prefix(6))
                remaining -= 1
                if remaining == 0 {
                    self.finishFeed(collected)
                }
            }
        }
    }

    // Merge all channels and sort newest-first by published date.
    private func finishFeed(_ perChannel: [[Video]]) {
        var merged: [Video] = []
        var seen = Set<String>()
        for list in perChannel {
            for v in list {
                if seen.contains(v.id) { continue }
                seen.insert(v.id)
                merged.append(v)
            }
        }
        // Sort latest-first using the relative "published" text (e.g. "3 days ago").
        merged.sort { HomeVC.approxAge($0.publishedText) < HomeVC.approxAge($1.publishedText) }
        videos = merged
        HomeVC.saveFeedCache(merged, subs: builtChannelIds)
        isLoading = false
        refreshControl?.endRefreshing()
        statusLabel?.isHidden = !merged.isEmpty
        if merged.isEmpty { statusLabel?.text = "No recent videos from your subscriptions." }
        tableView?.reloadData()
    }

    // Convert a relative "published" string ("3 days ago", "Streamed 2 hours ago") into an
    // approximate age in seconds. Smaller = more recent; unknown sorts last.
    private static func approxAge(_ text: String) -> Double {
        let lower = text.lowercased()
        if lower.isEmpty { return .greatestFiniteMagnitude }
        var digits = ""
        for ch in lower {
            if ch.isNumber { digits.append(ch) }
            else if !digits.isEmpty { break }
        }
        let num = Double(digits) ?? 1
        let unit: Double
        if lower.contains("year")        { unit = 31_536_000 }
        else if lower.contains("month")  { unit = 2_592_000 }
        else if lower.contains("week")   { unit = 604_800 }
        else if lower.contains("day")    { unit = 86_400 }
        else if lower.contains("hour")   { unit = 3_600 }
        else if lower.contains("minute") { unit = 60 }
        else if lower.contains("second") { unit = 1 }
        else { return .greatestFiniteMagnitude }
        return num * unit
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return videos.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: VideoRowCell.reuseId, for: indexPath) as! VideoRowCell
        cell.configure(with: videos[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return VideoRowCell.rowHeight
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let vc = VideoPlayerVC(video: videos[indexPath.row])
        navigationController?.pushViewController(vc, animated: true)
    }
}
