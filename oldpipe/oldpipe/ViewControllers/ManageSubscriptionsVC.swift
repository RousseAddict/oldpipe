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
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 60, right: 0)
        view.addSubview(tableView)

        statusLabel = UILabel(frame: CGRect(x: 20, y: 40, width: w - 40, height: 60))
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
        let id = "ChannelCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: id) ?? UITableViewCell(style: .default, reuseIdentifier: id)
        let channel = channels[indexPath.row]

        cell.backgroundColor = bg
        cell.textLabel?.backgroundColor = .clear
        cell.textLabel?.textColor = UIColor(white: 0.95, alpha: 1)
        cell.textLabel?.font = UIFont.systemFont(ofSize: 15)
        cell.textLabel?.text = channel.name.isEmpty ? channel.id : channel.name
        cell.accessoryType = .disclosureIndicator

        if cell.imageView?.image == nil {
            cell.imageView?.image = placeholderImage()
            cell.imageView?.layer.cornerRadius = 20
            cell.imageView?.clipsToBounds = true
        }
        if !channel.thumbnailURL.isEmpty {
            AsyncImageView.loadCell(url: channel.thumbnailURL) { [weak cell] img in
                guard let cell = cell else { return }
                cell.imageView?.image = img
                cell.setNeedsLayout()
            }
        }

        let selView = UIView()
        selView.backgroundColor = UIColor(white: 0.15, alpha: 1)
        cell.selectedBackgroundView = selView
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

    private func placeholderImage() -> UIImage? {
        let size = CGSize(width: 40, height: 40)
        UIGraphicsBeginImageContextWithOptions(size, false, UIScreen.main.scale)
        UIColor(white: 0.15, alpha: 1).setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let img = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return img
    }
}
