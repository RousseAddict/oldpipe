import UIKit

// MARK: - ChannelVC
// Channel page: header (name + subscribe toggle) over a 4-tab interface:
//   0 Videos    — the channel's video list (with "Load More")
//   1 Shorts    — the channel's short videos (lazy-loaded on first tap)
//   2 Playlists — the channel's YouTube playlists (lazy-loaded, one page, no "Load More")
//   3 About     — the channel's description text
// Reached by tapping a channel name in VideoPlayerVC or a row in ManageSubscriptionsVC.

class ChannelVC: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let channelId: String
    private var channelName: String
    private var avatarURL = ""
    private var channelDescription = ""

    // Videos tab
    private var videos: [Video] = []
    private var videosSeen = Set<String>()
    private var videosToken: String?
    private var videosLoadingMore = false
    private var videosLoadMoreBtn: UIButton?
    private var didLoadVideos = false

    // Shorts tab
    private var shorts: [Video] = []
    private var shortsSeen = Set<String>()
    private var shortsToken: String?
    private var shortsLoadingMore = false
    private var shortsLoadMoreBtn: UIButton?
    private var didLoadShorts = false

    // Playlists tab
    private var playlists: [YTPlaylist] = []
    private var didLoadPlaylists = false

    private var selectedTab = 0        // 0 Videos, 1 Shorts, 2 Playlists, 3 About

    private var didSetupUI = false

    private var headerView: UIView!
    private var avatarView: AsyncImageView!
    private var nameLabel: UILabel!
    private var subscribeBtn: UIButton!

    private var tabBar: UIView!
    private var tabButtons: [UIButton] = []
    private var tabIndicator: UIView!

    private var videosTable: UITableView!
    private var videosStatus: UILabel!
    private var shortsTable: UITableView!
    private var shortsStatus: UILabel!
    private var playlistsTable: UITableView!
    private var playlistsStatus: UILabel!
    private var aboutScroll: UIScrollView!
    private var aboutLabel: UILabel!

    private let bg = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
    private let accent = UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 1)

    private let navH: CGFloat = 64
    private let headerH: CGFloat = 96
    private let tabBarH: CGFloat = 44

    init(channelId: String, name: String) {
        self.channelId = channelId
        self.channelName = name
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = channelName.isEmpty ? "Channel" : channelName
        view.backgroundColor = bg
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didSetupUI else { return }
        didSetupUI = true
        setupUI()
        loadVideos()
    }

    #if IOS8_TARGET
    // iPad rotates its window natively; reflow the width-dependent bits that autoresizing
    // masks can't handle (the equal-width tabs, the indicator, and the About text).
    // Guarded to iPad — iPhone is portrait-locked so this never fires there. This whole
    // override is compiled ONLY into the iOS 8 build (-D IOS8_TARGET); the iOS 6/7 build
    // never sees it, so iOS 6 behavior is provably untouched.
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        guard UIDevice.current.userInterfaceIdiom == .pad, didSetupUI else { return }
        coordinator.animate(alongsideTransition: nil, completion: { [weak self] _ in
            guard let self = self else { return }
            let w = size.width
            let bw = w / CGFloat(max(self.tabButtons.count, 1))
            for (i, b) in self.tabButtons.enumerated() {
                b.frame = CGRect(x: bw * CGFloat(i), y: 0, width: bw, height: self.tabBarH)
            }
            self.updateTabIndicator()
            self.updateAboutContent()
        })
    }
    #endif

    private func setupUI() {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height

        headerView = UIView(frame: CGRect(x: 0, y: 0, width: w, height: headerH))
        headerView.backgroundColor = UIColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)
        headerView.autoresizingMask = iPadFlexWidth
        view.addSubview(headerView)

        avatarView = AsyncImageView(frame: CGRect(x: 12, y: 16, width: 64, height: 64))
        avatarView.backgroundColor = UIColor(white: 0.15, alpha: 1)
        avatarView.layer.cornerRadius = 32
        avatarView.clipsToBounds = true
        avatarView.layer.shouldRasterize = true
        avatarView.layer.rasterizationScale = UIScreen.main.scale
        headerView.addSubview(avatarView)
        if !avatarURL.isEmpty { avatarView.load(url: avatarURL) }

        nameLabel = UILabel(frame: CGRect(x: 88, y: 18, width: w - 100, height: 30))
        nameLabel.backgroundColor = .clear
        nameLabel.textColor = UIColor(white: 0.95, alpha: 1)
        nameLabel.font = UIFont.boldSystemFont(ofSize: 17)
        nameLabel.text = channelName
        nameLabel.autoresizingMask = iPadFlexWidth
        headerView.addSubview(nameLabel)

        subscribeBtn = UIButton(type: .custom)
        subscribeBtn.frame = CGRect(x: 88, y: 52, width: 130, height: 30)
        subscribeBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
        subscribeBtn.layer.cornerRadius = 6
        subscribeBtn.addTarget(self, action: #selector(toggleSubscribe), for: .touchUpInside)
        headerView.addSubview(subscribeBtn)
        refreshSubscribeButton()

        // Tab bar
        tabBar = UIView(frame: CGRect(x: 0, y: headerH, width: w, height: tabBarH))
        tabBar.backgroundColor = UIColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)
        tabBar.autoresizingMask = iPadFlexWidth
        view.addSubview(tabBar)

        let titles = ["Videos", "Shorts", "Playlists", "About"]
        let bw = w / CGFloat(titles.count)
        for (i, t) in titles.enumerated() {
            let b = UIButton(type: .custom)
            b.frame = CGRect(x: bw * CGFloat(i), y: 0, width: bw, height: tabBarH)
            b.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
            b.setTitle(t, for: .normal)
            b.setTitleColor(UIColor(white: 0.55, alpha: 1), for: .normal)
            b.tag = i
            b.addTarget(self, action: #selector(tabTapped(_:)), for: .touchUpInside)
            tabBar.addSubview(b)
            tabButtons.append(b)
        }
        // 0.5px hairline under the tab bar
        let hair = UIView(frame: CGRect(x: 0, y: tabBarH - 0.5, width: w, height: 0.5))
        hair.backgroundColor = UIColor(white: 0.2, alpha: 1)
        hair.autoresizingMask = iPadFlexWidth
        tabBar.addSubview(hair)

        tabIndicator = UIView(frame: CGRect(x: 0, y: tabBarH - 2, width: bw, height: 2))
        tabIndicator.backgroundColor = accent
        tabBar.addSubview(tabIndicator)

        // Content area frame
        let contentY = headerH + tabBarH
        let contentFrame = CGRect(x: 0, y: contentY, width: w, height: h - navH - contentY)

        // Videos table
        videosTable = makeTable(frame: contentFrame)
        view.addSubview(videosTable)
        videosStatus = makeStatus(width: w)
        videosStatus.text = "Loading..."
        videosTable.addSubview(videosStatus)

        // Shorts table
        shortsTable = makeTable(frame: contentFrame)
        shortsTable.isHidden = true
        view.addSubview(shortsTable)
        shortsStatus = makeStatus(width: w)
        shortsStatus.text = "Loading..."
        shortsTable.addSubview(shortsStatus)

        // Playlists table
        playlistsTable = makeTable(frame: contentFrame)
        playlistsTable.registerCell(YTPlaylistRowCell.self, YTPlaylistRowCell.reuseId)
        playlistsTable.isHidden = true
        view.addSubview(playlistsTable)
        playlistsStatus = makeStatus(width: w)
        playlistsStatus.text = "Loading..."
        playlistsTable.addSubview(playlistsStatus)

        // About
        aboutScroll = UIScrollView(frame: contentFrame)
        aboutScroll.backgroundColor = bg
        aboutScroll.isHidden = true
        aboutScroll.autoresizingMask = iPadFlexWidthHeight
        view.addSubview(aboutScroll)
        aboutLabel = UILabel(frame: CGRect(x: 16, y: 16, width: w - 32, height: 0))
        aboutLabel.backgroundColor = .clear
        aboutLabel.textColor = UIColor(white: 0.85, alpha: 1)
        aboutLabel.font = UIFont.systemFont(ofSize: 14)
        aboutLabel.numberOfLines = 0
        aboutScroll.addSubview(aboutLabel)

        updateTabIndicator()
    }

    private func makeTable(frame: CGRect) -> UITableView {
        let tv = UITableView(frame: frame)
        tv.backgroundColor = bg
        tv.separatorColor = UIColor(white: 0.2, alpha: 1)
        tv.dataSource = self
        tv.delegate = self
        tv.registerCell(VideoRowCell.self, VideoRowCell.reuseId)
        tv.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 60, right: 0)
        tv.tableFooterView = UIView()   // no empty separator rows while loading/empty
        tv.autoresizingMask = iPadFlexWidthHeight
        return tv
    }

    private func makeStatus(width w: CGFloat) -> UILabel {
        let l = UILabel(frame: CGRect(x: 20, y: 40, width: w - 40, height: 40))
        l.backgroundColor = .clear
        l.textColor = UIColor(white: 0.5, alpha: 1)
        l.textAlignment = .center
        l.font = UIFont.systemFont(ofSize: 15)
        l.autoresizingMask = iPadFlexWidth
        return l
    }

    // MARK: - Tabs

    @objc private func tabTapped(_ sender: UIButton) {
        selectTab(sender.tag)
    }

    private func selectTab(_ index: Int) {
        selectedTab = index
        videosTable.isHidden = (index != 0)
        shortsTable.isHidden = (index != 1)
        playlistsTable.isHidden = (index != 2)
        aboutScroll.isHidden = (index != 3)
        updateTabIndicator()

        if index == 1 { loadShorts() }
        if index == 2 { loadPlaylists() }
        if index == 3 { updateAboutContent() }
    }

    private func updateTabIndicator() {
        for (i, b) in tabButtons.enumerated() {
            b.setTitleColor(i == selectedTab ? accent : UIColor(white: 0.55, alpha: 1), for: .normal)
        }
        let bw = UIScreen.main.bounds.width / CGFloat(max(tabButtons.count, 1))
        tabIndicator.frame = CGRect(x: bw * CGFloat(selectedTab), y: tabBarH - 2, width: bw, height: 2)
    }

    // MARK: - Subscribe

    private func refreshSubscribeButton() {
        guard subscribeBtn != nil else { return }
        let subscribed = SubscriptionManager.isSubscribed(channelId)
        if subscribed {
            subscribeBtn.setTitle("Subscribed", for: .normal)
            subscribeBtn.setTitleColor(UIColor(white: 0.7, alpha: 1), for: .normal)
            subscribeBtn.backgroundColor = UIColor(white: 0.18, alpha: 1)
        } else {
            subscribeBtn.setTitle("Subscribe", for: .normal)
            subscribeBtn.setTitleColor(.white, for: .normal)
            subscribeBtn.backgroundColor = accent
        }
    }

    @objc private func toggleSubscribe() {
        if SubscriptionManager.isSubscribed(channelId) {
            SubscriptionManager.unsubscribe(channelId)
        } else {
            SubscriptionManager.subscribe(Channel(id: channelId, name: channelName, thumbnailURL: avatarURL))
        }
        refreshSubscribeButton()
    }

    // MARK: - Loading (Videos)

    private func loadVideos() {
        guard !didLoadVideos else { return }
        didLoadVideos = true
        YoutubeAPI.getChannelVideos(channelId: channelId, priority: true) { [weak self] vids, channel, token in
            guard let self = self else { return }
            self.videos = vids
            self.videosSeen = Set(vids.map { $0.id })
            self.videosToken = token
            if let c = channel {
                if !c.name.isEmpty {
                    self.channelName = c.name
                    self.title = c.name
                    self.nameLabel?.text = c.name
                }
                if !c.thumbnailURL.isEmpty {
                    self.avatarURL = c.thumbnailURL
                    self.avatarView?.load(url: c.thumbnailURL)
                }
                if !c.channelDescription.isEmpty {
                    self.channelDescription = c.channelDescription
                    self.updateAboutContent()
                }
                // Keep the stored subscription avatar fresh (heals blank icons elsewhere).
                SubscriptionManager.updateThumbnail(channelId: self.channelId,
                                                    thumbnailURL: c.thumbnailURL, name: c.name)
            }
            self.videosStatus?.isHidden = !vids.isEmpty
            if vids.isEmpty { self.videosStatus?.text = "No videos found" }
            self.videosTable?.reloadData()
            self.updateLoadMoreFooter(tab: 0)
        }
    }

    // MARK: - Loading (Shorts)

    private func loadShorts() {
        guard !didLoadShorts else { return }
        didLoadShorts = true
        YoutubeAPI.getChannelShorts(channelId: channelId, priority: true) { [weak self] vids, token in
            guard let self = self else { return }
            self.shorts = vids
            self.shortsSeen = Set(vids.map { $0.id })
            self.shortsToken = token
            self.shortsStatus?.isHidden = !vids.isEmpty
            if vids.isEmpty { self.shortsStatus?.text = "No shorts found" }
            self.shortsTable?.reloadData()
            self.updateLoadMoreFooter(tab: 1)
        }
    }

    // MARK: - Loading (Playlists)

    // One page only — the Playlists tab's own continuation is not wired up, so there is no
    // "Load More" here (unlike the Videos/Shorts tabs).
    private func loadPlaylists() {
        guard !didLoadPlaylists else { return }
        didLoadPlaylists = true
        YoutubeAPI.getChannelPlaylists(channelId: channelId, priority: true) { [weak self] lists in
            guard let self = self else { return }
            self.playlists = lists
            self.playlistsStatus?.isHidden = !lists.isEmpty
            if lists.isEmpty { self.playlistsStatus?.text = "No playlists found" }
            self.playlistsTable?.reloadData()
        }
    }

    // MARK: - About

    private func updateAboutContent() {
        guard aboutLabel != nil else { return }
        let w = UIScreen.main.bounds.width
        if channelDescription.isEmpty {
            aboutLabel.text = didLoadVideos ? "No description available." : "Loading..."
            aboutLabel.textColor = UIColor(white: 0.5, alpha: 1)
        } else {
            aboutLabel.text = channelDescription
            aboutLabel.textColor = UIColor(white: 0.85, alpha: 1)
        }
        let maxW = w - 32
        let size = aboutLabel.sizeThatFits(CGSize(width: maxW, height: .greatestFiniteMagnitude))
        aboutLabel.frame = CGRect(x: 16, y: 16, width: maxW, height: size.height)
        aboutScroll.contentSize = CGSize(width: w, height: size.height + 32 + 60)
    }

    // MARK: - Load More footer

    // A "Load More" button shown as the active table's footer while a token exists.
    private func updateLoadMoreFooter(tab: Int) {
        let tv = (tab == 0) ? videosTable : shortsTable
        guard let tv = tv else { return }
        let token = (tab == 0) ? videosToken : shortsToken
        let list = (tab == 0) ? videos : shorts
        guard token != nil, !list.isEmpty else {
            tv.tableFooterView = UIView()   // also hides empty separator rows
            return
        }
        let loading = (tab == 0) ? videosLoadingMore : shortsLoadingMore
        let existing = (tab == 0) ? videosLoadMoreBtn : shortsLoadMoreBtn
        let btn: UIButton
        if let e = existing {
            btn = e
        } else {
            btn = UIButton(type: .custom)
            btn.frame = CGRect(x: 0, y: 0, width: tv.bounds.width, height: 56)
            btn.backgroundColor = UIColor(white: 0.12, alpha: 1)
            btn.setTitleColor(.white, for: .normal)
            btn.setTitleColor(UIColor(white: 0.5, alpha: 1), for: .disabled)
            btn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
            btn.tag = tab
            btn.addTarget(self, action: #selector(loadMoreTapped(_:)), for: .touchUpInside)
            if tab == 0 { videosLoadMoreBtn = btn } else { shortsLoadMoreBtn = btn }
        }
        btn.isEnabled = !loading
        btn.setTitle(loading ? "Loading..." : "Load More", for: .normal)
        tv.tableFooterView = btn
    }

    @objc private func loadMoreTapped(_ sender: UIButton) {
        let tab = sender.tag
        if tab == 0 {
            guard let token = videosToken, !videosLoadingMore else { return }
            videosLoadingMore = true
            updateLoadMoreFooter(tab: 0)
            YoutubeAPI.getChannelContinuation(token: token, channelName: channelName, priority: true) { [weak self] vids, next in
                guard let self = self else { return }
                self.videosLoadingMore = false
                self.videosToken = next
                for v in vids where !self.videosSeen.contains(v.id) {
                    self.videosSeen.insert(v.id)
                    self.videos.append(v)
                }
                self.videosTable?.reloadData()
                self.updateLoadMoreFooter(tab: 0)
            }
        } else {
            guard let token = shortsToken, !shortsLoadingMore else { return }
            shortsLoadingMore = true
            updateLoadMoreFooter(tab: 1)
            YoutubeAPI.getChannelContinuation(token: token, channelName: channelName, priority: true) { [weak self] vids, next in
                guard let self = self else { return }
                self.shortsLoadingMore = false
                self.shortsToken = next
                for v in vids where !self.shortsSeen.contains(v.id) {
                    self.shortsSeen.insert(v.id)
                    self.shorts.append(v)
                }
                self.shortsTable?.reloadData()
                self.updateLoadMoreFooter(tab: 1)
            }
        }
    }

    // MARK: - UITableViewDataSource

    private func list(for tableView: UITableView) -> [Video] {
        return (tableView == shortsTable) ? shorts : videos
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if tableView == playlistsTable { return playlists.count }
        return list(for: tableView).count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if tableView == playlistsTable {
            let cell = tableView.dequeueCell(YTPlaylistRowCell.self, YTPlaylistRowCell.reuseId, for: indexPath)
            cell.configure(with: playlists[indexPath.row])
            return cell
        }
        let cell = tableView.dequeueCell(VideoRowCell.self, VideoRowCell.reuseId, for: indexPath)
        cell.configure(with: list(for: tableView)[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return VideoRowCell.rowHeight
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if tableView == playlistsTable {
            let p = playlists[indexPath.row]
            navigationController?.pushViewController(YTPlaylistVC(playlistId: p.id, title: p.title), animated: true)
            return
        }
        let vc = VideoPlayerVC(video: list(for: tableView)[indexPath.row])
        navigationController?.pushViewController(vc, animated: true)
    }
}

// MARK: - YTPlaylistRowCell
// Row for the Playlists tab: thumbnail + title + "N videos". Same metrics as VideoRowCell
// so both tables can share heightForRowAt.
private class YTPlaylistRowCell: UITableViewCell {

    static let reuseId = "YTPlaylistRowCell"

    // AsyncImageView so reuse cancels the in-flight thumbnail request (see prepareForReuse).
    private let thumb = AsyncImageView()
    private let titleLabel = UILabel()
    private let countLabel = UILabel()

    required override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)

        thumb.backgroundColor = UIColor(white: 0.15, alpha: 1)
        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = 4
        thumb.layer.shouldRasterize = true
        thumb.layer.rasterizationScale = UIScreen.main.scale
        contentView.addSubview(thumb)

        titleLabel.backgroundColor = .clear
        titleLabel.textColor = UIColor(white: 0.95, alpha: 1)
        titleLabel.font = UIFont.systemFont(ofSize: 14)
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)

        countLabel.backgroundColor = .clear
        countLabel.textColor = UIColor(white: 0.55, alpha: 1)
        countLabel.font = UIFont.systemFont(ofSize: 12)
        contentView.addSubview(countLabel)

        accessoryType = .disclosureIndicator
        let sel = UIView()
        sel.backgroundColor = UIColor(white: 0.15, alpha: 1)
        selectedBackgroundView = sel
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(with playlist: YTPlaylist) {
        titleLabel.text = playlist.title
        countLabel.text = playlist.countText

        thumb.cancel()
        thumb.image = nil
        guard !playlist.thumbnailURL.isEmpty else { return }
        thumb.load(url: playlist.thumbnailURL)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumb.cancel()
        thumb.image = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = contentView.bounds.width
        let pad: CGFloat = 8
        let tW: CGFloat = 120, tH: CGFloat = 64

        thumb.frame = CGRect(x: pad, y: pad, width: tW, height: tH)
        let textX = pad + tW + 10
        let textW = max(0, w - textX - pad)
        titleLabel.frame = CGRect(x: textX, y: pad, width: textW, height: 36)
        countLabel.frame = CGRect(x: textX, y: pad + 38, width: textW, height: 18)
    }
}
