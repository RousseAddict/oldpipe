import UIKit

// MARK: - ManageSubscriptionsVC
// Subscribed channels, with channel groups folded in as a filter strip across the top:
// "All", one pill per group, then "+" to create one. Picking a group narrows the list to
// its channels, and Edit then turns that same list into the group's membership editor
// (every subscription, with checkmarks) instead of the unsubscribe list it is under "All".
// The (i) on a row goes the other way round — which groups is THIS channel in.
// Tapping the already-active pill offers Open Feed / Rename / Delete for that group.
//
// Groups have no screen of their own: this is the only place they are managed.

class ManageSubscriptionsVC: UIViewController, UITableViewDataSource, UITableViewDelegate,
                             UIAlertViewDelegate, UIActionSheetDelegate {

    private var allChannels: [Channel] = []
    private var groups: [ChannelGroup] = []
    private var activeGroupId: String?           // nil = "All"
    private var memberIds: Set<String> = []      // channel ids in the active group
    private var rows: [Channel] = []             // what the table actually shows
    private var didSetupUI = false

    private var pillScroll: UIScrollView!
    private var tableView: UITableView!
    private var statusLabel: UILabel!
    private var feedItem: UIBarButtonItem!

    private let bg = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
    private let accent = UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 1)
    private let pillBarH: CGFloat = 44

    // Pill tags: 0 = All, 1...n = groups[tag - 1], newGroupPillTag = "+".
    private let newGroupPillTag = 1000

    // Alert tags, since one delegate serves both.
    private let alertTagCreate = 1
    private let alertTagRename = 2

    private var activeGroup: ChannelGroup? {
        guard let id = activeGroupId else { return nil }
        return groups.first { $0.id == id }
    }

    // Under "All", Edit means unsubscribe. Inside a group it means edit membership.
    private var isEditingMembership: Bool { return isEditing && activeGroupId != nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Subscriptions"
        view.backgroundColor = bg
        feedItem = UIBarButtonItem(title: "Feed", style: .plain, target: self, action: #selector(openFeed))
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

        pillScroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: w, height: pillBarH))
        pillScroll.backgroundColor = UIColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)
        pillScroll.showsHorizontalScrollIndicator = false
        pillScroll.autoresizingMask = iPadFlexWidth
        view.addSubview(pillScroll)

        let hair = UIView(frame: CGRect(x: 0, y: pillBarH - 0.5, width: w, height: 0.5))
        hair.backgroundColor = UIColor(white: 0.2, alpha: 1)
        hair.autoresizingMask = iPadFlexWidth
        view.addSubview(hair)

        tableView = UITableView(frame: CGRect(x: 0, y: pillBarH, width: w, height: h - navH - pillBarH))
        tableView.backgroundColor = bg
        tableView.separatorColor = UIColor(white: 0.2, alpha: 1)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerCell(ChannelCell.self, ChannelCell.reuseId)
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 60, right: 0)
        tableView.tableFooterView = UIView()   // hide separators on empty rows (iOS 6)
        // Membership editing happens in edit mode, so rows must stay tappable there.
        tableView.allowsSelectionDuringEditing = true
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
        statusLabel.text = "No subscriptions yet"
        tableView.addSubview(statusLabel)
    }

    private func reload() {
        allChannels = SubscriptionManager.all()
        groups = ChannelGroupManager.all()
        // The active group may have been deleted elsewhere (Settings reset, import).
        if activeGroupId != nil && activeGroup == nil { activeGroupId = nil }
        rebuildPills()
        rebuildRows()
        updateNavItems()
        tableView?.reloadData()
    }

    private func rebuildRows() {
        if let g = activeGroup {
            memberIds = Set(g.channelIds)
            // Editing a group shows every subscription so membership can be toggled;
            // otherwise only the members (intersected with the live subscriptions).
            rows = isEditing ? allChannels : allChannels.filter { memberIds.contains($0.id) }
        } else {
            memberIds = []
            rows = allChannels
        }

        if allChannels.isEmpty {
            statusLabel?.text = "No subscriptions yet"
            statusLabel?.isHidden = false
        } else if rows.isEmpty {
            statusLabel?.text = "No channels in this group.\nTap Edit to add some."
            statusLabel?.isHidden = false
        } else {
            statusLabel?.isHidden = true
        }
    }

    private func updateNavItems() {
        if activeGroupId != nil {
            feedItem.isEnabled = !memberIds.isEmpty
            navigationItem.rightBarButtonItems = [editButtonItem, feedItem]
        } else {
            navigationItem.rightBarButtonItems = [editButtonItem]
        }
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView?.setEditing(editing, animated: animated)
        rebuildRows()
        tableView?.reloadData()
    }

    // MARK: - Pills

    private func rebuildPills() {
        guard let strip = pillScroll else { return }
        for v in strip.subviews { v.removeFromSuperview() }

        var x: CGFloat = 10
        x = addPill(title: "All", tag: 0, active: activeGroupId == nil, at: x)
        for (i, g) in groups.enumerated() {
            x = addPill(title: g.name, tag: i + 1, active: g.id == activeGroupId, at: x)
        }
        x = addPill(title: "+", tag: newGroupPillTag, active: false, at: x)
        strip.contentSize = CGSize(width: x, height: pillBarH)
    }

    // Returns the x for the next pill. Width comes from sizeToFit rather than a string
    // measurement API (NSString.size(withAttributes:) is iOS 7+).
    private func addPill(title: String, tag: Int, active: Bool, at x: CGFloat) -> CGFloat {
        let b = UIButton(type: .custom)
        b.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
        b.setTitle(title, for: .normal)
        b.sizeToFit()
        let pw = max(34, b.bounds.width + 24)
        b.frame = CGRect(x: x, y: 7, width: pw, height: 30)
        b.setTitleColor(active ? .white : UIColor(white: 0.7, alpha: 1), for: .normal)
        b.backgroundColor = active ? accent : UIColor(white: 0.18, alpha: 1)
        b.layer.cornerRadius = 15   // no clipsToBounds — avoids off-screen rendering
        b.tag = tag
        b.addTarget(self, action: #selector(pillTapped(_:)), for: .touchUpInside)
        pillScroll.addSubview(b)
        return x + pw + 8
    }

    @objc private func pillTapped(_ sender: UIButton) {
        if sender.tag == newGroupPillTag {
            promptNewGroup()
            return
        }
        let newId: String? = (sender.tag == 0) ? nil : groups[sender.tag - 1].id
        // Re-tapping the active group pill opens its actions instead of re-selecting it.
        if newId != nil && newId == activeGroupId {
            showGroupActions()
            return
        }
        if isEditing { setEditing(false, animated: false) }
        activeGroupId = newId
        rebuildPills()
        rebuildRows()
        updateNavItems()
        tableView?.reloadData()
    }

    @objc private func openFeed() {
        guard let g = activeGroup else { return }
        navigationController?.pushViewController(HomeVC(groupId: g.id), animated: true)
    }

    // MARK: - Group actions

    // Empty init + addButton (NOT the variadic otherButtonTitles: convenience init, which
    // crashes on the 5.1.5 runtime).
    private func showGroupActions() {
        guard let g = activeGroup else { return }
        let sheet = UIActionSheet()
        sheet.delegate = self
        sheet.title = g.name
        sheet.addButton(withTitle: "Open Feed")
        sheet.addButton(withTitle: "Rename")
        sheet.addButton(withTitle: "Delete Group")
        sheet.addButton(withTitle: "Cancel")
        sheet.destructiveButtonIndex = 2
        sheet.cancelButtonIndex = 3
        sheet.show(in: view)
    }

    func actionSheet(_ actionSheet: UIActionSheet, clickedButtonAt buttonIndex: Int) {
        guard let g = activeGroup else { return }
        switch buttonIndex {
        case 0:
            openFeed()
        case 1:
            let alert = UIAlertView()
            alert.delegate = self
            alert.tag = alertTagRename
            alert.title = "Rename Group"
            alert.message = "Enter a new name"
            alert.alertViewStyle = .plainTextInput
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Rename")
            alert.cancelButtonIndex = 0
            alert.textField(at: 0)?.text = g.name
            alert.show()
        case 2:
            ChannelGroupManager.delete(id: g.id)
            activeGroupId = nil
            if isEditing { setEditing(false, animated: false) }
            reload()
        default:
            break
        }
    }

    private func promptNewGroup() {
        let alert = UIAlertView()
        alert.delegate = self
        alert.tag = alertTagCreate
        alert.title = "New Group"
        alert.message = "Enter a name"
        alert.alertViewStyle = .plainTextInput
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Create")
        alert.cancelButtonIndex = 0
        alert.show()
    }

    func alertView(_ alertView: UIAlertView, clickedButtonAt buttonIndex: Int) {
        guard buttonIndex == 1 else { return }   // 0 = Cancel, 1 = confirm
        let name = (alertView.textField(at: 0)?.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        if alertView.tag == alertTagRename {
            guard let g = activeGroup else { return }
            ChannelGroupManager.rename(id: g.id, to: name)
            reload()
            return
        }

        let group = ChannelGroupManager.create(name: name)
        activeGroupId = group.id
        reload()
        // A brand-new group is empty, so drop straight into picking its channels.
        setEditing(true, animated: true)
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueCell(ChannelCell.self, ChannelCell.reuseId, for: indexPath)
        let channel = rows[indexPath.row]
        cell.configure(with: channel)
        cell.accessoryType = isEditingMembership
            ? (memberIds.contains(channel.id) ? .checkmark : .none)
            : .detailDisclosureButton
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 56
    }

    // Only the "All" list unsubscribes; inside a group, editing means membership, so the
    // delete control is suppressed there.
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return activeGroupId == nil
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        let channel = rows[indexPath.row]
        SubscriptionManager.unsubscribe(channel.id)
        allChannels.removeAll { $0.id == channel.id }
        rows.remove(at: indexPath.row)
        tableView.deleteRows(at: [indexPath], with: .automatic)
        if allChannels.isEmpty {
            statusLabel?.text = "No subscriptions yet"
            statusLabel?.isHidden = false
        }
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let channel = rows[indexPath.row]

        if isEditingMembership, let g = activeGroup {
            if memberIds.contains(channel.id) {
                memberIds.remove(channel.id)
                ChannelGroupManager.remove(channelId: channel.id, from: g.id)
            } else {
                memberIds.insert(channel.id)
                ChannelGroupManager.add(channelId: channel.id, to: g.id)
            }
            tableView.cellForRow(at: indexPath)?.accessoryType =
                memberIds.contains(channel.id) ? .checkmark : .none
            groups = ChannelGroupManager.all()
            updateNavItems()
            return
        }

        navigationController?.openChannel(id: channel.id, name: channel.name)
    }

    // The inverse of the pill filter: which groups is this one channel in.
    func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        guard !isEditingMembership else { return }
        navigationController?.pushViewController(
            ChannelGroupsVC(channel: rows[indexPath.row]), animated: true)
    }
}

// MARK: - ChannelGroupsVC
// Per-channel group assignment: every group with a checkmark for the ones this channel
// belongs to, plus a trailing "New Group..." row. Toggles are written through immediately.

class ChannelGroupsVC: UIViewController, UITableViewDataSource, UITableViewDelegate, UIAlertViewDelegate {

    private let channel: Channel
    private var groups: [ChannelGroup] = []
    private var didSetupUI = false

    private var tableView: UITableView!
    private var statusLabel: UILabel!

    private let bg = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)

    init(channel: Channel) {
        self.channel = channel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = channel.name.isEmpty ? "Groups" : channel.name
        view.backgroundColor = bg
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
        tableView.autoresizingMask = iPadFlexWidthHeight
        view.addSubview(tableView)

        statusLabel = UILabel(frame: CGRect(x: 20, y: 80, width: w - 40, height: 60))
        statusLabel.autoresizingMask = iPadFlexWidth
        statusLabel.backgroundColor = .clear
        statusLabel.textColor = UIColor(white: 0.5, alpha: 1)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.font = UIFont.systemFont(ofSize: 15)
        statusLabel.text = "No groups yet.\nTap \"New Group...\" to make one."
        tableView.addSubview(statusLabel)
    }

    private func reload() {
        groups = ChannelGroupManager.all()
        statusLabel?.isHidden = !groups.isEmpty
        tableView?.reloadData()
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return groups.count + 1   // + the "New Group..." row
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let id = "ChannelGroupCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: id)
            ?? UITableViewCell(style: .default, reuseIdentifier: id)

        cell.backgroundColor = bg
        cell.textLabel?.backgroundColor = .clear
        cell.textLabel?.font = UIFont.systemFont(ofSize: 16)

        if indexPath.row == groups.count {
            cell.textLabel?.text = "New Group..."
            cell.textLabel?.textColor = UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 1)
            cell.accessoryType = .none
        } else {
            let g = groups[indexPath.row]
            cell.textLabel?.text = g.name
            cell.textLabel?.textColor = UIColor(white: 0.95, alpha: 1)
            cell.accessoryType = g.channelIds.contains(channel.id) ? .checkmark : .none
        }

        let sel = UIView()
        sel.backgroundColor = UIColor(white: 0.15, alpha: 1)
        cell.selectedBackgroundView = sel
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 48
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        if indexPath.row == groups.count {
            let alert = UIAlertView()
            alert.delegate = self
            alert.title = "New Group"
            alert.message = "Enter a name"
            alert.alertViewStyle = .plainTextInput
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Create")
            alert.cancelButtonIndex = 0
            alert.show()
            return
        }

        let g = groups[indexPath.row]
        if g.channelIds.contains(channel.id) {
            ChannelGroupManager.remove(channelId: channel.id, from: g.id)
        } else {
            ChannelGroupManager.add(channelId: channel.id, to: g.id)
        }
        groups = ChannelGroupManager.all()
        tableView.reloadRows(at: [indexPath], with: .none)
    }

    func alertView(_ alertView: UIAlertView, clickedButtonAt buttonIndex: Int) {
        guard buttonIndex == 1 else { return }   // 0 = Cancel, 1 = Create
        let name = (alertView.textField(at: 0)?.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        // Creating from here implies wanting this channel in it.
        let group = ChannelGroupManager.create(name: name)
        ChannelGroupManager.add(channelId: channel.id, to: group.id)
        reload()
    }
}

// MARK: - ChannelCell
// Circular avatar (AsyncImageView, which cancels its own in-flight request on reload) +
// channel name. Using a dedicated AsyncImageView — not the cell's built-in imageView plus
// the static loadCell — is what keeps the right avatar on the right row while reusing.

private class ChannelCell: UITableViewCell {

    static let reuseId = "ChannelCell"

    private let avatar = AsyncImageView()
    private let nameLbl = UILabel()
    private let bg = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)

    required override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = bg

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
        nameLbl.frame = CGRect(x: 64, y: 0, width: contentView.bounds.width - 64 - 44,
                               height: contentView.bounds.height)
    }
}
