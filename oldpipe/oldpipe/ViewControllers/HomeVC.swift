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

    // MARK: - Shorts-on-Home (optional, gated by AppSettings.shortsOnHome)
    // When the Settings toggle is on, a Videos/Shorts tab bar sits above the feed and a
    // second (2-column portrait grid) table shows shorts from the subscribed channels.
    // All of this is inert unless the toggle is enabled — HomeVC then behaves exactly as
    // before (videos-only, no tab bar).
    private let tabBarH: CGFloat = 44
    private var tabBar: UIView?
    private var tabButtons: [UIButton] = []
    private var tabIndicator: UIView?
    private var selectedHomeTab = 0            // 0 Videos, 1 Shorts
    private var shortsTabBuilt = false
    private var shortsApplied = false          // last-applied visibility state

    private var shorts: [Video] = []
    private var shortsBuiltChannelIds: Set<String> = []
    private var shortsLoading = false
    private var shortsTable: UITableView?
    private var shortsStatus: UILabel?
    private var shortsReloadTimer: Timer?

    // Continuous (infinite-scroll) Shorts pagination. The home Shorts feed is MERGED across
    // every subscribed channel, so — unlike ChannelVC's single-channel Shorts tab — we track
    // one continuation token PER channel. Reaching the end of the grid fetches the next page
    // from every channel that still has a token; the new (de-duped, shuffled) videos are
    // appended below what's already on screen so the scroll position never jumps. Pagination
    // is session-only: continuation pages live in `shortsExtra` (memory), never in the cache,
    // so a fresh launch/refresh restarts from the cached first page.
    private var shortsTokens: [String: String] = [:]   // channelId → continuation token
    private var shortsExtra: [Video] = []              // continuation pages (appended after page 1)
    private var shortsSeen: Set<String> = []           // ids currently in `shorts` (dedup)
    private var shortsLoadingMore = false

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
    private static let shortsCacheKey = "home_shorts_cache"          // [channelId: [videoDict]]
    private static let shortsCacheTimeKey = "home_shorts_cache_time" // [channelId: epochSeconds]
    private static let feedCacheTTL: TimeInterval = 1800  // 30 min — older cache refetches

    // Wipe the cached feed (Settings → Reset Cache). Subscriptions/playlists are untouched.
    // Also clears the legacy whole-feed keys so upgrading installs don't leave them behind.
    static func clearFeedCache() {
        for k in [channelCacheKey, channelCacheTimeKey, shortsCacheKey, shortsCacheTimeKey,
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

    // Same as saveChannelVideos but for the per-channel Shorts cache.
    private static func saveChannelShorts(_ videos: [Video], for id: String) {
        var map = UserDefaults.standard.dictionary(forKey: shortsCacheKey) ?? [:]
        map[id] = videos.map { $0.toDict() }
        UserDefaults.standard.set(map, forKey: shortsCacheKey)
        var times = UserDefaults.standard.dictionary(forKey: shortsCacheTimeKey) ?? [:]
        times[id] = Date().timeIntervalSince1970
        UserDefaults.standard.set(times, forKey: shortsCacheTimeKey)
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
        applyShortsTabVisibility()   // reflects the current Settings toggle (may have changed)
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

    // MARK: - Shorts tab

    // The row height of the 2-column portrait grid: a full-width portrait (9:16) thumbnail
    // per card plus a 2-line title. Shared by heightForRowAt and the grid cell's layout.
    static func shortRowHeight(width w: CGFloat) -> CGFloat {
        let pad: CGFloat = 12
        let cardW = (w - pad * 3) / 2
        let thumbH = cardW * 16.0 / 9.0
        return pad + thumbH + 6 + 34
    }

    // Build the tab bar + shorts grid table once, the first time the toggle is enabled.
    private func buildShortsUIIfNeeded() {
        guard !shortsTabBuilt else { return }
        shortsTabBuilt = true
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        let navH: CGFloat = 64
        let contentY = tabBarH
        let contentFrame = CGRect(x: 0, y: contentY, width: w, height: h - navH - contentY)

        // Shorts grid table (behind the tab bar in z-order; the videos tableView is already
        // added). Both content tables share this VC as data source, branched by identity.
        let st = UITableView(frame: contentFrame)
        st.backgroundColor = bg
        st.separatorStyle = .none
        st.dataSource = self
        st.delegate = self
        st.register(ShortGridCell.self, forCellReuseIdentifier: ShortGridCell.reuseId)
        st.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 60, right: 0)
        st.tableFooterView = UIView()
        st.autoresizingMask = iPadFlexWidthHeight
        st.isHidden = true
        view.addSubview(st)
        shortsTable = st

        let ss = UILabel(frame: CGRect(x: 20, y: 40, width: w - 40, height: 40))
        ss.backgroundColor = .clear
        ss.textColor = UIColor(white: 0.5, alpha: 1)
        ss.textAlignment = .center
        ss.font = UIFont.systemFont(ofSize: 15)
        ss.autoresizingMask = iPadFlexWidth
        st.addSubview(ss)
        shortsStatus = ss

        // Tab bar on top (added last so it sits above both tables + the loading bar).
        let tb = UIView(frame: CGRect(x: 0, y: 0, width: w, height: tabBarH))
        tb.backgroundColor = UIColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)
        tb.autoresizingMask = iPadFlexWidth
        view.addSubview(tb)
        tabBar = tb

        let titles = ["Videos", "Shorts"]
        let bw = w / CGFloat(titles.count)
        for (i, t) in titles.enumerated() {
            let b = UIButton(type: .custom)
            b.frame = CGRect(x: bw * CGFloat(i), y: 0, width: bw, height: tabBarH)
            b.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
            b.setTitle(t, for: .normal)
            b.setTitleColor(UIColor(white: 0.55, alpha: 1), for: .normal)
            b.tag = i
            b.addTarget(self, action: #selector(homeTabTapped(_:)), for: .touchUpInside)
            tb.addSubview(b)
            tabButtons.append(b)
        }
        let hair = UIView(frame: CGRect(x: 0, y: tabBarH - 0.5, width: w, height: 0.5))
        hair.backgroundColor = UIColor(white: 0.2, alpha: 1)
        hair.autoresizingMask = iPadFlexWidth
        tb.addSubview(hair)

        let ind = UIView(frame: CGRect(x: 0, y: tabBarH - 2, width: bw, height: 2))
        ind.backgroundColor = accent
        tabBar?.addSubview(ind)
        tabIndicator = ind
    }

    // Reflect the current Settings toggle: show/hide the tab bar + shorts table and size the
    // videos table to leave room for the tab bar (or fill the view when the toggle is off).
    private func applyShortsTabVisibility() {
        let enabled = AppSettings.shortsOnHome
        // No change since last apply and nothing to build → skip (cheap re-appears).
        if enabled == shortsApplied && (!enabled || shortsTabBuilt) { return }
        shortsApplied = enabled

        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        let navH: CGFloat = 64

        if enabled {
            buildShortsUIIfNeeded()
            tabBar?.isHidden = false
            let contentY = tabBarH
            tableView.frame = CGRect(x: 0, y: contentY, width: w, height: h - navH - contentY)
            shortsTable?.frame = tableView.frame
            loadingBar?.frame.origin.y = contentY
            selectHomeTab(selectedHomeTab)
        } else {
            tabBar?.isHidden = true
            shortsTable?.isHidden = true
            selectedHomeTab = 0
            tableView.isHidden = false
            tableView.frame = CGRect(x: 0, y: 0, width: w, height: h - navH)
            loadingBar?.frame.origin.y = 0
        }
    }

    @objc private func homeTabTapped(_ sender: UIButton) {
        selectHomeTab(sender.tag)
    }

    private func selectHomeTab(_ index: Int) {
        selectedHomeTab = index
        tableView.isHidden = (index != 0)
        shortsTable?.isHidden = (index != 1)
        updateHomeTabIndicator()
        if index == 1 { loadShortsFeed() }
    }

    private func updateHomeTabIndicator() {
        for (i, b) in tabButtons.enumerated() {
            b.setTitleColor(i == selectedHomeTab ? accent : UIColor(white: 0.55, alpha: 1), for: .normal)
        }
        let bw = UIScreen.main.bounds.width / CGFloat(max(tabButtons.count, 1))
        tabIndicator?.frame = CGRect(x: bw * CGFloat(selectedHomeTab), y: tabBarH - 2, width: bw, height: 2)
    }

    // MARK: - Shorts feed loading (fixed first batch — no load-more)

    private func loadShortsFeed() {
        let subs = SubscriptionManager.all()
        let ids = Set(subs.map { $0.id })

        if subs.isEmpty {
            shorts = []
            shortsBuiltChannelIds = []
            shortsStatus?.text = "No subscriptions yet.\nSubscribe to channels to see their Shorts."
            shortsStatus?.isHidden = false
            shortsTable?.reloadData()
            return
        }

        if shorts.isEmpty || ids != shortsBuiltChannelIds {
            shortsBuiltChannelIds = ids
            // Fresh load / sub-set change → restart pagination from the cached first page.
            shortsTokens.removeAll()
            shortsExtra.removeAll()
            rebuildShortsFromCache()
        }

        guard !shortsLoading else { return }

        let times = UserDefaults.standard.dictionary(forKey: HomeVC.shortsCacheTimeKey) ?? [:]
        let now = Date().timeIntervalSince1970
        let toFetch = subs.filter { ch in
            guard let ts = (times[ch.id] as? NSNumber)?.doubleValue else { return true }
            let age = now - ts
            return !(age >= 0 && age < HomeVC.feedCacheTTL)
        }
        guard !toFetch.isEmpty else { return }

        shortsLoading = true
        if shorts.isEmpty {
            shortsStatus?.text = "Loading shorts..."
            shortsStatus?.isHidden = false
        }

        var remaining = toFetch.count
        for channel in toFetch {
            // priority:false — Shorts is a background feed like the videos feed.
            YoutubeAPI.getChannelShorts(channelId: channel.id, priority: false) { [weak self] vids, token in
                guard let self = self else { return }
                HomeVC.saveChannelShorts(Array(vids.prefix(12)), for: channel.id)
                // Stash this channel's continuation token for infinite scroll (drop if absent).
                if let t = token, !t.isEmpty { self.shortsTokens[channel.id] = t }
                else { self.shortsTokens.removeValue(forKey: channel.id) }
                self.scheduleShortsReload()
                remaining -= 1
                if remaining == 0 { self.finishShortsFeed() }
            }
        }
    }

    private func scheduleShortsReload() {
        guard shortsReloadTimer == nil else { return }
        let t = Timer(timeInterval: 0.3, target: self,
                      selector: #selector(shortsReloadFired), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
        shortsReloadTimer = t
    }

    @objc private func shortsReloadFired() {
        shortsReloadTimer = nil
        rebuildShortsFromCache()
    }

    private func finishShortsFeed() {
        shortsLoading = false
        shortsReloadTimer?.invalidate()
        shortsReloadTimer = nil
        rebuildShortsFromCache()
    }

    private func rebuildShortsFromCache() {
        let subs = SubscriptionManager.all()
        let map = UserDefaults.standard.dictionary(forKey: HomeVC.shortsCacheKey) ?? [:]
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
        // Shorts carry no publish date (the shortsLockupViewModel has no date field), so a
        // time sort is impossible and concatenating per channel makes the feed feel grouped
        // ("all of channel A, then all of channel B"). Shuffle instead for a mixed, less
        // predictable feel. shuffle() is pure Swift stdlib (runtime-independent, safe on 5.1.5).
        merged.shuffle()
        // Re-append this session's continuation pages (de-duped against the rebuilt first page)
        // so a progressive/background rebuild doesn't discard what infinite scroll fetched.
        for v in shortsExtra where !seen.contains(v.id) {
            seen.insert(v.id)
            merged.append(v)
        }
        shortsSeen = seen
        shorts = merged
        if merged.isEmpty {
            shortsStatus?.text = shortsLoading ? "Loading shorts..." : "No recent Shorts from your subscriptions."
            shortsStatus?.isHidden = false
        } else {
            shortsStatus?.isHidden = true
        }
        shortsTable?.reloadData()
    }

    // Infinite scroll: fetch the next page from every channel that still has a continuation
    // token, then append the new (de-duped, shuffled) videos below the current feed. Runs on
    // the background lane (priority:false, CurlFetcher caps concurrency at 4). Appending —
    // rather than re-merging + re-shuffling the whole list — keeps the scroll position and
    // already-seen ordering stable. Stops naturally once every channel is exhausted.
    private func loadMoreShorts() {
        guard !shortsLoadingMore, !shortsTokens.isEmpty else { return }
        let names = Dictionary(SubscriptionManager.all().map { ($0.id, $0.name) },
                               uniquingKeysWith: { a, _ in a })
        let pending = shortsTokens   // snapshot — completions mutate shortsTokens
        shortsLoadingMore = true
        var remaining = pending.count
        for (channelId, token) in pending {
            let channelName = names[channelId] ?? ""
            YoutubeAPI.getChannelContinuation(token: token, channelName: channelName, priority: false) { [weak self] vids, next in
                guard let self = self else { return }
                if let n = next, !n.isEmpty { self.shortsTokens[channelId] = n }
                else { self.shortsTokens.removeValue(forKey: channelId) }   // channel exhausted
                var batch: [Video] = []
                for v in vids.prefix(12) where !self.shortsSeen.contains(v.id) {
                    self.shortsSeen.insert(v.id)
                    batch.append(v)
                }
                batch.shuffle()
                self.shortsExtra.append(contentsOf: batch)
                self.shorts.append(contentsOf: batch)
                remaining -= 1
                if remaining == 0 {
                    self.shortsLoadingMore = false
                    self.shortsTable?.reloadData()
                }
            }
        }
    }

    private func openShort(at index: Int) {
        guard index >= 0, index < shorts.count else { return }
        let vc = ShortsPlayerVC(shorts: shorts, startIndex: index)
        navigationController?.pushViewController(vc, animated: true)
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
        if tableView === shortsTable { return (shorts.count + 1) / 2 }   // 2 cards per row
        return videos.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if tableView === shortsTable {
            let cell = tableView.dequeueReusableCell(withIdentifier: ShortGridCell.reuseId, for: indexPath) as! ShortGridCell
            let i0 = indexPath.row * 2
            let i1 = i0 + 1
            cell.configureLeft(shorts[i0]) { [weak self] in self?.openShort(at: i0) }
            if i1 < shorts.count {
                cell.configureRight(shorts[i1]) { [weak self] in self?.openShort(at: i1) }
            } else {
                cell.clearRight()
            }
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: VideoRowCell.reuseId, for: indexPath) as! VideoRowCell
        cell.configure(with: videos[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if tableView === shortsTable { return HomeVC.shortRowHeight(width: tableView.bounds.width) }
        return VideoRowCell.rowHeight
    }

    // Infinite scroll for the Shorts grid: when the last grid row is about to appear, pull the
    // next page from every channel that still has a token. Videos feed is unchanged (no paging).
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard tableView === shortsTable else { return }
        let rows = (shorts.count + 1) / 2
        if indexPath.row >= rows - 1 { loadMoreShorts() }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if tableView === shortsTable { return }   // shorts taps handled by the per-card button
        let vc = VideoPlayerVC(video: videos[indexPath.row])
        navigationController?.pushViewController(vc, animated: true)
    }
}

// MARK: - Shorts grid cell (2 portrait cards per row)
// A private grid row holding two ShortCardView columns. Not a separate file — mirrors the
// DownloadCell pattern of a VC-local UITableViewCell subclass.

private class ShortCardView: UIView {
    private let thumb = AsyncImageView()
    private let titleLabel = UILabel()
    private let tapBtn = UIButton(type: .custom)
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        thumb.backgroundColor = UIColor(white: 0.15, alpha: 1)
        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = 6
        thumb.layer.shouldRasterize = true
        thumb.layer.rasterizationScale = UIScreen.main.scale
        addSubview(thumb)

        titleLabel.backgroundColor = .clear
        titleLabel.textColor = UIColor(white: 0.95, alpha: 1)
        titleLabel.font = UIFont.systemFont(ofSize: 13)
        titleLabel.numberOfLines = 2
        addSubview(titleLabel)

        tapBtn.backgroundColor = .clear
        tapBtn.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        addSubview(tapBtn)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(_ v: Video) {
        isHidden = false
        titleLabel.text = v.title
        thumb.image = nil
        if !v.thumbnailURL.isEmpty { thumb.load(url: v.thumbnailURL) }
    }

    func clear() {
        isHidden = true
        onTap = nil
        thumb.cancel()
        thumb.image = nil
        titleLabel.text = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let thumbH = w * 16.0 / 9.0
        thumb.frame = CGRect(x: 0, y: 0, width: w, height: thumbH)
        titleLabel.frame = CGRect(x: 0, y: thumbH + 6, width: w, height: 34)
        tapBtn.frame = bounds
    }

    @objc private func tapped() { onTap?() }
}

private class ShortGridCell: UITableViewCell {
    static let reuseId = "ShortGridCell"
    private let left = ShortCardView()
    private let right = ShortCardView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
        selectionStyle = .none
        contentView.addSubview(left)
        contentView.addSubview(right)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configureLeft(_ v: Video, onTap: @escaping () -> Void) { left.configure(v); left.onTap = onTap }
    func configureRight(_ v: Video, onTap: @escaping () -> Void) { right.configure(v); right.onTap = onTap }
    func clearRight() { right.clear() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let pad: CGFloat = 12
        let w = contentView.bounds.width
        let cardW = (w - pad * 3) / 2
        let thumbH = cardW * 16.0 / 9.0
        let cardH = thumbH + 6 + 34
        left.frame = CGRect(x: pad, y: pad, width: cardW, height: cardH)
        right.frame = CGRect(x: pad * 2 + cardW, y: pad, width: cardW, height: cardH)
    }
}
