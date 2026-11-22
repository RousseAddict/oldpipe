import UIKit

// MARK: - AppMenu
//
// The app's one menu. Every list of choices opens here instead of as the system action sheet:
// Share, Add to playlist, Cast, the Download button, Playback and its Quality / Speed /
// Captions submenus, the Settings choices and a channel group's actions. So a menu looks and
// behaves the same on iOS 5 to 8, on iPhone and iPad, on a page and over a fullscreen video.
//
// A UIActionSheet still describes each menu (title, rows, tag, cancel and destructive
// indices) but is never shown. A pick goes to that sheet's delegate exactly as a tap on the
// sheet would, so no screen's handling changed when its menus moved here.
//
// Where it opens:
//  - Over a fullscreen video it is a plain view INSIDE the overlay, so it turns with it,
//    refits when the iPad resizes it, and measures the room it really has. The system sheet
//    failed there in a different way on each side of iOS 8. Before iOS 8 it sized itself for
//    the portrait screen and ran off the top of a landscape one (iOS 5.1.1 and 6). From iOS 8
//    it is a UIAlertController and needs a presenting view controller, which the overlay (a
//    bare window subview) doesn't have.
//  - Anywhere else it covers the whole window, above the mini bar and the iPad video card,
//    where the system sheet drew too. The iPad stretches window subviews when it turns, the
//    same way it stretches the mini bar.
//
// iOS 5/6 rules followed throughout:
//  - Every UILabel gets a clear background (the default is white).
//  - Buttons are .custom.
//  - Taps are button targets, not recognizers (on iOS 6 a recognizer fires alongside the
//    buttons above it).
//  - No clipsToBounds with a corner radius (an off-screen render pass on every frame).
//  - Timing is UIView animation only. There is no Dispatch on iOS 5.
final class AppMenu: UIView {

    // The menu up right now. There is only ever one: opening another closes this one,
    // unanswered. (Also how the iOS 5 build's press/ hook finds it.)
    private(set) static weak var current: AppMenu?

    // Show `sheet` for `page`: inside `overlay` when one is given (the fullscreen video), else
    // over the page's whole window. Nothing opens for a page that isn't on screen.
    @discardableResult
    static func show(_ sheet: UIActionSheet, from page: UIViewController, in overlay: UIView? = nil) -> AppMenu? {
        guard let host = overlay ?? page.view.window else { return nil }
        current?.close()
        let menu = AppMenu(sheet: sheet, owner: page, frame: host.bounds)
        host.addSubview(menu)
        current = menu
        menu.present()
        return menu
    }

    // Take down the menu `page` opened, if it is up, without an answer, as a system sheet left
    // with the view it was shown in. For a page that is leaving, and for a video going in or
    // out of fullscreen under its menu.
    static func dismiss(ownedBy page: UIViewController) {
        guard let menu = current, menu.owner == nil || menu.owner === page else { return }
        menu.close()
    }

    private let sheet: UIActionSheet
    // Held weakly on this side. UIActionSheet's own delegate pointer is not retained on
    // iOS 5/6, and the page may be gone by the time a pick arrives.
    private weak var delegate: UIActionSheetDelegate?
    private weak var owner: UIViewController?
    private var done = false

    private let cancelIndex: Int
    private let backdrop = UIButton(type: .custom)
    private let panel = UIView()
    private let heading: UILabel?
    private let scroll = UIScrollView()
    private var rowButtons: [UIButton] = []
    private var rowLines: [UIView] = []
    private let cancelLine = UIView()
    private let cancelButton = UIButton(type: .custom)
    private var checkedRow = -1
    private var scrolledToChecked = false

    private static let rowH: CGFloat = 40
    private static let titleH: CGFloat = 34
    private static let maxTitleLines: CGFloat = 4
    private static let cancelH: CGFloat = 44
    private static let margin: CGFloat = 12
    private static let maxWidth: CGFloat = 320
    private static let lineColor = UIColor(white: 1, alpha: 0.12)
    private static let rowHighlight = UIColor(white: 1, alpha: 0.14)

    private init(sheet: UIActionSheet, owner: UIViewController, frame: CGRect) {
        self.sheet = sheet
        self.delegate = sheet.delegate
        self.owner = owner
        cancelIndex = sheet.cancelButtonIndex
        let title = sheet.title
        if title.isEmpty {
            heading = nil
        } else {
            let lbl = UILabel()
            lbl.backgroundColor = .clear
            lbl.textColor = UIColor(white: 0.6, alpha: 1)
            lbl.font = UIFont.boldSystemFont(ofSize: 13)
            lbl.textAlignment = .center
            // Wraps: the Download menu's title can be two lines, Share's is the whole link.
            // Before iOS 7, sizeThatFits measures one line unless BOTH of these are set.
            lbl.numberOfLines = 0
            lbl.lineBreakMode = .byWordWrapping
            lbl.text = title
            heading = lbl
        }
        super.init(frame: frame)
        backgroundColor = .clear
        // Follows its host: the window when the iPad turns, or the fullscreen overlay that
        // relayoutForRotation resizes. layoutSubviews then refits the panel.
        autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Off the panel is Cancel.
        backdrop.backgroundColor = UIColor(white: 0, alpha: 0.5)
        backdrop.addTarget(self, action: #selector(menuCancelTapped), for: .touchUpInside)
        addSubview(backdrop)

        // Opaque: over a page, even 3% see-through lets its text show behind the rows.
        panel.backgroundColor = UIColor(white: 0.12, alpha: 1)
        // The layer's own background rounds without clipping, and nothing filled reaches a
        // corner: the rows start below the title (or a 6pt pad), Cancel highlights by colour.
        panel.layer.cornerRadius = 10
        addSubview(panel)
        if let lbl = heading { panel.addSubview(lbl) }

        scroll.backgroundColor = .clear
        scroll.indicatorStyle = .white
        panel.addSubview(scroll)

        for i in 0..<sheet.numberOfButtons where i != cancelIndex {
            let rowTitle = sheet.buttonTitle(at: i) ?? ""
            // A "✓ " row is the choice in force. It is drawn red and bold, and scrolled into
            // view on opening. A destructive row (Stop Casting, Delete Group) is drawn red.
            let checked = rowTitle.hasPrefix("\u{2713}")
            if checked && checkedRow < 0 { checkedRow = rowButtons.count }
            let red = checked || i == sheet.destructiveButtonIndex
            let b = UIButton(type: .custom)
            b.tag = i
            b.setTitle(rowTitle, for: .normal)
            b.setTitleColor(red ? Theme.accent : .white, for: .normal)
            b.titleLabel?.font = checked ? UIFont.boldSystemFont(ofSize: 16) : UIFont.systemFont(ofSize: 16)
            b.titleLabel?.lineBreakMode = .byTruncatingTail
            b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
            b.addTarget(self, action: #selector(menuRowDown(_:)), for: [.touchDown, .touchDragEnter])
            b.addTarget(self, action: #selector(menuRowUp(_:)), for: [.touchUpOutside, .touchCancel, .touchDragExit])
            b.addTarget(self, action: #selector(menuRowTapped(_:)), for: .touchUpInside)
            scroll.addSubview(b)
            rowButtons.append(b)
            let sep = UIView()
            sep.backgroundColor = AppMenu.lineColor
            sep.isUserInteractionEnabled = false
            scroll.addSubview(sep)
            rowLines.append(sep)
        }

        cancelLine.backgroundColor = UIColor(white: 1, alpha: 0.25)
        panel.addSubview(cancelLine)
        let cancelTitle = cancelIndex >= 0 ? (sheet.buttonTitle(at: cancelIndex) ?? "Cancel") : "Cancel"
        cancelButton.setTitle(cancelTitle, for: .normal)
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.setTitleColor(UIColor(white: 0.5, alpha: 1), for: .highlighted)
        cancelButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        cancelButton.addTarget(self, action: #selector(menuCancelTapped), for: .touchUpInside)
        panel.addSubview(cancelButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Everything is placed from the menu's current size, so the first layout and a refit
    // after the iPad turns are the same code.
    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        let line = 1 / UIScreen.main.scale
        let rowH = AppMenu.rowH
        let margin = AppMenu.margin
        let pw = min(bounds.width - 40, AppMenu.maxWidth)
        // Over a page the status bar overlays the window's top edge on every iOS: the panel
        // centres in the room below it. The fullscreen overlay has no status bar over it.
        let top: CGFloat = superview is UIWindow ? UIApplication.shared.statusBarFrame.height : 0

        // The title wraps, up to four lines. Without one the first row would meet the rounded
        // top corner, where its square highlight would show, so a little padding goes there.
        var topH: CGFloat = 6
        if let h = heading, let font = h.font {
            let fit = h.sizeThatFits(CGSize(width: pw - 24, height: CGFloat.greatestFiniteMagnitude))
            let textH = min(ceil(fit.height), ceil(font.lineHeight * AppMenu.maxTitleLines))
            topH = max(AppMenu.titleH, textH + 16)
            h.frame = CGRect(x: 12, y: floor((topH - textH) / 2), width: pw - 24, height: textH)
        }
        let allRowsH = CGFloat(rowButtons.count) * rowH
        let roomH = bounds.height - top - 2 * margin - topH - line - AppMenu.cancelH
        let rowsH = max(min(allRowsH, roomH), min(allRowsH, rowH))
        let ph = topH + rowsH + line + AppMenu.cancelH

        let roomY = bounds.height - top
        panel.frame = CGRect(x: floor((bounds.width - pw) / 2), y: top + max(floor((roomY - ph) / 2), 0),
                             width: pw, height: ph)
        scroll.frame = CGRect(x: 0, y: topH, width: pw, height: rowsH)
        scroll.contentSize = CGSize(width: pw, height: allRowsH)
        scroll.isScrollEnabled = allRowsH > rowsH
        for (n, b) in rowButtons.enumerated() {
            let y = CGFloat(n) * rowH
            b.frame = CGRect(x: 0, y: y, width: pw, height: rowH)
            rowLines[n].frame = CGRect(x: 0, y: y, width: pw, height: line)
        }
        cancelLine.frame = CGRect(x: 0, y: topH + rowsH, width: pw, height: line)
        cancelButton.frame = CGRect(x: 0, y: topH + rowsH + line, width: pw, height: AppMenu.cancelH)

        // The checked row is centred once, on the first layout. A refit after that only keeps
        // the offset in range, so turning the iPad doesn't undo the viewer's own scrolling.
        let maxOffset = max(allRowsH - rowsH, 0)
        var offset = min(scroll.contentOffset.y, maxOffset)
        if !scrolledToChecked {
            scrolledToChecked = true
            if checkedRow >= 0 {
                offset = min(max(CGFloat(checkedRow) * rowH + rowH / 2 - rowsH / 2, 0), maxOffset)
            }
        }
        if offset != scroll.contentOffset.y { scroll.contentOffset = CGPoint(x: 0, y: offset) }
    }

    private func present() {
        layoutIfNeeded()
        alpha = 0
        UIView.animate(withDuration: 0.2, animations: { self.alpha = 1 }, completion: { _ in
            // The rows run past the panel: the indicator says there is more below.
            if self.scroll.isScrollEnabled { self.scroll.flashScrollIndicators() }
        })
    }

    // Gone at once and unanswered: replaced by another menu, or its page or overlay is leaving.
    private func close() {
        guard !done else { return }
        done = true
        if AppMenu.current === self { AppMenu.current = nil }
        removeFromSuperview()
    }

    // One answer per menu, however fast the taps come. The menu is let go before the delegate
    // hears, so a pick that opens the next menu (Playback -> Speed) opens it cleanly.
    private func finish(_ index: Int?) {
        guard !done else { return }
        done = true
        isUserInteractionEnabled = false
        if AppMenu.current === self { AppMenu.current = nil }
        UIView.animate(withDuration: 0.15, animations: { self.alpha = 0 }, completion: { _ in
            self.removeFromSuperview()
        })
        // A page no longer on screen is not answered: its menu outlived it.
        guard let i = index, let d = delegate, owner?.view.window != nil else { return }
        d.actionSheet?(sheet, clickedButtonAt: i)
    }

    @objc private func menuRowTapped(_ sender: UIButton) { finish(sender.tag) }
    @objc private func menuCancelTapped() { finish(cancelIndex >= 0 ? cancelIndex : nil) }
    @objc private func menuRowDown(_ sender: UIButton) { sender.backgroundColor = AppMenu.rowHighlight }
    @objc private func menuRowUp(_ sender: UIButton) { sender.backgroundColor = .clear }
}
