import UIKit

// MARK: - DownloadsVC
// Lists locally downloaded videos. Tap to replay offline; swipe or Edit to delete. A Save to
// Photos started from the video page shows its progress in the row's status line.

class DownloadsVC: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private var videos: [Video] = []
    private var sizeText: [String: String] = [:]   // precomputed per CLAUDE.md (no per-cell file I/O)
    private var qualityText: [String: String] = [:]  // ditto — a UserDefaults scan per cell would be worse
    private var incomplete: Set<String> = []       // ids of partial (unfinished) downloads
    private var playedFrac: [String: CGFloat] = [:] // resume-position / duration, for the progress bar
    private var didSetupUI = false
    private var pollTimer: Timer?   // refreshes rows while a download is in flight
    private var shownState = RowState()   // what the rows were built from (see RowState)

    // What the rows depend on besides the moving percentages: which downloads are in flight
    // and whether each has anything on disk yet (an HLS one is only listed once its playlist is
    // written), and which listed videos are exporting. A download that finishes straight into
    // its Save to Photos changes both halves at once.
    private struct RowState: Equatable {
        var downloads: [String: Bool] = [:]   // in-flight id → has files on disk
        var exports: Set<String> = []
    }

    private lazy var tableView: UITableView = {
        let tv = UITableView()
        tv.backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
        tv.separatorColor = UIColor(white: 0.2, alpha: 1)
        tv.dataSource = self
        tv.delegate = self
        return tv
    }()

    private lazy var emptyLabel: UILabel = {
        let l = UILabel()
        l.backgroundColor = .clear
        l.textColor = UIColor(white: 0.5, alpha: 1)
        l.textAlignment = .center
        l.font = UIFont.systemFont(ofSize: 15)
        l.numberOfLines = 2
        l.text = "No downloads yet"
        return l
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Downloads"
        view.backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
        navigationItem.rightBarButtonItem = editButtonItem
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didSetupUI {
            didSetupUI = true
            setupUI()
        }
        reload()
        startPollTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // Polls on .common, so it also fires while scrolling, to keep a running download's or Save
    // to Photos' % live (not while editing). The rows themselves only change with RowState —
    // a download starting, getting files, finishing; an export starting or ending — so that is
    // when it reloads. In between, only the running rows' status line is rewritten: a full
    // reload twice a second read every store and walked every bundle's segments to size it.
    private func startPollTimer() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 0.5, target: DownloadsPollProxy { [weak self] in
            guard let self = self, !self.tableView.isEditing else { return }
            if self.currentRowState() != self.shownState {
                self.reload()
            } else {
                self.refreshRunningRows()
            }
        }, selector: #selector(DownloadsPollProxy.fire), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func currentRowState() -> RowState {
        var s = RowState()
        for id in DownloadManager.downloadingIds() { s.downloads[id] = DownloadManager.fileExists(id) }
        for v in videos where PhotoExporter.shared.isBusy(v.id) { s.exports.insert(v.id) }
        return s
    }

    // Rewrites, in place, the status line of the visible rows with a download or export running.
    private func refreshRunningRows() {
        for path in tableView.indexPathsForVisibleRows ?? [] where path.row < videos.count {
            let video = videos[path.row]
            guard DownloadManager.isDownloading(video.id) || PhotoExporter.shared.isBusy(video.id),
                  let cell = tableView.cellForRow(at: path) else { continue }
            applyStatus(to: cell, for: video)
            cell.setNeedsLayout()   // the stock cell sizes its labels to their text in layout
        }
    }

    private func setupUI() {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        let navH: CGFloat = 64
        tableView.frame = CGRect(x: 0, y: 0, width: w, height: h - navH)
        // iPad rotates natively; these masks reflow the layout in landscape. iPhone is
        // portrait-locked in the pbxproj so autoresizing never triggers there.
        tableView.autoresizingMask = iPadFlexWidthHeight
        view.addSubview(tableView)
        emptyLabel.frame = CGRect(x: 20, y: 80, width: w - 40, height: 60)
        emptyLabel.autoresizingMask = iPadFlexWidth
        view.addSubview(emptyLabel)
    }

    private func reload() {
        let snap = DownloadManager.snapshot()   // one read of each store for the whole list
        videos = snap.videos
        sizeText.removeAll()
        qualityText.removeAll()
        incomplete = snap.incomplete
        playedFrac.removeAll()
        for v in videos {
            sizeText[v.id] = DownloadManager.fileSizeText(for: v.id)
            qualityText[v.id] = snap.quality[v.id] ?? ""
            if snap.watched.contains(v.id) {
                playedFrac[v.id] = 1   // fully played → full bar (resume position is cleared)
            } else {
                let dur = DownloadsVC.durationSeconds(v.durationText)
                if dur > 0 {
                    let f = CGFloat((snap.positions[v.id] ?? 0) / dur)
                    playedFrac[v.id] = max(0, min(1, f))
                }
            }
        }
        shownState = currentRowState()
        emptyLabel.isHidden = !videos.isEmpty
        tableView.reloadData()
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView.setEditing(editing, animated: animated)
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return videos.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let id = "DownloadCell"
        let cell = (tableView.dequeueReusableCell(withIdentifier: id) as? DownloadCell)
            ?? DownloadCell(style: .subtitle, reuseIdentifier: id)
        let video = videos[indexPath.row]

        cell.backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
        cell.textLabel?.backgroundColor = .clear
        cell.detailTextLabel?.backgroundColor = .clear
        cell.textLabel?.textColor = UIColor(white: 0.95, alpha: 1)
        cell.textLabel?.numberOfLines = 2
        cell.textLabel?.font = UIFont.systemFont(ofSize: 14)
        cell.detailTextLabel?.font = UIFont.systemFont(ofSize: 12)

        cell.textLabel?.text = video.title
        applyStatus(to: cell, for: video)

        cell.imageView?.image = DownloadsVC.placeholder
        cell.imageView?.layer.cornerRadius = 4
        cell.imageView?.clipsToBounds = true
        cell.playedFraction = playedFrac[video.id] ?? 0
        AsyncImageView.cancel(cell.thumbTicket)
        cell.thumbTicket = AsyncImageView.loadCell(url: video.thumbnailURL) { [weak cell] img in
            guard let cell = cell else { return }
            cell.thumbTicket = nil
            cell.imageView?.image = img
            cell.setNeedsLayout()
        }

        let selView = UIView()
        selView.backgroundColor = UIColor(white: 0.15, alpha: 1)
        cell.selectedBackgroundView = selView
        return cell
    }

    // The channel + status line under the title, and its colour. Also what the poll rewrites
    // on the rows still running.
    private func applyStatus(to cell: UITableViewCell, for video: Video) {
        let isDownloading = DownloadManager.isDownloading(video.id)
        let isPartial = incomplete.contains(video.id)
        let isExporting = PhotoExporter.shared.isBusy(video.id)
        let exportText = PhotoExporter.shared.statusText(video.id)
        let sz = sizeText[video.id] ?? ""
        let status: String
        if isDownloading {
            status = "Downloading \(Int(DownloadManager.progress(for: video.id) * 100))%"
        } else if isPartial {
            status = "Incomplete" + (sz.isEmpty ? "" : " (\(sz))")
        } else if let t = exportText {
            status = t   // "Saving 34%" while exporting, "Saved to Photos ✓" after
        } else {
            // "720p • 48.2 MB" — the quality an entry was saved at is otherwise invisible now
            // that a download is no longer always 360p.
            let q = qualityText[video.id] ?? ""
            status = [q, sz].filter { !$0.isEmpty }.joined(separator: " \u{2022} ")
        }
        if isDownloading || isPartial || isExporting {
            cell.detailTextLabel?.textColor = UIColor(red: 0.95, green: 0.6, blue: 0.2, alpha: 1)  // amber
        } else if exportText != nil {
            cell.detailTextLabel?.textColor = UIColor(red: 0.45, green: 0.8, blue: 0.45, alpha: 1)  // saved
        } else {
            cell.detailTextLabel?.textColor = UIColor(white: 0.55, alpha: 1)
        }
        cell.detailTextLabel?.text = [video.channelName, status]
            .filter { !$0.isEmpty }.joined(separator: " • ")
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 72
    }

    // MARK: - Delete

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        let video = videos[indexPath.row]
        DownloadManager.remove(video.id)
        videos.remove(at: indexPath.row)
        sizeText[video.id] = nil
        tableView.deleteRows(at: [indexPath], with: .automatic)
        emptyLabel.isHidden = !videos.isEmpty
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.openVideo(videos[indexPath.row])
    }

    // MARK: - Helpers

    // Drawn once and shared by every row, not once per cellForRow.
    private static let placeholder: UIImage? = {
        let size = CGSize(width: 80, height: 45)
        UIGraphicsBeginImageContextWithOptions(size, false, UIScreen.main.scale)
        UIColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1).setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let img = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return img
    }()

    // Parse "8:00" / "1:02:03" → seconds. Returns 0 if unparseable.
    private static func durationSeconds(_ text: String) -> Double {
        let parts = text.split(separator: ":")
        guard !parts.isEmpty else { return 0 }
        var total = 0
        for p in parts { total = total * 60 + (Int(p) ?? 0) }
        return Double(total)
    }
}

// MARK: - DownloadCell
// Stock subtitle cell with a thin "watched progress" bar pinned to the bottom edge of the
// thumbnail (red fill over a dark track). Positioned in layoutSubviews from imageView.bounds
// so it tracks the thumb's frame after the async image loads.

private class DownloadCell: UITableViewCell {

    var playedFraction: CGFloat = 0 { didSet { setNeedsLayout() } }

    // This cell draws into the built-in UITableViewCell.imageView (not an AsyncImageView),
    // so it holds the request ticket itself and withdraws it on reuse — otherwise a fast
    // scroll leaves every passed-over thumbnail still queued on the curl gate.
    var thumbTicket: AsyncImageView.ImageRequestTicket?

    private let progressTrack = UIView()
    private let progressFill = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        progressTrack.backgroundColor = UIColor(white: 0, alpha: 0.5)
        progressTrack.isHidden = true
        progressFill.backgroundColor = UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 1)
        progressTrack.addSubview(progressFill)
        imageView?.addSubview(progressTrack)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        AsyncImageView.cancel(thumbTicket)
        thumbTicket = nil
    }

    deinit { AsyncImageView.cancel(thumbTicket) }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let iv = imageView else { return }
        let b = iv.bounds
        guard playedFraction > 0.01, b.width > 0, b.height > 0 else {
            progressTrack.isHidden = true
            return
        }
        let barH: CGFloat = 3
        progressTrack.isHidden = false
        progressTrack.frame = CGRect(x: 0, y: b.height - barH, width: b.width, height: barH)
        progressFill.frame = CGRect(x: 0, y: 0, width: b.width * min(1, playedFraction), height: barH)
        iv.bringSubviewToFront(progressTrack)
    }
}

// MARK: - Timer helper (avoids retain cycles with the poll timer on iOS 6)

private class DownloadsPollProxy: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}
