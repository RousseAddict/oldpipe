import UIKit

// MARK: - YTPlaylistVC
// The videos in a YouTube playlist (reached from a channel's Playlists tab). Same shape as
// PlaylistDetailVC, but sourced from the innertube API instead of PlaylistManager, with a
// "Load More" footer while a continuation token exists. Tapping a row seeds the singleton
// autoplay queue, so playback advances through the playlist. "Save" copies what is currently
// loaded into a new local playlist.

class YTPlaylistVC: UIViewController, UITableViewDataSource, UITableViewDelegate {

    let playlistId: String   // read by Navigator to find this page in the stack
    private let playlistTitle: String

    private var videos: [Video] = []
    private var seen = Set<String>()
    private var token: String?
    private var loadingMore = false
    private var loadMoreBtn: UIButton?
    private var didLoad = false
    private var didSetupUI = false

    private var tableView: UITableView!
    private var statusLabel: UILabel!
    private var saveItem: UIBarButtonItem!

    private let bg = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)

    init(playlistId: String, title: String) {
        self.playlistId = playlistId
        self.playlistTitle = title
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = playlistTitle.isEmpty ? "Playlist" : playlistTitle
        view.backgroundColor = bg
        saveItem = UIBarButtonItem(title: "Save", style: .plain, target: self, action: #selector(saveTapped))
        navigationItem.rightBarButtonItem = saveItem
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didSetupUI {
            didSetupUI = true
            setupUI()
        }
        load()
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
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 60, right: 0)
        tableView.tableFooterView = UIView()
        tableView.registerCell(VideoRowCell.self, VideoRowCell.reuseId)
        // iPad rotates natively; these masks reflow the layout in landscape. iPhone is
        // portrait-locked in the pbxproj so autoresizing never triggers there.
        tableView.autoresizingMask = iPadFlexWidthHeight
        view.addSubview(tableView)

        statusLabel = UILabel(frame: CGRect(x: 20, y: 40, width: w - 40, height: 40))
        statusLabel.autoresizingMask = iPadFlexWidth
        statusLabel.backgroundColor = .clear
        statusLabel.textColor = UIColor(white: 0.5, alpha: 1)
        statusLabel.textAlignment = .center
        statusLabel.font = UIFont.systemFont(ofSize: 15)
        statusLabel.text = "Loading..."
        tableView.addSubview(statusLabel)
    }

    // MARK: - Loading

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        YoutubeAPI.getPlaylistVideos(playlistId: playlistId, priority: true) { [weak self] vids, next in
            guard let self = self else { return }
            self.videos = vids
            self.seen = Set(vids.map { $0.id })
            self.token = next
            self.statusLabel?.isHidden = !vids.isEmpty
            if vids.isEmpty { self.statusLabel?.text = "No videos in this playlist" }
            self.tableView?.reloadData()
            self.updateLoadMoreFooter()
        }
    }

    private func updateLoadMoreFooter() {
        guard let tv = tableView else { return }
        guard token != nil, !videos.isEmpty else {
            tv.tableFooterView = UIView()   // also hides empty separator rows
            return
        }
        let btn: UIButton
        if let e = loadMoreBtn {
            btn = e
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
        btn.isEnabled = !loadingMore
        btn.setTitle(loadingMore ? "Loading..." : "Load More", for: .normal)
        tv.tableFooterView = btn
    }

    // Playlist continuations land under onResponseReceivedActions in the same shape as a
    // channel's, so the generic continuation call handles them unchanged.
    @objc private func loadMoreTapped() {
        guard let t = token, !loadingMore else { return }
        loadingMore = true
        updateLoadMoreFooter()
        YoutubeAPI.getChannelContinuation(token: t, channelName: "", priority: true) { [weak self] vids, next in
            guard let self = self else { return }
            self.loadingMore = false
            self.token = next
            for v in vids where !self.seen.contains(v.id) {
                self.seen.insert(v.id)
                self.videos.append(v)
            }
            self.tableView?.reloadData()
            self.updateLoadMoreFooter()
        }
    }

    // MARK: - Save

    // Copies the videos loaded SO FAR into a new local playlist — hence the confirmation
    // text naming the count rather than claiming the whole playlist was saved.
    @objc private func saveTapped() {
        guard !videos.isEmpty else { return }
        let name = playlistTitle.isEmpty ? "Playlist" : playlistTitle
        let created = PlaylistManager.create(name: name)
        for v in videos {
            PlaylistManager.add(video: v, to: created.id)
        }
        saveItem.title = "Saved \(videos.count) \u{2713}"
        let t = Timer(timeInterval: 1.5, target: YTPlaylistBlockTarget { [weak self] in
            self?.saveItem.title = "Save"
        }, selector: #selector(YTPlaylistBlockTarget.fire), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return videos.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueCell(VideoRowCell.self, VideoRowCell.reuseId, for: indexPath)
        cell.configure(with: videos[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return VideoRowCell.rowHeight
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        // Seed the singleton autoplay queue so playback advances through the playlist
        // (stopping at the end) even after this VC / the player VC is popped.
        VideoPlayer.shared.setQueue(videos, startIndex: indexPath.row)
        navigationController?.openVideo(videos[indexPath.row])
    }
}

// Timer needs an ObjC target; this wraps a closure (same pattern as SettingsBlockTarget).
private class YTPlaylistBlockTarget: NSObject {
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}
