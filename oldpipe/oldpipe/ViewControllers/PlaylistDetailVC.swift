import UIKit

// MARK: - PlaylistDetailVC
// Shows the videos in one playlist (reusing VideoRowCell). "Rename" edits the name;
// Edit/swipe removes a video from the playlist. Tap → VideoPlayerVC. "Shuffle" (table
// header) plays it in random order. The playlist is re-read from the manager on every
// appear, so videos added elsewhere show up.

class PlaylistDetailVC: UIViewController, UITableViewDataSource, UITableViewDelegate, UIAlertViewDelegate {

    private let playlistId: String
    private var playlist: Playlist?
    private var videos: [Video] = []
    private var didSetupUI = false

    private var tableView: UITableView!
    private var statusLabel: UILabel!
    private var shuffleHeader: UIView!

    private let bg = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)

    init(playlistId: String) {
        self.playlistId = playlistId
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bg
        let rename = UIBarButtonItem(title: "Rename", style: .plain, target: self, action: #selector(renameTapped))
        navigationItem.rightBarButtonItems = [rename, editButtonItem]
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didSetupUI {
            didSetupUI = true
            setupUI()
        }
        reload()
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
        statusLabel.text = "This playlist is empty"
        tableView.addSubview(statusLabel)

        shuffleHeader = makeShuffleHeader(width: w)
    }

    // "Shuffle" sits in a table header, not the nav bar: that already carries Back, Rename
    // and Edit, and a third item truncates the title on a 320pt iPhone.
    private func makeShuffleHeader(width w: CGFloat) -> UIView {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: w, height: 56))
        header.backgroundColor = bg
        let btn = UIButton(type: .custom)
        btn.frame = CGRect(x: 12, y: 8, width: w - 24, height: 40)
        btn.autoresizingMask = iPadFlexWidth
        btn.layer.cornerRadius = 6   // no clipsToBounds: the layer's own background rounds
        btn.backgroundColor = UIColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1)
        btn.setTitle("Shuffle", for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.setTitleColor(UIColor(white: 0.5, alpha: 1), for: .highlighted)
        btn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
        btn.addTarget(self, action: #selector(shuffleTapped), for: .touchUpInside)
        header.addSubview(btn)
        return header
    }

    // The empty-state label sits at y=40 inside the table, under where the header would be,
    // so the header only exists while there is something to shuffle.
    private func updateShuffleHeader() {
        guard let tv = tableView else { return }
        let header: UIView? = videos.isEmpty ? nil : shuffleHeader
        if tv.tableHeaderView !== header { tv.tableHeaderView = header }
    }

    private func reload() {
        playlist = PlaylistManager.playlist(id: playlistId)
        videos = playlist?.videos ?? []
        title = playlist?.name ?? "Playlist"
        statusLabel?.isHidden = !videos.isEmpty
        updateShuffleHeader()
        tableView?.reloadData()
    }

    @objc private func shuffleTapped() {
        navigationController?.openShuffled(videos)
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView?.setEditing(editing, animated: animated)
    }

    // MARK: - Rename

    @objc private func renameTapped() {
        let alert = UIAlertView()
        alert.delegate = self
        alert.title = "Rename Playlist"
        alert.message = ""
        alert.alertViewStyle = .plainTextInput
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Save")
        alert.cancelButtonIndex = 0
        alert.textField(at: 0)?.text = playlist?.name
        alert.show()
    }

    func alertView(_ alertView: UIAlertView, clickedButtonAt buttonIndex: Int) {
        guard buttonIndex == 1 else { return }   // 0 = Cancel, 1 = Save
        let name = (alertView.textField(at: 0)?.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        PlaylistManager.rename(id: playlistId, to: name)
        reload()
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

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        let video = videos[indexPath.row]
        PlaylistManager.remove(videoId: video.id, from: playlistId)
        videos.remove(at: indexPath.row)
        tableView.deleteRows(at: [indexPath], with: .automatic)
        statusLabel?.isHidden = !videos.isEmpty
        updateShuffleHeader()
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
