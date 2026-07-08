import UIKit

// MARK: - HistoryVC
// Shows the last watched videos (newest first, capped at HistoryManager.maxCount).
// Swipe/Edit removes a single entry; the "Clear" bar button wipes all (with a confirm
// alert — UIAlertView, since UIAlertController is iOS 8+ and crashes on iOS 6). Tap a row
// to replay it in VideoPlayerVC. Reached from the HomeVC side menu (between Downloads and
// Settings).

class HistoryVC: UIViewController, UITableViewDataSource, UITableViewDelegate, UIAlertViewDelegate {

    private var videos: [Video] = []
    private var playedFrac: [String: CGFloat] = [:]   // resume-position / duration, for the progress bar
    private var didSetupUI = false

    private var tableView: UITableView!
    private var statusLabel: UILabel!

    private let bg = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "History"
        view.backgroundColor = bg
        let clear = UIBarButtonItem(title: "Clear", style: .plain, target: self, action: #selector(clearTapped))
        navigationItem.rightBarButtonItems = [editButtonItem, clear]
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
        tableView.register(VideoRowCell.self, forCellReuseIdentifier: VideoRowCell.reuseId)
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 60, right: 0)
        tableView.tableFooterView = UIView()   // hide separators on empty rows (iOS 6)
        // iPad rotates natively; these masks reflow the layout in landscape. iPhone is
        // portrait-locked in the pbxproj so autoresizing never triggers there.
        tableView.autoresizingMask = iPadFlexWidthHeight
        view.addSubview(tableView)

        statusLabel = UILabel(frame: CGRect(x: 20, y: 40, width: w - 40, height: 60))
        statusLabel.autoresizingMask = iPadFlexWidth
        statusLabel.backgroundColor = .clear
        statusLabel.textColor = UIColor(white: 0.5, alpha: 1)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.font = UIFont.systemFont(ofSize: 15)
        statusLabel.text = "No history yet.\nVideos you play will appear here."
        tableView.addSubview(statusLabel)
    }

    private func reload() {
        videos = HistoryManager.all()
        playedFrac.removeAll()
        for v in videos {
            if DownloadManager.isWatched(v.id) {
                playedFrac[v.id] = 1   // fully played → full bar (resume position is cleared)
            } else {
                let dur = HistoryVC.durationSeconds(v.durationText)
                if dur > 0 {
                    let f = CGFloat(DownloadManager.position(for: v.id) / dur)
                    playedFrac[v.id] = max(0, min(1, f))
                }
            }
        }
        statusLabel?.isHidden = !videos.isEmpty
        tableView?.reloadData()
    }

    // Parse "8:00" / "1:02:03" → seconds. Returns 0 if unparseable.
    private static func durationSeconds(_ text: String) -> Double {
        let parts = text.split(separator: ":")
        guard !parts.isEmpty else { return 0 }
        var total = 0
        for p in parts { total = total * 60 + (Int(p) ?? 0) }
        return Double(total)
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView?.setEditing(editing, animated: animated)
    }

    // MARK: - Clear all

    @objc private func clearTapped() {
        guard !videos.isEmpty else { return }
        let alert = UIAlertView()
        alert.delegate = self
        alert.title = "Clear History"
        alert.message = "Remove all watched videos from your history?"
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear")
        alert.cancelButtonIndex = 0
        alert.show()
    }

    func alertView(_ alertView: UIAlertView, clickedButtonAt buttonIndex: Int) {
        guard buttonIndex == 1 else { return }   // 0 = Cancel, 1 = Clear
        HistoryManager.clear()
        reload()
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return videos.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: VideoRowCell.reuseId, for: indexPath) as! VideoRowCell
        let video = videos[indexPath.row]
        cell.configure(with: video)
        cell.playedFraction = playedFrac[video.id] ?? 0
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
        HistoryManager.remove(id: videos[indexPath.row].id)
        videos.remove(at: indexPath.row)
        tableView.deleteRows(at: [indexPath], with: .automatic)
        statusLabel?.isHidden = !videos.isEmpty
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let vc = VideoPlayerVC(video: videos[indexPath.row])
        navigationController?.pushViewController(vc, animated: true)
    }
}
