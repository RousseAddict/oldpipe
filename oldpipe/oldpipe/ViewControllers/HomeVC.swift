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

    // Thin indeterminate top loading bar (3px overlay at the top of the content area).
    private var loadingBar: UIView?
    private var loadingBarSeg: CALayer?

    // Side menu
    private var menuOverlay: UIView!
    private var menuPanel: UIView!
    private var menuOpen = false
    private let menuWidth: CGFloat = 240

    private let bg = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
    private let accent = UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 1)

    // Coalesces the progressive "show results as they arrive" reloads into a couple of
    // smooth refreshes instead of one flicker per channel that returns.
    private var reloadTimer: Timer?

    // MARK: - Per-channel feed cache (persisted)
    // Each subscribed channel's newest few videos are cached under its own id (+ a
    // timestamp). Adding a channel therefore only fetches THAT channel — every other
    // channel renders instantly from cache. Stale (>TTL) or missing channels are refetched.
    private static let channelCacheKey = "home_channel_cache"        // [channelId: [videoDict]]
    private static let channelCacheTimeKey = "home_channel_cache_time" // [channelId: epochSeconds]
    private static let feedCacheTTL: TimeInterval = 1800  // 30 min — older cache refetches

    // Wipe the cached feed (Settings → Reset Cache). Subscriptions/playlists are untouched.
    // Also clears the legacy whole-feed keys so upgrading installs don't leave them behind.
    static func clearFeedCache() {
        for k in [channelCacheKey, channelCacheTimeKey,
                  "home_feed_cache", "home_feed_cache_subs", "home_feed_cache_time"] {
            UserDefaults.standard.removeObject(forKey: k)
        }
        UserDefaults.standard.synchronize()
    }

    // Persist one channel's videos (+ now as its freshness timestamp). An empty list is
    // still stored (with a timestamp) so a channel with no videos isn't refetched every appear.
    private static func saveChannelVideos(_ videos: [Video], for id: String) {
        var map = UserDefaults.standard.dictionary(forKey: channelCacheKey) ?? [:]
        map[id] = videos.map { $0.toDict() }
        UserDefaults.standard.set(map, forKey: channelCacheKey)
        var times = UserDefaults.standard.dictionary(forKey: channelCacheTimeKey) ?? [:]
        times[id] = Date().timeIntervalSince1970
        UserDefaults.standard.set(times, forKey: channelCacheTimeKey)
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
        // iPad rotates natively; the flexible masks (here + on the status label, loading bar
        // and side menu) reflow the layout in landscape. iPhone is portrait-locked in the
        // pbxproj so autoresizing never triggers there.
        tableView.autoresizingMask = iPadFlexWidthHeight
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
        statusLabel.autoresizingMask = iPadFlexWidth
        tableView.addSubview(statusLabel)

        // Indeterminate top loading bar: a 3px strip overlaid at the top of the content area
        // (added to `view`, NOT the table, so it stays fixed and doesn't scroll). It only
        // covers the table's top 3px — above the first row's 8px thumbnail margin.
        let barH: CGFloat = 3
        let bar = UIView(frame: CGRect(x: 0, y: 0, width: w, height: barH))
        bar.backgroundColor = UIColor(white: 0.12, alpha: 1)   // faint track behind the segment
        bar.clipsToBounds = true                               // clip the segment when off-edge
        bar.isHidden = true
        bar.autoresizingMask = iPadFlexWidth   // startLoadingBar re-reads bar.bounds.width
        view.addSubview(bar)
        loadingBar = bar

        let seg = CALayer()
        seg.backgroundColor = accent.cgColor
        seg.frame = CGRect(x: 0, y: 0, width: floor(w * 0.35), height: barH)
        bar.layer.addSublayer(seg)
        loadingBarSeg = seg
    }

    // MARK: - Loading bar

    private func startLoadingBar() {
        guard let bar = loadingBar, let seg = loadingBarSeg else { return }
        bar.isHidden = false
        seg.removeAnimation(forKey: "indeterminate")
        // Shuttle the accent segment left→right repeatedly. A CAAnimation (vs a UIView block
        // animation) keeps running while the user is dragging the list.
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = -seg.bounds.width / 2
        move.toValue = bar.bounds.width + seg.bounds.width / 2
        move.duration = 1.1
        move.repeatCount = .infinity
        move.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.linear)
        seg.add(move, forKey: "indeterminate")
    }

    private func stopLoadingBar() {
        loadingBarSeg?.removeAnimation(forKey: "indeterminate")
        loadingBar?.isHidden = true
    }

    // MARK: - Side menu

    private func buildMenuIfNeeded() {
        guard menuOverlay == nil else { return }
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height

        menuOverlay = UIView(frame: CGRect(x: 0, y: 0, width: w, height: h))
        menuOverlay.backgroundColor = .clear
        menuOverlay.isHidden = true
        menuOverlay.autoresizingMask = iPadFlexWidthHeight

        // Dimming button — tap outside the panel closes the menu.
        let dim = UIButton(type: .custom)
        dim.frame = menuOverlay.bounds
        dim.backgroundColor = UIColor(white: 0, alpha: 0.5)
        dim.autoresizingMask = iPadFlexWidthHeight
        dim.addTarget(self, action: #selector(closeMenu), for: .touchUpInside)
        menuOverlay.addSubview(dim)

        // Fixed-width panel anchored to the left edge; only the height flexes on rotation.
        menuPanel = UIView(frame: CGRect(x: -menuWidth, y: 0, width: menuWidth, height: h))
        menuPanel.backgroundColor = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        menuPanel.autoresizingMask = iPadFlexHeight
        menuOverlay.addSubview(menuPanel)

        // Accent header band with the app name + tagline.
        let band = UIView(frame: CGRect(x: 0, y: 0, width: menuWidth, height: 78))
        band.backgroundColor = accent
        menuPanel.addSubview(band)

        let header = UILabel(frame: CGRect(x: 18, y: 40, width: menuWidth - 36, height: 30))
        header.backgroundColor = .clear
        header.textColor = .white
        header.font = UIFont.boldSystemFont(ofSize: 22)
        header.text = "oldpipe"
        band.addSubview(header)

        let items: [(String, Selector)] = [
            ("Subscriptions", #selector(menuSubscriptions)),
            ("Playlists", #selector(menuPlaylists)),
            ("Downloads", #selector(menuDownloads)),
            ("History", #selector(menuHistory)),
            ("Settings", #selector(menuSettings))
        ]
        var y: CGFloat = 78
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
        footer.autoresizingMask = iPadFlexTop   // stay pinned to the panel's bottom
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

    @objc private func menuHistory() {
        closeMenu()
        navigationController?.pushViewController(HistoryVC(), animated: true)
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

        // Render instantly from the per-channel cache (any age) when the view is empty or
        // the sub set changed — e.g. a channel was just added: every other channel shows at
        // once and only the new one is blank until it loads below.
        if videos.isEmpty || ids != builtChannelIds {
            builtChannelIds = ids
            rebuildFromCache()
        }

        guard !isLoading else { return }

        // Fetch only channels whose cache is missing or stale (>TTL).
        let times = UserDefaults.standard.dictionary(forKey: HomeVC.channelCacheTimeKey) ?? [:]
        let now = Date().timeIntervalSince1970
        let toFetch = subs.filter { ch in
            guard let ts = (times[ch.id] as? NSNumber)?.doubleValue else { return true }
            let age = now - ts
            return !(age >= 0 && age < HomeVC.feedCacheTTL)
        }
        guard !toFetch.isEmpty else { return }
        loadFeed(channels: toFetch)
    }

    // Pull-to-refresh: force a refetch of every channel, ignoring cache freshness.
    @objc private func handleRefresh() {
        let subs = SubscriptionManager.all()
        if subs.isEmpty || isLoading {
            refreshControl?.endRefreshing()
            return
        }
        builtChannelIds = Set(subs.map { $0.id })
        loadFeed(channels: subs, isRefresh: true)
    }

    // Fetch the given channels in parallel (CurlFetcher caps concurrency at 4). Each result
    // is cached per-channel and triggers a coalesced re-render, so videos appear as they
    // arrive rather than all at once when the slowest channel finishes.
    private func loadFeed(channels toFetch: [Channel], isRefresh: Bool = false) {
        guard !toFetch.isEmpty else { return }
        isLoading = true
        startLoadingBar()
        // Fresh load with nothing on screen yet → show the loading label. A pull-to-refresh
        // (or an add-channel render) keeps the current rows visible while new ones stream in.
        if !isRefresh && videos.isEmpty {
            statusLabel?.text = "Loading subscriptions..."
            statusLabel?.isHidden = false
        }

        var remaining = toFetch.count
        for channel in toFetch {
            YoutubeAPI.getChannelVideos(channelId: channel.id) { [weak self] vids, fresh, _ in
                guard let self = self else { return }
                // Heal the stored avatar/name from the fresh channel result (fixes blank
                // icons in ManageSubscriptionsVC for subs saved before their avatar was known).
                if let c = fresh {
                    SubscriptionManager.updateThumbnail(channelId: channel.id,
                                                        thumbnailURL: c.thumbnailURL, name: c.name)
                }
                // Keep newest few per channel (channel browse returns newest-first).
                HomeVC.saveChannelVideos(Array(vids.prefix(6)), for: channel.id)
                self.scheduleProgressiveReload()
                remaining -= 1
                if remaining == 0 { self.finishFeed() }
            }
        }
    }

    // One-shot coalesced reload: the first arriving channel arms a 0.3s timer; any further
    // channels that return before it fires are folded into the same rebuild.
    private func scheduleProgressiveReload() {
        guard reloadTimer == nil else { return }
        let t = Timer(timeInterval: 0.3, target: self,
                      selector: #selector(progressiveReloadFired), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
        reloadTimer = t
    }

    @objc private func progressiveReloadFired() {
        reloadTimer = nil
        rebuildFromCache()
    }

    private func finishFeed() {
        isLoading = false
        stopLoadingBar()
        refreshControl?.endRefreshing()
        reloadTimer?.invalidate()
        reloadTimer = nil
        rebuildFromCache()
    }

    // Merge every subscribed channel's cached videos, de-dupe, and sort newest-first.
    // Reads the cache dict once (not per channel) to stay cheap on the iPhone 4S.
    private func rebuildFromCache() {
        let subs = SubscriptionManager.all()
        let map = UserDefaults.standard.dictionary(forKey: HomeVC.channelCacheKey) ?? [:]
        var merged: [Video] = []
        var seen = Set<String>()
        for ch in subs {
            guard let dicts = map[ch.id] as? [[String: Any]] else { continue }
            for d in dicts {
                guard let v = Video.from(dict: d), !seen.contains(v.id) else { continue }
                seen.insert(v.id)
                merged.append(v)
            }
        }
        // Sort latest-first using the relative "published" text (e.g. "3 days ago").
        merged.sort { HomeVC.approxAge($0.publishedText) < HomeVC.approxAge($1.publishedText) }
        videos = merged
        if merged.isEmpty {
            statusLabel?.text = isLoading ? "Loading subscriptions..." : "No recent videos from your subscriptions."
            statusLabel?.isHidden = false
        } else {
            statusLabel?.isHidden = true
        }
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
