import UIKit

// MARK: - DownloadOptionsView
//
// The Download picker: sections of rows over a dimmed screen, confirmed with Download. The
// video page fills it with Save to, Video, Audio and Captions; another section slots in by
// appending another Section — the layout and hit-testing walk the array and know nothing
// about what a section means. The one place a caller reacts to a tap is onChange (Photos
// greys out Audio and Captions).
//
// A view of its own rather than an AppMenu: a menu is a flat list answered by one tap, while
// this carries a size per row, section headings, several ticks at once and a confirm step.
// It is drawn as an AppMenu all the same (panel, heading, rows, red ticks, the Cancel bar) on
// every iOS, and opens where one does: over the whole window. Inside the page's view, the mini
// bar of another video sat on top of its buttons.
//
// iOS 5/6 rules followed throughout, as in AppMenu:
//  - Every UILabel gets a clear background (the default is white).
//  - Buttons are .custom, and no tintColor (an unrecognized selector on iOS 6).
//  - Taps are button targets, not recognizers (on iOS 6 a recognizer fires alongside the
//    buttons above it).
//  - No clipsToBounds with a corner radius (an off-screen render pass on every frame).

struct DownloadOptionRow {
    let title: String       // "720p"
    let detail: String      // "~48 MB"
    let mark: String        // "\u{2713}" already downloaded, "\u{2022}" the Settings default, "" otherwise
    let enabled: Bool
    // Opaque to this view — the caller maps it back to a stream / format / track.
    let tag: Int
}

// How a section's rows behave. The modal mixes all three: the download target is one choice
// spread over two groups, where it goes is a choice of its own, and caption languages are
// independent ticks in the same sheet.
enum DownloadOptionMode {
    // Part of the modal-wide SINGLE choice: ticking a row here clears every other exclusive
    // section too, so "720p" and "Audio only" cannot both be chosen.
    case exclusive
    // One row of this section, whatever the others hold ("oldpipe" or "Photos").
    case single
    // Independent — any number of rows may be ticked, and other sections are untouched.
    case multi
}

struct DownloadOptionSection {
    let title: String
    let rows: [DownloadOptionRow]
    let mode: DownloadOptionMode
    // Row indices ticked when the modal opens. Empty for none.
    let initialSelection: [Int]
}

final class DownloadOptionsView: UIView {

    // The picker up right now, if any. (Also how the iOS 5 build's press/ hook finds it.)
    private(set) static weak var current: DownloadOptionsView?

    // AppMenu's measures, so the two read as one.
    private static let rowH: CGFloat = 40
    private static let headerH: CGFloat = 26
    private static let titleH: CGFloat = 34
    private static let footH: CGFloat = 44
    private static let margin: CGFloat = 12
    private static let maxWidth: CGFloat = 320
    private static let markW: CGFloat = 28
    private static let detailW: CGFloat = 90
    private static let lineColor = UIColor(white: 1, alpha: 0.12)
    private static let footLineColor = UIColor(white: 1, alpha: 0.25)
    private static let rowHighlight = UIColor(white: 1, alpha: 0.14)
    // A row's own mark (already downloaded) when it isn't the one ticked: grey, so the red
    // tick stays the pick.
    private static let markGrey = UIColor(white: 0.5, alpha: 1)

    // MARK: - State

    private let sections: [DownloadOptionSection]
    // Ticked row indices per section. A Set because a .multi section can hold several.
    private var selection: [Set<Int>]
    // A greyed-out section keeps its ticks, so turning it back on restores them.
    private var sectionEnabled: [Bool]
    private var onConfirm: (([[Int]]) -> Void)?
    private var onChange: ((DownloadOptionsView, [[Int]]) -> Void)?
    private weak var owner: UIViewController?
    private var done = false

    private let backdrop = UIButton(type: .custom)
    private let panel = UIView()
    private let titleLabel = UILabel()
    private let scroll = UIScrollView()
    private let footLine = UIView()
    private let footDivider = UIView()
    private let confirmBtn = UIButton(type: .custom)
    private let cancelBtn = UIButton(type: .custom)
    // Row buttons, flattened in the same order the sections declare them, so a button's tag
    // maps back to (section, row) through rowIndexPaths.
    private var rowButtons: [UIButton] = []
    private var rowLines: [UIView] = []
    private var rowIndexPaths: [(section: Int, row: Int)] = []
    // Held explicitly rather than reached through btn.subviews[n]: UIButton creates its own
    // titleLabel/imageView lazily, so subview order is not ours to depend on.
    private var rowNameLabels: [UILabel] = []
    private var rowDetailLabels: [UILabel] = []
    private var rowMarkLabels: [UILabel] = []
    private var sectionHeaders: [Int: UILabel] = [:]

    // MARK: - Presentation

    // Open over the whole window of `page`, above the mini bar and the iPad video card, and
    // fade in. Nothing opens for a page that isn't on screen. `onChange` runs after every tap,
    // and once before the picker shows, with the ticks so far.
    @discardableResult
    static func present(from page: UIViewController, title: String, sections: [DownloadOptionSection],
                        confirmTitle: String,
                        onChange: ((DownloadOptionsView, [[Int]]) -> Void)? = nil,
                        onConfirm: @escaping ([[Int]]) -> Void) -> DownloadOptionsView? {
        guard let host = page.view.window else { return nil }
        current?.close()
        let v = DownloadOptionsView(frame: host.bounds, owner: page, title: title, sections: sections,
                                    confirmTitle: confirmTitle, onConfirm: onConfirm)
        v.onChange = onChange
        v.notifyChange()
        host.addSubview(v)
        current = v
        v.present()
        return v
    }

    // Take down the picker `page` opened, if it is up, without an answer: for a page that is
    // leaving (autoplay can move on to the next video under it).
    static func dismiss(ownedBy page: UIViewController) {
        guard let v = current, v.owner == nil || v.owner === page else { return }
        v.close()
    }

    // MARK: - Changes from onChange

    // Grey a section out, or back in. Its rows stop taking taps but keep their ticks; whether
    // those still count is the caller's to decide when it reads `picked`.
    func setSectionEnabled(_ section: Int, _ enabled: Bool) {
        guard section >= 0, section < sections.count, sectionEnabled[section] != enabled else { return }
        sectionEnabled[section] = enabled
        for (i, path) in rowIndexPaths.enumerated() where path.section == section {
            rowButtons[i].isEnabled = enabled && sections[section].rows[path.row].enabled
            rowButtons[i].alpha = enabled ? 1 : 0.35
        }
        sectionHeaders[section]?.alpha = enabled ? 1 : 0.35
    }

    // Tick a row as a tap would, without calling onChange back.
    func select(section: Int, row: Int) {
        guard section >= 0, section < sections.count,
              row >= 0, row < sections[section].rows.count else { return }
        apply(section: section, row: row)
        refreshSelectionMarks()
    }

    func setConfirmTitle(_ title: String) {
        confirmBtn.setTitle(title, for: .normal)
    }

    private init(frame: CGRect, owner: UIViewController, title: String,
                 sections: [DownloadOptionSection], confirmTitle: String,
                 onConfirm: @escaping ([[Int]]) -> Void) {
        self.sections = sections
        self.selection = sections.map { Set($0.initialSelection) }
        self.sectionEnabled = sections.map { _ in true }
        self.onConfirm = onConfirm
        self.owner = owner
        super.init(frame: frame)
        buildUI(title: title, confirmTitle: confirmTitle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - Build

    private func buildUI(title: String, confirmTitle: String) {
        backgroundColor = .clear
        // Follows the window when the iPad turns; layoutSubviews then refits the panel.
        autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Off the panel is Cancel.
        backdrop.backgroundColor = UIColor(white: 0, alpha: 0.5)
        backdrop.addTarget(self, action: #selector(pickerCancelTapped), for: .touchUpInside)
        addSubview(backdrop)

        // Opaque, as AppMenu: the page's text must not show through behind the rows.
        panel.backgroundColor = UIColor(white: 0.12, alpha: 1)
        panel.layer.cornerRadius = 10
        addSubview(panel)

        titleLabel.text = title
        titleLabel.textColor = UIColor(white: 0.6, alpha: 1)
        titleLabel.backgroundColor = .clear
        titleLabel.font = UIFont.boldSystemFont(ofSize: 13)
        titleLabel.textAlignment = .center
        panel.addSubview(titleLabel)

        scroll.backgroundColor = .clear
        scroll.indicatorStyle = .white
        panel.addSubview(scroll)

        buildRows()

        footLine.backgroundColor = DownloadOptionsView.footLineColor
        panel.addSubview(footLine)
        footDivider.backgroundColor = DownloadOptionsView.footLineColor
        panel.addSubview(footDivider)

        // Cancel where a menu has it, and the confirm beside it in red.
        cancelBtn.setTitle("Cancel", for: .normal)
        cancelBtn.setTitleColor(.white, for: .normal)
        cancelBtn.setTitleColor(UIColor(white: 0.5, alpha: 1), for: .highlighted)
        cancelBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        cancelBtn.addTarget(self, action: #selector(pickerCancelTapped), for: .touchUpInside)
        panel.addSubview(cancelBtn)

        confirmBtn.setTitle(confirmTitle, for: .normal)
        confirmBtn.setTitleColor(Theme.accent, for: .normal)
        confirmBtn.setTitleColor(Theme.accent.withAlphaComponent(0.5), for: .highlighted)
        confirmBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        confirmBtn.addTarget(self, action: #selector(pickerConfirmTapped), for: .touchUpInside)
        panel.addSubview(confirmBtn)
    }

    private func buildRows() {
        for (s, section) in sections.enumerated() {
            if !section.title.isEmpty {
                let header = UILabel()
                header.text = section.title.uppercased()
                header.textColor = UIColor(white: 0.55, alpha: 1)
                header.backgroundColor = .clear
                header.font = UIFont.boldSystemFont(ofSize: 11)
                scroll.addSubview(header)
                sectionHeaders[s] = header
            }
            for (r, row) in section.rows.enumerated() {
                let btn = UIButton(type: .custom)
                btn.isEnabled = row.enabled
                btn.tag = rowButtons.count
                btn.addTarget(self, action: #selector(pickerRowDown(_:)), for: [.touchDown, .touchDragEnter])
                btn.addTarget(self, action: #selector(pickerRowUp(_:)), for: [.touchUpOutside, .touchCancel, .touchDragExit])
                btn.addTarget(self, action: #selector(pickerRowTapped(_:)), for: .touchUpInside)
                scroll.addSubview(btn)

                let sep = UIView()
                sep.backgroundColor = DownloadOptionsView.lineColor
                sep.isUserInteractionEnabled = false
                scroll.addSubview(sep)

                // Font and colour come from refreshSelectionMarks: red and bold when ticked.
                let name = UILabel()
                name.text = row.title
                name.backgroundColor = .clear
                name.lineBreakMode = .byTruncatingTail
                btn.addSubview(name)

                let detail = UILabel()
                detail.text = row.detail
                detail.textColor = UIColor(white: 0.6, alpha: 1)
                detail.backgroundColor = .clear
                detail.font = UIFont.systemFont(ofSize: 13)
                detail.textAlignment = .right
                btn.addSubview(detail)

                // The tick. A label, not an image: "\u{2713}" is in iOS 5's font, unlike the
                // Unicode 7.0 glyphs that render blank there.
                let mark = UILabel()
                mark.backgroundColor = .clear
                mark.font = UIFont.boldSystemFont(ofSize: 16)
                mark.textAlignment = .center
                btn.addSubview(mark)

                rowButtons.append(btn)
                rowLines.append(sep)
                rowIndexPaths.append((s, r))
                rowNameLabels.append(name)
                rowDetailLabels.append(detail)
                rowMarkLabels.append(mark)
            }
        }
        refreshSelectionMarks()
    }

    // MARK: - Layout

    // Everything is placed from the picker's current size, so the first layout and a refit
    // after the iPad turns are the same code (AppMenu's layout, with headings and a two-button
    // bar).
    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        let line = 1 / UIScreen.main.scale
        let rowH = DownloadOptionsView.rowH, headerH = DownloadOptionsView.headerH
        let topH = DownloadOptionsView.titleH, footH = DownloadOptionsView.footH
        let markW = DownloadOptionsView.markW, detailW = DownloadOptionsView.detailW
        let pw = min(bounds.width - 40, DownloadOptionsView.maxWidth)
        // The status bar overlays the window's top edge: the panel centres in the room below.
        let top: CGFloat = superview is UIWindow ? UIApplication.shared.statusBarFrame.height : 0

        titleLabel.frame = CGRect(x: 12, y: 0, width: pw - 24, height: topH)

        // Headings and rows, in the scroller's own coordinates.
        var y: CGFloat = 0
        var idx = 0
        for (s, section) in sections.enumerated() {
            if let header = sectionHeaders[s] {
                header.frame = CGRect(x: 12, y: y + 8, width: pw - 24, height: headerH - 8)
                y += headerH
            }
            for _ in section.rows {
                guard idx < rowButtons.count else { break }
                rowButtons[idx].frame = CGRect(x: 0, y: y, width: pw, height: rowH)
                rowLines[idx].frame = CGRect(x: 0, y: y, width: pw, height: line)
                // name | detail | tick, the last two right-anchored
                rowNameLabels[idx].frame = CGRect(x: 12, y: 0, width: max(0, pw - 12 - detailW - markW - 8),
                                                  height: rowH)
                rowDetailLabels[idx].frame = CGRect(x: pw - markW - detailW - 4, y: 0, width: detailW, height: rowH)
                rowMarkLabels[idx].frame = CGRect(x: pw - markW - 6, y: 0, width: markW, height: rowH)
                y += rowH
                idx += 1
            }
        }
        let contentH = y

        // The rows scroll when the screen is short of room (five video tiers, the audio, the
        // destinations and the captions outgrow a 3.5-inch screen).
        let roomH = bounds.height - top - 2 * DownloadOptionsView.margin - topH - line - footH
        let scrollH = max(min(contentH, roomH), min(contentH, rowH))
        let ph = topH + scrollH + line + footH
        let roomY = bounds.height - top
        panel.frame = CGRect(x: floor((bounds.width - pw) / 2), y: top + max(floor((roomY - ph) / 2), 0),
                             width: pw, height: ph)
        scroll.frame = CGRect(x: 0, y: topH, width: pw, height: scrollH)
        scroll.contentSize = CGSize(width: pw, height: contentH)
        scroll.isScrollEnabled = contentH > scrollH
        let maxOffset = max(contentH - scrollH, 0)
        if scroll.contentOffset.y > maxOffset { scroll.contentOffset = CGPoint(x: 0, y: maxOffset) }

        let footY = topH + scrollH
        footLine.frame = CGRect(x: 0, y: footY, width: pw, height: line)
        let cancelW = floor(pw * 0.4)
        cancelBtn.frame = CGRect(x: 0, y: footY + line, width: cancelW, height: footH)
        footDivider.frame = CGRect(x: cancelW, y: footY + line, width: line, height: footH)
        confirmBtn.frame = CGRect(x: cancelW + line, y: footY + line, width: pw - cancelW - line, height: footH)
    }

    private func present() {
        layoutIfNeeded()
        alpha = 0
        UIView.animate(withDuration: 0.2, animations: { self.alpha = 1 }, completion: { _ in
            // The rows run past the panel: the indicator says there is more below.
            if self.scroll.isScrollEnabled { self.scroll.flashScrollIndicators() }
        })
    }

    // MARK: - Selection

    private func apply(section: Int, row: Int) {
        switch sections[section].mode {
        case .exclusive:
            // Clear every exclusive section, not just this one — the choice spans them.
            for i in sections.indices where sections[i].mode == .exclusive {
                selection[i].removeAll()
            }
            selection[section] = [row]
        case .single:
            selection[section] = [row]
        case .multi:
            if selection[section].contains(row) {
                selection[section].remove(row)
            } else {
                selection[section].insert(row)
            }
        }
    }

    private func notifyChange() {
        onChange?(self, selection.map { Array($0).sorted() })
    }

    // A ticked row is red and bold with a red tick, as the choice in force in a menu. A row
    // that carries its own mark (already downloaded) keeps it in grey when it isn't ticked.
    private func refreshSelectionMarks() {
        for (i, path) in rowIndexPaths.enumerated() {
            let picked = selection[path.section].contains(path.row)
            let row = sections[path.section].rows[path.row]
            let name = rowNameLabels[i]
            name.font = picked ? UIFont.boldSystemFont(ofSize: 16) : UIFont.systemFont(ofSize: 16)
            name.textColor = picked ? Theme.accent
                : (row.enabled ? UIColor.white : UIColor(white: 0.45, alpha: 1))
            rowMarkLabels[i].text = picked ? "\u{2713}" : row.mark
            rowMarkLabels[i].textColor = picked ? Theme.accent : DownloadOptionsView.markGrey
        }
    }

    // MARK: - Actions

    @objc private func pickerRowTapped(_ sender: UIButton) {
        sender.backgroundColor = .clear
        let idx = sender.tag
        guard !done, idx >= 0, idx < rowIndexPaths.count else { return }
        let path = rowIndexPaths[idx]
        apply(section: path.section, row: path.row)
        refreshSelectionMarks()
        notifyChange()
    }

    @objc private func pickerRowDown(_ sender: UIButton) { sender.backgroundColor = DownloadOptionsView.rowHighlight }
    @objc private func pickerRowUp(_ sender: UIButton) { sender.backgroundColor = .clear }

    @objc private func pickerConfirmTapped() {
        let picked = selection.map { Array($0).sorted() }
        let handler = onConfirm
        guard finish() else { return }   // a double tap must not fire two downloads
        // A page no longer on screen is not answered: its picker outlived it.
        guard owner?.view.window != nil else { return }
        handler?(picked)
    }

    @objc private func pickerCancelTapped() {
        _ = finish()
    }

    // One answer per picker, however fast the taps come. False when it already had one.
    private func finish() -> Bool {
        guard !done else { return false }
        done = true
        onConfirm = nil
        isUserInteractionEnabled = false
        if DownloadOptionsView.current === self { DownloadOptionsView.current = nil }
        UIView.animate(withDuration: 0.15, animations: { self.alpha = 0 }, completion: { _ in
            self.removeFromSuperview()
        })
        return true
    }

    // Gone at once and unanswered: replaced by another picker, or its page is leaving.
    private func close() {
        guard !done else { return }
        done = true
        onConfirm = nil
        if DownloadOptionsView.current === self { DownloadOptionsView.current = nil }
        removeFromSuperview()
    }
}
