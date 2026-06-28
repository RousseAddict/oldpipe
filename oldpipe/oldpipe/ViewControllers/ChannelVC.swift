import UIKit

// MARK: - ChannelVC
// Channel page: header (name + subscribe toggle) over a video list.
// Reached by tapping a channel name in VideoPlayerVC or a row in ManageSubscriptionsVC.

class ChannelVC: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let channelId: String
    private var channelName: String
    private var avatarURL = ""

    private var videos: [Video] = []
    private var seenIds = Set<String>()
    private var continuationToken: String?
    private var isLoadingMore = false
    private var didSetupUI = false
    private var didLoad = false
    private var loadMoreBtn: UIButton?

    private var headerView: UIView!
    private var avatarView: AsyncImageView!
    private var nameLabel: UILabel!
    private var subscribeBtn: UIButton!
    private var tableView: UITableView!
    private var statusLabel: UILabel!

    private let bg = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)

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

    private func setupUI() {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        let navH: CGFloat = 64
        let headerH: CGFloat = 96

        headerView = UIView(frame: CGRect(x: 0, y: 0, width: w, height: headerH))
        headerView.backgroundColor = UIColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)
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
        headerView.addSubview(nameLabel)

        subscribeBtn = UIButton(type: .custom)
        subscribeBtn.frame = CGRect(x: 88, y: 52, width: 130, height: 30)
        subscribeBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
        subscribeBtn.layer.cornerRadius = 6
        subscribeBtn.addTarget(self, action: #selector(toggleSubscribe), for: .touchUpInside)
        headerView.addSubview(subscribeBtn)
        refreshSubscribeButton()

        tableView = UITableView(frame: CGRect(x: 0, y: headerH, width: w, height: h - navH - headerH))
        tableView.backgroundColor = bg
        tableView.separatorColor = UIColor(white: 0.2, alpha: 1)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(VideoRowCell.self, forCellReuseIdentifier: VideoRowCell.reuseId)
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 60, right: 0)
        tableView.tableFooterView = UIView()   // no empty separator rows while loading/empty
        view.addSubview(tableView)

        statusLabel = UILabel(frame: CGRect(x: 20, y: 40, width: w - 40, height: 40))
        statusLabel.backgroundColor = .clear
        statusLabel.textColor = UIColor(white: 0.5, alpha: 1)
        statusLabel.textAlignment = .center
        statusLabel.font = UIFont.systemFont(ofSize: 15)
        statusLabel.text = "Loading..."
        tableView.addSubview(statusLabel)
    }

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
            subscribeBtn.backgroundColor = UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 1)
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

    private func loadVideos() {
        guard !didLoad else { return }
        didLoad = true
        YoutubeAPI.getChannelVideos(channelId: channelId) { [weak self] vids, channel, token in
            guard let self = self else { return }
            self.videos = vids
            self.seenIds = Set(vids.map { $0.id })
            self.continuationToken = token
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
            }
            self.statusLabel?.isHidden = !vids.isEmpty
            if vids.isEmpty { self.statusLabel?.text = "No videos found" }
            self.tableView?.reloadData()
            self.updateLoadMoreFooter()
        }
    }

    // A "Load More" button shown as the table footer while a continuation token exists.
    private func updateLoadMoreFooter() {
        guard let tv = tableView else { return }
        guard continuationToken != nil, !videos.isEmpty else {
            tv.tableFooterView = UIView()   // also hides empty separator rows
            return
        }
        let btn: UIButton
        if let existing = loadMoreBtn {
            btn = existing
        } else {
            btn = UIButton(type: .custom)
            btn.frame = CGRect(x: 0, y: 0, width: tv.bounds.width, height: 56)
            btn.backgroundColor = UIColor(white: 0.12, alpha: 1)
            btn.setTitleColor(.white, for: .normal)
            btn.setTitleColor(UIColor(white: 0.5, alpha: 1), for: .disabled)
            btn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
            btn.addTarget(self, action: #selector(loadMoreTapped), for: .touchUpInside)
            loadMoreBtn = btn
        }
        btn.isEnabled = !isLoadingMore
        btn.setTitle(isLoadingMore ? "Loading..." : "Load More", for: .normal)
        tv.tableFooterView = btn
    }

    @objc private func loadMoreTapped() {
        guard let token = continuationToken, !isLoadingMore else { return }
        isLoadingMore = true
        updateLoadMoreFooter()
        YoutubeAPI.getChannelContinuation(token: token, channelName: channelName) { [weak self] vids, next in
            guard let self = self else { return }
            self.isLoadingMore = false
            self.continuationToken = next
            for v in vids where !self.seenIds.contains(v.id) {
                self.seenIds.insert(v.id)
                self.videos.append(v)
            }
            self.tableView?.reloadData()
            self.updateLoadMoreFooter()
        }
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
