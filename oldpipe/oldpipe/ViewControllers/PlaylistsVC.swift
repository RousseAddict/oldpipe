import UIKit

// MARK: - PlaylistsVC
// Lists local playlists. "+" creates one (name via UIAlertView text input — UIAlertController
// is iOS 8+ and crashes on iOS 6). Edit/swipe-delete removes a playlist. Tap → detail.

class PlaylistsVC: UIViewController, UITableViewDataSource, UITableViewDelegate, UIAlertViewDelegate {

    private var playlists: [Playlist] = []
    private var didSetupUI = false

    private var tableView: UITableView!
    private var statusLabel: UILabel!

    private let bg = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Playlists"
        view.backgroundColor = bg
        let add = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(createTapped))
        navigationItem.rightBarButtonItems = [add, editButtonItem]
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
        tableView.tableFooterView = UIView()   // hide separators on empty rows (iOS 6)
        view.addSubview(tableView)

        statusLabel = UILabel(frame: CGRect(x: 20, y: 40, width: w - 40, height: 60))
        statusLabel.backgroundColor = .clear
        statusLabel.textColor = UIColor(white: 0.5, alpha: 1)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.font = UIFont.systemFont(ofSize: 15)
        statusLabel.text = "No playlists yet.\nTap + to create one."
        tableView.addSubview(statusLabel)
    }

    private func reload() {
        playlists = PlaylistManager.all()
        statusLabel?.isHidden = !playlists.isEmpty
        tableView?.reloadData()
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView?.setEditing(editing, animated: animated)
    }

    // MARK: - Create

    @objc private func createTapped() {
        let alert = UIAlertView()
        alert.delegate = self
        alert.title = "New Playlist"
        alert.message = "Enter a name"
        alert.alertViewStyle = .plainTextInput
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Create")
        alert.cancelButtonIndex = 0
        alert.show()
    }

    func alertView(_ alertView: UIAlertView, clickedButtonAt buttonIndex: Int) {
        guard buttonIndex == 1 else { return }   // 0 = Cancel, 1 = Create
        let name = (alertView.textField(at: 0)?.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        PlaylistManager.create(name: name)
        reload()
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return playlists.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let id = "PlaylistCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: id)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: id)
        let pl = playlists[indexPath.row]

        cell.backgroundColor = bg
        cell.textLabel?.backgroundColor = .clear
        cell.detailTextLabel?.backgroundColor = .clear
        cell.textLabel?.textColor = UIColor(white: 0.95, alpha: 1)
        cell.textLabel?.font = UIFont.systemFont(ofSize: 16)
        cell.textLabel?.text = pl.name
        cell.detailTextLabel?.textColor = UIColor(white: 0.55, alpha: 1)
        cell.detailTextLabel?.font = UIFont.systemFont(ofSize: 12)
        let count = pl.videos.count
        cell.detailTextLabel?.text = count == 1 ? "1 video" : "\(count) videos"
        cell.accessoryType = .disclosureIndicator

        let sel = UIView()
        sel.backgroundColor = UIColor(white: 0.15, alpha: 1)
        cell.selectedBackgroundView = sel
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 56
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        let pl = playlists[indexPath.row]
        PlaylistManager.delete(id: pl.id)
        playlists.remove(at: indexPath.row)
        tableView.deleteRows(at: [indexPath], with: .automatic)
        statusLabel?.isHidden = !playlists.isEmpty
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let pl = playlists[indexPath.row]
        navigationController?.pushViewController(PlaylistDetailVC(playlistId: pl.id), animated: true)
    }
}
