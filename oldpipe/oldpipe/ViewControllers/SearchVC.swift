import UIKit

class SearchVC: UIViewController, UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate {

    // MARK: - State
    private var results: [Video] = []
    private var didSetupUI = false
    private var isLoading = false

    // lazy so creation is deferred to viewDidAppear — avoids work during push animation
    private lazy var searchBar: UISearchBar = {
        let sb = UISearchBar()
        sb.placeholder = "Search YouTube"
        sb.barStyle = .black
        sb.delegate = self
        // iOS 6: tintColor on UISearchBar is fine (it's a direct property, not UIAppearance)
        sb.tintColor = UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 1)
        return sb
    }()

    private lazy var tableView: UITableView = {
        let tv = UITableView()
        tv.backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
        tv.separatorColor = UIColor(white: 0.2, alpha: 1)
        tv.dataSource = self
        tv.delegate = self
        return tv
    }()

    private lazy var statusLabel: UILabel = {
        let l = UILabel()
        l.backgroundColor = .clear  // iOS 6: UILabel defaults to white bg
        l.textColor = UIColor(white: 0.5, alpha: 1)
        l.textAlignment = .center
        l.font = UIFont.systemFont(ofSize: 15)
        l.numberOfLines = 2
        l.text = "Search for YouTube videos"
        return l
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Search"
        view.backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didSetupUI else { return }
        didSetupUI = true
        setupUI()
    }

    private func setupUI() {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        let navH: CGFloat = 64 // nav bar + status bar

        searchBar.frame = CGRect(x: 0, y: 0, width: w, height: 44)
        view.addSubview(searchBar)

        tableView.register(VideoRowCell.self, forCellReuseIdentifier: VideoRowCell.reuseId)
        tableView.frame = CGRect(x: 0, y: 44, width: w, height: h - navH - 44)
        view.addSubview(tableView)

        statusLabel.frame = CGRect(x: 20, y: 44 + 60, width: w - 40, height: 60)
        view.addSubview(statusLabel)
    }

    // MARK: - UISearchBarDelegate

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        guard let query = searchBar.text, !query.isEmpty else { return }
        performSearch(query: query)
    }

    private func performSearch(query: String) {
        guard !isLoading else { return }
        isLoading = true
        results = []
        tableView.reloadData()
        statusLabel.text = "Searching..."
        statusLabel.isHidden = false

        YoutubeAPI.search(query: query) { [weak self] videos in
            guard let self = self else { return }
            self.isLoading = false
            self.results = videos
            self.tableView.reloadData()
            if videos.isEmpty {
                self.statusLabel.text = "No results found"
                self.statusLabel.isHidden = false
            } else {
                self.statusLabel.isHidden = true
            }
        }
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return results.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: VideoRowCell.reuseId, for: indexPath) as! VideoRowCell
        cell.configure(with: results[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return VideoRowCell.rowHeight
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let video = results[indexPath.row]
        let vc = VideoPlayerVC(video: video)
        navigationController?.pushViewController(vc, animated: true)
    }
}
