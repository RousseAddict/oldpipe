import UIKit

// MARK: - HomeVC
// Root VC. A feed of the latest videos from subscribed channels.
// Top-right "Search" button pushes SearchVC. Top-left "Menu" opens a slide-in
// side menu with Subscriptions + Downloads. Empty state when no subscriptions.
//
// Also serves as a channel GROUP feed: init(groupId:) narrows every feed path to that
// group's channels (see feedChannels()). The only state HomeVC instances share is the
// per-channel FeedCache, keyed by channel id, so a group instance pushed on the nav stack is
// safe and warms the root feed's cache (and vice versa).

class HomeVC: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let groupId: String?   // nil = root Home (all subscriptions)

    private var videos: [Video] = []
    private var didSetupUI = false
    private var builtChannelIds: Set<String> = []
    private var isLoading = false

    private var tableView: UITableView!
    private var statusLabel: UILabel!
    #if !IOS5_TARGET
    private var refreshControl: UIRefreshControl?
    #endif

    // UIRefreshControl is iOS 6+, so the iOS 5 build simply has no pull-to-refresh
    // and this is a no-op; every other target forwards to the control.
    private func endPullToRefresh() {
        #if !IOS5_TARGET
        refreshControl?.endRefreshing()
        #endif
    }

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

    // Coalesces the progressive "show results as they arrive" reloads into a couple of
    // smooth refreshes instead of one flicker per channel that returns.
    private var reloadTimer: Timer?

    // MARK: - Per-channel feed cache
    // Each subscribed channel's newest few videos and Shorts, under its own id with the time it
    // was fetched (see FeedCache at the bottom of this file). Adding a channel therefore only
    // fetches THAT channel — every other channel renders instantly from cache. Stale (>TTL) or
    // missing channels are refetched.
    private static let feedCache = FeedCache()

    // Wipe the cached feed (Settings → Reset Cache). Subscriptions/playlists are untouched.
    static func clearFeedCache() {
        feedCache.clear()
    }

    init(groupId: String? = nil) {
        self.groupId = groupId
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // The channels this feed covers: every subscription, or — for a group feed — only the
    // subscribed channels in that group. Intersecting with the live subscription list here
    // is what makes unsubscribing need no group cleanup.
    private func feedChannels() -> [Channel] {
        let subs = SubscriptionManager.all()
        guard let gid = groupId, let g = ChannelGroupManager.group(id: gid) else { return subs }
        let ids = Set(g.channelIds)
        return subs.filter { ids.contains($0.id) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        CrashLog.mark("HomeVC: viewDidLoad")
        view.backgroundColor = bg
        if let gid = groupId {
            // A group feed is pushed, so the nav back button takes the Menu button's place.
            title = ChannelGroupManager.group(id: gid)?.name ?? "Group"
        } else {
            title = "oldpipe"
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                title: "Menu", style: .plain, target: self, action: #selector(toggleMenu))
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Search", style: .plain, target: self, action: #selector(showSearch))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        CrashLog.mark("HomeVC: viewDidAppear didSetupUI=\(didSetupUI)")
        if !didSetupUI {
            didSetupUI = true
            setupUI()
        }
        CrashLog.mark("HomeVC: setupUI done")
        applyShortsTabVisibility()   // reflects the current Settings toggle (may have changed)
        refreshFeedIfNeeded()
        CrashLog.mark("HomeVC: viewDidAppear done")
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
        tableView.registerCell(VideoRowCell.self, VideoRowCell.reuseId)
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 60, right: 0)
        tableView.tableFooterView = UIView()   // no empty separator rows while loading/empty
        // iPad rotates natively; the flexible masks (here + on the status label, loading bar
        // and side menu) reflow the layout in landscape. iPhone is portrait-locked in the
        // pbxproj so autoresizing never triggers there.
        tableView.autoresizingMask = iPadFlexWidthHeight
        view.addSubview(tableView)

        // Pull-to-refresh (UIRefreshControl is iOS 6+; add as a subview of the plain
        // table). The iOS 5 build goes without it — the feed still reloads on appear.
        #if !IOS5_TARGET
        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        tableView.addSubview(rc)
        refreshControl = rc
        #endif

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
        seg.backgroundColor = Theme.accent.cgColor
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
        st.registerCell(ShortGridCell.self, ShortGridCell.reuseId)
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
        ind.backgroundColor = Theme.accent
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
            b.setTitleColor(i == selectedHomeTab ? Theme.accent : UIColor(white: 0.55, alpha: 1), for: .normal)
        }
        let bw = UIScreen.main.bounds.width / CGFloat(max(tabButtons.count, 1))
        tabIndicator?.frame = CGRect(x: bw * CGFloat(selectedHomeTab), y: tabBarH - 2, width: bw, height: 2)
    }

    // MARK: - Shorts feed loading (fixed first batch — no load-more)

    private func loadShortsFeed() {
        let subs = feedChannels()
        let ids = Set(subs.map { $0.id })

        if subs.isEmpty {
            shorts = []
            shortsBuiltChannelIds = []
            shortsStatus?.text = groupId != nil
                ? "No channels in this group."
                : "No subscriptions yet.\nSubscribe to channels to see their Shorts."
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

        let now = Date().timeIntervalSince1970
        let toFetch = subs.filter { HomeVC.feedCache.shorts.isDue($0.id, now: now) }
        guard !toFetch.isEmpty else { return }

        shortsLoading = true
        if shorts.isEmpty {
            shortsStatus?.text = "Loading shorts..."
            shortsStatus?.isHidden = false
        }

        var remaining = toFetch.count
        for channel in toFetch {
            // priority:false — Shorts is a background feed like the videos feed.
            YoutubeAPI.getChannelShorts(channelId: channel.id, priority: false) { [weak self] vids, fresh, token in
                // Stored before the self check, and a failure keeps the cached copy — the same
                // rules as the videos feed (see loadFeed).
                if fresh != nil || !vids.isEmpty {
                    HomeVC.feedCache.store(Array(vids.prefix(12)), in: .shorts, for: channel.id)
                } else {
                    HomeVC.feedCache.recordFailure(in: .shorts, for: channel.id)
                }
                guard let self = self else { return }
                // Stash this channel's continuation token for infinite scroll (drop if absent).
                if let t = token, !t.isEmpty { self.shortsTokens[channel.id] = t }
                else { self.shortsTokens.removeValue(forKey: channel.id) }
                self.scheduleShortsReload()
                remaining -= 1
                if remaining == 0 { self.finishShortsFeed() }
            }
            // The Shorts tab gives us no publish date, so pull the channel's Atom feed for one.
            // Deliberately NOT part of the `remaining` count: it is an ordering improvement, so
            // the feed must never wait on it, and a failed fetch just leaves those Shorts in the
            // shuffled tail. Whichever lands last triggers the coalesced rebuild.
            ChannelRSS.fetchPublishDates(channelId: channel.id, priority: false) { [weak self] dates in
                guard !dates.isEmpty else { return }
                HomeVC.feedCache.storeShortsDates(dates, for: channel.id)
                self?.scheduleShortsReload()
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
        let subs = feedChannels()
        let cached = HomeVC.feedCache.shorts.byChannel
        var merged: [Video] = []
        var seen = Set<String>()
        for ch in subs {
            for v in cached[ch.id] ?? [] where !seen.contains(v.id) {
                seen.insert(v.id)
                merged.append(v)
            }
        }
        // The shortsLockupViewModel these came from has no date field, so the date comes from
        // the channel's Atom feed instead (ChannelRSS), which does list Shorts. Anything the
        // feed covered — the recent Shorts, which is what the top of the feed is — sorts
        // newest-first; the rest keeps the old shuffle and follows behind, because
        // concatenating them per channel would make the tail feel grouped ("all of channel A,
        // then all of channel B"). shuffle() and sorted() are pure Swift stdlib
        // (runtime-independent, safe on 5.1.5).
        let dates = HomeVC.feedCache.allShortsDates()
        for i in 0..<merged.count {
            if let ts = dates[merged[i].id] { merged[i].publishedTimestamp = ts }
        }
        merged.shuffle()
        let dated = merged.filter { $0.publishedTimestamp > 0 }
            .sorted { $0.publishedTimestamp > $1.publishedTimestamp }
        merged = dated + merged.filter { $0.publishedTimestamp <= 0 }
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
        let names = Dictionary(feedChannels().map { ($0.id, $0.name) },
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
        band.backgroundColor = Theme.accent
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
            btn.setTitleColor(Theme.accent, for: .highlighted)
            btn.titleLabel?.font = UIFont.systemFont(ofSize: 16)
            btn.addTarget(self, action: sel, for: .touchUpInside)
            menuPanel.addSubview(btn)

            // accent leading tab
            let tab = UIView(frame: CGRect(x: 0, y: y + 14, width: 4, height: rowH - 28))
            tab.backgroundColor = Theme.accent
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
        // The Shorts tab bar/table (if enabled later, from Settings reached via this very
        // menu) is built lazily too and may be added to `view` AFTER menuOverlay, which
        // would otherwise leave it stacked above the menu. Always bring the menu to front
        // on open so z-order is correct regardless of which UI was built first.
        view.bringSubviewToFront(menuOverlay)
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
        let subs = feedChannels()
        let ids = Set(subs.map { $0.id })

        if subs.isEmpty {
            videos = []
            builtChannelIds = []
            statusLabel?.text = groupId != nil
                ? "No channels in this group."
                : "No subscriptions yet.\nTap Search, open a channel, and tap Subscribe."
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

        // Fetch only channels whose cache is missing or stale (>TTL), and not failing right now.
        let now = Date().timeIntervalSince1970
        let toFetch = subs.filter { HomeVC.feedCache.videos.isDue($0.id, now: now) }
        guard !toFetch.isEmpty else { return }
        loadFeed(channels: toFetch)
    }

    // Pull-to-refresh: force a refetch of every channel, ignoring cache freshness.
    @objc private func handleRefresh() {
        let subs = feedChannels()
        if subs.isEmpty || isLoading {
            endPullToRefresh()
            return
        }
        builtChannelIds = Set(subs.map { $0.id })
        loadFeed(channels: subs, isRefresh: true)
    }

    // Fetch the given channels in parallel (CurlFetcher caps concurrency at 4). Each result
    // is cached per-channel and triggers a coalesced re-render, so videos appear as they
    // arrive rather than all at once when the slowest channel finishes.
    private func loadFeed(channels toFetch: [Channel], isRefresh: Bool = false) {
        CrashLog.mark("HomeVC: loadFeed n=\(toFetch.count)")
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
                // Stored before the self check: the cache is shared, so a group feed popped
                // mid-load still warms the root feed with what it paid for. A failed request —
                // no channel metadata and no videos — keeps the cached copy and leaves the
                // channel stale, so it is retried (see FeedCache.Lists.isDue) instead of showing
                // nothing for the whole TTL. A channel that really has no videos still answers
                // with its metadata, so its empty list is stored and not refetched every appear.
                if fresh != nil || !vids.isEmpty {
                    // Keep newest few per channel (channel browse returns newest-first).
                    HomeVC.feedCache.store(Array(vids.prefix(6)), in: .videos, for: channel.id)
                } else {
                    HomeVC.feedCache.recordFailure(in: .videos, for: channel.id)
                }
                guard let self = self else { return }
                // Heal the stored avatar/name from the fresh channel result (fixes blank
                // icons in ManageSubscriptionsVC for subs saved before their avatar was known).
                if let c = fresh {
                    SubscriptionManager.updateThumbnail(channelId: channel.id,
                                                        thumbnailURL: c.thumbnailURL, name: c.name)
                }
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
        endPullToRefresh()
        reloadTimer?.invalidate()
        reloadTimer = nil
        rebuildFromCache()
    }

    // Merge every subscribed channel's cached videos, de-dupe, and sort newest-first.
    private func rebuildFromCache() {
        CrashLog.mark("HomeVC: rebuildFromCache")
        let subs = feedChannels()
        let cached = HomeVC.feedCache.videos.byChannel
        var merged: [Video] = []
        var seen = Set<String>()
        for ch in subs {
            for v in cached[ch.id] ?? [] where !seen.contains(v.id) {
                seen.insert(v.id)
                merged.append(v)
            }
        }
        // Newest first, by the absolute publish time worked out when each channel was fetched
        // (0 = unknown, sorts last). Sorting on the "3 days ago" text itself parsed both strings
        // on every comparison, and compared texts captured at different times.
        merged.sort { $0.publishedTimestamp > $1.publishedTimestamp }
        videos = merged
        if merged.isEmpty {
            let emptyText = groupId != nil
                ? "No recent videos from this group."
                : "No recent videos from your subscriptions."
            statusLabel?.text = isLoading ? "Loading subscriptions..." : emptyText
            statusLabel?.isHidden = false
        } else {
            statusLabel?.isHidden = true
        }
        tableView?.reloadData()
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if tableView === shortsTable { return (shorts.count + 1) / 2 }   // 2 cards per row
        return videos.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if tableView === shortsTable {
            let cell = tableView.dequeueCell(ShortGridCell.self, ShortGridCell.reuseId, for: indexPath)
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
        let cell = tableView.dequeueCell(VideoRowCell.self, VideoRowCell.reuseId, for: indexPath)
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
        let video = videos[indexPath.row]
        DebugLog.log("Home", "tap video id=\(video.id) title=\"\(video.title)\" channel=\(video.channelName)")
        navigationController?.openVideo(video)
    }
}

// MARK: - Feed cache
// What HomeVC renders its feeds from: each subscribed channel's newest few videos and Shorts,
// stamped with when they were fetched, plus the Shorts publish dates read from each channel's
// Atom feed (the innertube Shorts tab carries none — see ChannelRSS).
//
// Held in memory, already decoded, and written to its own file in Caches — every couple of
// seconds while it changes, and when the app goes to the background. It used to live in
// UserDefaults, which cost the main thread twice over: every channel that came back re-read
// the whole map, wrote it back and synchronize()d — once per channel per load — and because a
// defaults domain is saved as one file, every synchronize() anywhere else in the app rewrote
// the whole feed as well.
//
// Main thread only; the file is written on ioQueue, from a copy.
private final class FeedCache: NSObject {

    static let ttl: TimeInterval = 1800        // 30 min — older entries are refetched
    static let retryDelay: TimeInterval = 120  // between attempts at a channel that failed

    enum Kind { case videos, shorts }

    // One kind of per-channel list (videos or Shorts): what each channel returned, and when.
    struct Lists {
        var byChannel: [String: [Video]] = [:]
        var fetchedAt: [String: Double] = [:]   // channelId → epoch seconds of the last success
        // channelId → epoch seconds of the last failed fetch. Memory only: not worth keeping
        // across launches.
        var failedAt: [String: Double] = [:]

        // Whether to fetch the channel now: nothing fetched within the TTL, and no failure in
        // the last retryDelay — so a channel that keeps failing (offline, or since deleted) is
        // retried every couple of minutes, not on every appear.
        func isDue(_ channelId: String, now: Double) -> Bool {
            if let t = fetchedAt[channelId], now - t >= 0, now - t < FeedCache.ttl { return false }
            if let t = failedAt[channelId], now - t >= 0, now - t < FeedCache.retryDelay { return false }
            return true
        }
    }

    private(set) var videos = Lists()
    private(set) var shorts = Lists()
    private var shortsDates: [String: [String: Double]] = [:]   // channelId → videoId → epoch

    // The file's keys are the UserDefaults keys the cache used to live under, so the old copy
    // decodes exactly like the file.
    private static let videosKey = "home_channel_cache"           // [channelId: [videoDict]]
    private static let videosTimeKey = "home_channel_cache_time"  // [channelId: epochSeconds]
    private static let shortsKey = "home_shorts_cache"
    private static let shortsTimeKey = "home_shorts_cache_time"
    private static let shortsDatesKey = "home_shorts_dates"       // [channelId: [videoId: epochSeconds]]
    private static let keys = [videosKey, videosTimeKey, shortsKey, shortsTimeKey, shortsDatesKey]
    // The whole-feed cache from before the per-channel one. Only ever removed.
    private static let legacyKeys = ["home_feed_cache", "home_feed_cache_subs", "home_feed_cache_time"]

    private static let path: String = {
        let dirs = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)
        let base = dirs.first ?? NSTemporaryDirectory()
        return (base as NSString).appendingPathComponent("com.oldpipe.feedcache.plist")
    }()

    // Serial, so writes and a reset's delete land in the order they were asked for.
    private static let ioQueue = AppQueue(label: "com.oldpipe.feedcache")

    private var saveScheduled = false

    override init() {
        super.init()
        load()
        // What is still waiting to be written goes out before the app can be suspended — and
        // then possibly killed without another chance.
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification,
                                               object: nil)
    }

    // MARK: Updates

    func store(_ list: [Video], in kind: Kind, for channelId: String) {
        update(kind) { lists in
            lists.byChannel[channelId] = list
            lists.fetchedAt[channelId] = Date().timeIntervalSince1970
            lists.failedAt[channelId] = nil
        }
        setNeedsSave()
    }

    // A failed fetch keeps whatever was cached for the channel and leaves it stale.
    func recordFailure(in kind: Kind, for channelId: String) {
        update(kind) { $0.failedAt[channelId] = Date().timeIntervalSince1970 }
    }

    func storeShortsDates(_ dates: [String: Double], for channelId: String) {
        shortsDates[channelId] = dates
        setNeedsSave()
    }

    // Flattened videoId → publish date across every channel's Atom feed.
    func allShortsDates() -> [String: Double] {
        var out: [String: Double] = [:]
        for (_, perChannel) in shortsDates {
            for (videoId, ts) in perChannel where ts > 0 { out[videoId] = ts }
        }
        return out
    }

    // Settings → Reset Cache / Reset All.
    func clear() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(scheduledSave), object: nil)
        saveScheduled = false
        videos = Lists()
        shorts = Lists()
        shortsDates = [:]
        let path = FeedCache.path
        FeedCache.ioQueue.async { try? FileManager.default.removeItem(atPath: path) }
    }

    private func update(_ kind: Kind, _ change: (inout Lists) -> Void) {
        switch kind {
        case .videos: change(&videos)
        case .shorts: change(&shorts)
        }
    }

    // MARK: Persistence

    private func load() {
        let defaults = UserDefaults.standard
        if let data = try? Data(contentsOf: URL(fileURLWithPath: FeedCache.path)),
           let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            decode(root)
        } else {
            // First launch since the move out of UserDefaults: adopt the copy kept there, and
            // write it straight out, since it is about to be removed below.
            var root: [String: Any] = [:]
            for k in FeedCache.keys { root[k] = defaults.object(forKey: k) }
            decode(root)
            if !root.isEmpty { save() }
        }
        // Checked on every launch, not only the one that adopts them: a removal only reaches
        // disk with a later defaults sync, which an app killed early never gets to.
        for k in FeedCache.keys + FeedCache.legacyKeys where defaults.object(forKey: k) != nil {
            defaults.removeObject(forKey: k)
        }
    }

    private func decode(_ root: [String: Any]) {
        videos = Lists(byChannel: FeedCache.videoLists(root[FeedCache.videosKey]),
                       fetchedAt: FeedCache.numbers(root[FeedCache.videosTimeKey]))
        shorts = Lists(byChannel: FeedCache.videoLists(root[FeedCache.shortsKey]),
                       fetchedAt: FeedCache.numbers(root[FeedCache.shortsTimeKey]))
        var dates: [String: [String: Double]] = [:]
        for (channelId, perChannel) in (root[FeedCache.shortsDatesKey] as? [String: Any]) ?? [:] {
            dates[channelId] = FeedCache.numbers(perChannel)
        }
        shortsDates = dates
    }

    private static func videoLists(_ value: Any?) -> [String: [Video]] {
        var out: [String: [Video]] = [:]
        for (channelId, list) in (value as? [String: Any]) ?? [:] {
            guard let dicts = list as? [[String: Any]] else { continue }
            out[channelId] = dicts.compactMap { Video.from(dict: $0) }
        }
        return out
    }

    // [key: NSNumber] → [key: Double]. Through NSNumber because a direct `as? Double` silently
    // returns nil on the Swift 5.1.5 runtime.
    private static func numbers(_ value: Any?) -> [String: Double] {
        var out: [String: Double] = [:]
        for (key, n) in (value as? [String: Any]) ?? [:] {
            if let d = (n as? NSNumber)?.doubleValue { out[key] = d }
        }
        return out
    }

    // A feed load stores one channel at a time. The first change schedules a write a couple of
    // seconds out and the ones after it ride along, so a load writes at most every couple of
    // seconds — and a long one still reaches disk as it goes.
    private func setNeedsSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        perform(#selector(scheduledSave), with: nil, afterDelay: 2, inModes: [.common])
    }

    @objc private func scheduledSave() {
        save()
    }

    // Written before returning: once this returns, the app can be suspended at any moment.
    @objc private func appDidEnterBackground() {
        if saveScheduled { save(waitUntilWritten: true) }
    }

    private func save(waitUntilWritten: Bool = false) {
        // Also called directly; a write scheduled for later would only repeat this one.
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(scheduledSave), object: nil)
        saveScheduled = false
        // Copied here on main; encoded and written on ioQueue.
        let videos = self.videos, shorts = self.shorts, dates = shortsDates
        let path = FeedCache.path
        let write: () -> Void = {
            let root: [String: Any] = [
                FeedCache.videosKey: videos.byChannel.mapValues { $0.map { $0.toDict() } },
                FeedCache.videosTimeKey: videos.fetchedAt,
                FeedCache.shortsKey: shorts.byChannel.mapValues { $0.map { $0.toDict() } },
                FeedCache.shortsTimeKey: shorts.fetchedAt,
                FeedCache.shortsDatesKey: dates
            ]
            guard let data = try? PropertyListSerialization.data(fromPropertyList: root,
                                                                 format: .binary, options: 0)
            else { return }
            _ = (data as NSData).write(toFile: path, atomically: true)
        }
        if waitUntilWritten {
            FeedCache.ioQueue.sync(execute: write)
        } else {
            FeedCache.ioQueue.async(execute: write)
        }
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

    required override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
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
