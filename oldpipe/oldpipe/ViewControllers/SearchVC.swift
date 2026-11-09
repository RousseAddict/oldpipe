import UIKit

class SearchVC: UIViewController, UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate {

    // MARK: - State
    private var results: [Video] = []
    private var didSetupUI = false
    private var isLoading = false
    private var pendingQuery: String?   // see search(for:)

    // Set by Navigator's Search button. An empty page brings the keyboard up; one still
    // holding results is shown as it was, keyboard down, since iOS 6 has no way to put the
    // keyboard away by scrolling the results.
    var focusOnAppear = false

    private static let idleTitle = "Search YouTube"
    private static let idleBody = "Find videos by title, topic or channel."

    // lazy so creation is deferred to viewDidAppear — avoids work during push animation
    private lazy var searchBar: UISearchBar = {
        let sb = UISearchBar()
        sb.placeholder = "Search YouTube"
        sb.barStyle = .black
        sb.delegate = self
        // iOS 6: tintColor on UISearchBar is fine (it's a direct property, not UIAppearance)
        sb.tintColor = Theme.accent
        return sb
    }()

    private lazy var tableView: UITableView = {
        let tv = UITableView()
        tv.backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
        tv.separatorColor = UIColor(white: 0.2, alpha: 1)
        tv.dataSource = self
        tv.delegate = self
        tv.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 60, right: 0)   // mini player bar
        tv.tableFooterView = UIView()   // no empty separator rows under a short or empty list
        return tv
    }()

    // The prompt before the first search, and "No results" after an empty one. Compact, so it
    // stays clear of the keyboard the field usually has up.
    private lazy var emptyView = EmptyStateView(mark: .search, title: SearchVC.idleTitle,
                                                body: SearchVC.idleBody, compact: true)

    // A search in flight: a spinner over a "Searching…" line, where the prompt was.
    private lazy var spinner: UIActivityIndicatorView = {
        let s = UIActivityIndicatorView(style: .white)
        s.hidesWhenStopped = true
        return s
    }()

    private lazy var statusLabel: UILabel = {
        let l = UILabel()
        l.backgroundColor = .clear  // iOS 6: UILabel defaults to white bg
        l.textColor = UIColor(white: 0.5, alpha: 1)
        l.textAlignment = .center
        l.font = UIFont.systemFont(ofSize: 15)
        l.text = "Searching\u{2026}"
        l.isHidden = true
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
        if !didSetupUI {
            didSetupUI = true
            setupUI()
        }
        if let q = pendingQuery {
            pendingQuery = nil
            search(for: q)
        }
        if focusOnAppear {
            focusOnAppear = false
            if results.isEmpty && !isLoading { searchBar.becomeFirstResponder() }
        }
    }

    private func setupUI() {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        let navH: CGFloat = 64 // nav bar + status bar

        searchBar.frame = CGRect(x: 0, y: 0, width: w, height: 44)
        searchBar.autoresizingMask = iPadFlexWidth
        view.addSubview(searchBar)

        tableView.registerCell(VideoRowCell.self, VideoRowCell.reuseId)
        tableView.frame = CGRect(x: 0, y: 44, width: w, height: h - navH - 44)
        // iPad rotates natively; these masks reflow the layout in landscape. iPhone is
        // portrait-locked in the pbxproj so autoresizing never triggers there.
        tableView.autoresizingMask = iPadFlexWidthHeight
        view.addSubview(tableView)

        emptyView.frame = CGRect(x: 0, y: 0, width: w, height: tableView.bounds.height)
        tableView.addSubview(emptyView)

        spinner.center = CGPoint(x: floor(w / 2), y: 44 + 48)
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin]   // centred on a rotated iPad
        view.addSubview(spinner)

        statusLabel.frame = CGRect(x: 20, y: 44 + 70, width: w - 40, height: 20)
        statusLabel.autoresizingMask = iPadFlexWidth
        view.addSubview(statusLabel)
    }

    // Runs `query` as if typed and submitted: at once when the page is on screen, otherwise as
    // soon as it appears (the iOS 5 build's oldpipe://search hook).
    func search(for query: String) {
        guard didSetupUI, view.window != nil else {
            pendingQuery = query
            return
        }
        searchBar.text = query
        searchBar.resignFirstResponder()
        performSearch(query: query)
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
        tableView.setContentOffset(CGPoint(x: 0, y: 0), animated: false)   // new results start at the top
        emptyView.isHidden = true
        spinner.startAnimating()
        statusLabel.isHidden = false

        YoutubeAPI.search(query: query) { [weak self] videos in
            guard let self = self else { return }
            self.isLoading = false
            self.spinner.stopAnimating()
            self.statusLabel.isHidden = true
            self.results = videos
            self.tableView.reloadData()
            if videos.isEmpty {
                // A failed request comes back empty too, so this can't promise there is nothing.
                self.emptyView.setText(title: "No results",
                                       body: "Nothing came back. Check your connection or try other words.")
                self.emptyView.isHidden = false
            }
        }
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return results.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueCell(VideoRowCell.self, VideoRowCell.reuseId, for: indexPath)
        cell.configure(with: results[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return VideoRowCell.rowHeight
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.openVideo(results[indexPath.row])
    }
}
