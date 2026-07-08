import UIKit

// MARK: - ManageSubscriptionsVC
// Lists subscribed channels. Swipe-to-delete (or Edit) unsubscribes.
// Tapping a row opens the ChannelVC.

class ManageSubscriptionsVC: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private var channels: [Channel] = []
    private var didSetupUI = false

    private var tableView: UITableView!
    private var statusLabel: UILabel!

    private let bg = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Subscriptions"
        view.backgroundColor = bg
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

        tableView = UITableView(frame: CGRect(x: 0, y: 0, width: w, height: h - navH))
        tableView.backgroundColor = bg
        tableView.separatorColor = UIColor(white: 0.2, alpha: 1)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(ChannelCell.self, forCellReuseIdentifier: ChannelCell.reuseId)
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 60, right: 0)
        // iPad rotates natively; these masks reflow the layout in landscape. iPhone is
        // portrait-locked in the pbxproj so autoresizing never triggers there.
        tableView.autoresizingMask = iPadFlexWidthHeight
        view.addSubview(tableView)

        statusLabel = UILabel(frame: CGRect(x: 20, y: 40, width: w - 40, height: 60))
        statusLabel.autoresizingMask = iPadFlexWidth
        statusLabel.backgroundColor = .clear
        statusLabel.textColor = UIColor(white: 0.5, alpha: 1)
        statusLabel.textAlignment = .center
        statusLabel.font = UIFont.systemFont(ofSize: 15)
        statusLabel.text = "No subscriptions yet"
        tableView.addSubview(statusLabel)
    }

    private func reload() {
        channels = SubscriptionManager.all()
        statusLabel?.isHidden = !channels.isEmpty
        tableView?.reloadData()
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView?.setEditing(editing, animated: animated)
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return channels.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ChannelCell.reuseId, for: indexPath) as! ChannelCell
        cell.configure(with: channels[indexPath.row])
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
        let channel = channels[indexPath.row]
        SubscriptionManager.unsubscribe(channel.id)
        channels.remove(at: indexPath.row)
        tableView.deleteRows(at: [indexPath], with: .automatic)
        statusLabel?.isHidden = !channels.isEmpty
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let channel = channels[indexPath.row]
        let vc = ChannelVC(channelId: channel.id, name: channel.name)
        navigationController?.pushViewController(vc, animated: true)
    }
}

// MARK: - ChannelCell
// Circular avatar (AsyncImageView, with its own loadingURL reuse guard) + channel name.
// Using a dedicated AsyncImageView — not the cell's built-in imageView + the unguarded static
// loadCell — is what keeps the right avatar on the right row while scrolling/reusing.

private class ChannelCell: UITableViewCell {

    static let reuseId = "ChannelCell"

    private let avatar = AsyncImageView()
    private let nameLbl = UILabel()
    private let bg = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = bg
        accessoryType = .disclosureIndicator

        avatar.frame = CGRect(x: 12, y: 8, width: 40, height: 40)
        avatar.backgroundColor = UIColor(white: 0.15, alpha: 1)
        avatar.layer.cornerRadius = 20
        avatar.clipsToBounds = true
        avatar.contentMode = .scaleAspectFill
        contentView.addSubview(avatar)

        nameLbl.backgroundColor = .clear
        nameLbl.textColor = UIColor(white: 0.95, alpha: 1)
        nameLbl.font = UIFont.systemFont(ofSize: 15)
        contentView.addSubview(nameLbl)

        let sel = UIView()
        sel.backgroundColor = UIColor(white: 0.15, alpha: 1)
        selectedBackgroundView = sel
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with channel: Channel) {
        nameLbl.text = channel.name.isEmpty ? channel.id : channel.name
        if channel.thumbnailURL.isEmpty {
            avatar.cancel()
            avatar.image = nil
        } else {
            avatar.load(url: channel.thumbnailURL)   // load(url:) guards stale completions
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        nameLbl.frame = CGRect(x: 64, y: 0, width: contentView.bounds.width - 64 - 16,
                               height: contentView.bounds.height)
    }
}
