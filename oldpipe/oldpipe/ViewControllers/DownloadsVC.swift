import UIKit

// MARK: - DownloadsVC
// Lists locally downloaded videos. Tap to replay offline; swipe or Edit to delete.

class DownloadsVC: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private var videos: [Video] = []
    private var sizeText: [String: String] = [:]   // precomputed per CLAUDE.md (no per-cell file I/O)
    private var incomplete: Set<String> = []       // ids of partial (unfinished) downloads
    private var didSetupUI = false

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
    }

    private func setupUI() {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        let navH: CGFloat = 64
        tableView.frame = CGRect(x: 0, y: 0, width: w, height: h - navH)
        view.addSubview(tableView)
        emptyLabel.frame = CGRect(x: 20, y: 80, width: w - 40, height: 60)
        view.addSubview(emptyLabel)
    }

    private func reload() {
        videos = DownloadManager.all()
        sizeText.removeAll()
        incomplete.removeAll()
        for v in videos {
            sizeText[v.id] = DownloadManager.fileSizeText(for: v.id)
            if !DownloadManager.isComplete(v.id) { incomplete.insert(v.id) }
        }
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
        let cell = tableView.dequeueReusableCell(withIdentifier: id) ?? UITableViewCell(style: .subtitle, reuseIdentifier: id)
        let video = videos[indexPath.row]

        cell.backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
        cell.textLabel?.backgroundColor = .clear
        cell.detailTextLabel?.backgroundColor = .clear
        cell.textLabel?.textColor = UIColor(white: 0.95, alpha: 1)
        cell.textLabel?.numberOfLines = 2
        cell.textLabel?.font = UIFont.systemFont(ofSize: 14)
        cell.detailTextLabel?.font = UIFont.systemFont(ofSize: 12)

        cell.textLabel?.text = video.title
        let isPartial = incomplete.contains(video.id)
        let sz = sizeText[video.id] ?? ""
        let status = isPartial ? ("Incomplete" + (sz.isEmpty ? "" : " (\(sz))")) : sz
        cell.detailTextLabel?.textColor = isPartial
            ? UIColor(red: 0.95, green: 0.6, blue: 0.2, alpha: 1)   // amber for partial
            : UIColor(white: 0.55, alpha: 1)
        cell.detailTextLabel?.text = [video.channelName, status]
            .filter { !$0.isEmpty }.joined(separator: " • ")

        cell.imageView?.image = placeholderImage()
        cell.imageView?.layer.cornerRadius = 4
        cell.imageView?.clipsToBounds = true
        AsyncImageView.loadCell(url: video.thumbnailURL) { [weak cell] img in
            guard let cell = cell else { return }
            cell.imageView?.image = img
            cell.setNeedsLayout()
        }

        let selView = UIView()
        selView.backgroundColor = UIColor(white: 0.15, alpha: 1)
        cell.selectedBackgroundView = selView
        return cell
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
        let video = videos[indexPath.row]
        let vc = VideoPlayerVC(video: video)
        navigationController?.pushViewController(vc, animated: true)
    }

    // MARK: - Helpers

    private func placeholderImage() -> UIImage? {
        let size = CGSize(width: 80, height: 45)
        UIGraphicsBeginImageContextWithOptions(size, false, UIScreen.main.scale)
        UIColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1).setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let img = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return img
    }
}
