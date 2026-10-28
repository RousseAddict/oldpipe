import UIKit

// MARK: - DownloadOptionsView
//
// The "Download" modal: a card over a dimmed backdrop, built from a list of SECTIONS of rows.
// The video page fills it with Save to, Video, Audio and Captions; they slot in by appending
// another Section — the layout and hit-testing walk the array and know nothing about what a
// section means. The one place a caller reacts to a tap is onChange (Photos greys out Audio
// and Captions).
//
// A real view rather than a UIActionSheet because a sheet is a flat list of buttons: it can't
// carry a per-row size estimate, a section header, or the extra sections coming later.
//
// iOS 6 house rules observed throughout: every UILabel gets an explicit clear background (the
// default is WHITE, which is invisible-on-invisible here), buttons are .custom (.system
// overrides title colours), no tintColor (unrecognized selector on iOS 6), and taps are plain
// UIButton targets — a UITapGestureRecognizer on this view would fire alongside the row buttons.

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

    // MARK: - Look
    //
    // iOS 6 is flat and fully opaque with hard edges; iOS 7+ gets the lighter, rounder treatment
    // the rest of that build uses. Compile-time rather than a runtime version check, so each IPA
    // carries exactly one look — the same split the rest of the player VC uses.
    #if IOS6_TARGET
    private static let cardCorner: CGFloat = 0
    private static let rowCorner: CGFloat = 0
    private static let backdropAlpha: CGFloat = 0.55
    private static let cardBG = UIColor(red: 0.13, green: 0.13, blue: 0.13, alpha: 1)
    private static let rowBG = UIColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1)
    private static let separator = UIColor(white: 1, alpha: 0.10)
    #else
    private static let cardCorner: CGFloat = 12
    private static let rowCorner: CGFloat = 6
    private static let backdropAlpha: CGFloat = 0.70
    private static let cardBG = UIColor(red: 0.11, green: 0.11, blue: 0.11, alpha: 1)
    private static let rowBG = UIColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1)
    private static let separator = UIColor(white: 1, alpha: 0.07)
    #endif

    private static let rowHeight: CGFloat = 46
    private static let headerHeight: CGFloat = 26
    private static let footerHeight: CGFloat = 56
    private static let cardPadding: CGFloat = 12
    private static let maxCardWidth: CGFloat = 400   // keeps the card sane on an iPad

    // MARK: - State

    private let sections: [DownloadOptionSection]
    // Ticked row indices per section. A Set because a .multi section can hold several.
    private var selection: [Set<Int>]
    // A greyed-out section keeps its ticks, so turning it back on restores them.
    private var sectionEnabled: [Bool]
    private let confirmTitle: String
    private var onConfirm: (([[Int]]) -> Void)?
    private var onChange: ((DownloadOptionsView, [[Int]]) -> Void)?

    private let backdrop = UIButton(type: .custom)
    private let card = UIView()
    private let titleLabel = UILabel()
    private let confirmBtn = UIButton(type: .custom)
    private let cancelBtn = UIButton(type: .custom)
    // Row buttons, flattened in the same order the sections declare them, so a button's index
    // maps back to (section, row) through rowIndexPaths.
    private var rowButtons: [UIButton] = []
    private var rowIndexPaths: [(section: Int, row: Int)] = []
    // Held explicitly rather than reached through btn.subviews[n]: UIButton creates its own
    // titleLabel/imageView lazily, so subview order is not ours to depend on.
    private var rowNameLabels: [UILabel] = []
    private var rowDetailLabels: [UILabel] = []
    private var rowMarkLabels: [UILabel] = []
    private var headerLabels: [UILabel] = []
    private var sectionHeaders: [Int: UILabel] = [:]
    private var scroller = UIScrollView()

    // MARK: - Presentation

    // Add to `host` (the presenting VC's view) and fade in. Sized from the host's bounds and
    // flexible in both axes, so the iOS 8 build's iPad rotation reflows it for free and the
    // portrait-locked iOS 6/7 builds compile the mask to [] exactly as every other view does.
    // `onChange` runs after every tap, and once before the modal shows, with the ticks so far.
    @discardableResult
    static func present(in host: UIView, title: String, sections: [DownloadOptionSection],
                        confirmTitle: String,
                        onChange: ((DownloadOptionsView, [[Int]]) -> Void)? = nil,
                        onConfirm: @escaping ([[Int]]) -> Void) -> DownloadOptionsView {
        let v = DownloadOptionsView(frame: host.bounds, title: title, sections: sections,
                                    confirmTitle: confirmTitle, onConfirm: onConfirm)
        v.onChange = onChange
        v.notifyChange()
        v.autoresizingMask = iPadFlexWidthHeight
        v.alpha = 0
        host.addSubview(v)
        UIView.animate(withDuration: 0.18) { v.alpha = 1 }
        return v
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

    func dismiss() {
        UIView.animate(withDuration: 0.15, animations: { self.alpha = 0 }) { _ in
            self.removeFromSuperview()
        }
    }

    private init(frame: CGRect, title: String, sections: [DownloadOptionSection],
                 confirmTitle: String,
                 onConfirm: @escaping ([[Int]]) -> Void) {
        self.sections = sections
        self.selection = sections.map { Set($0.initialSelection) }
        self.sectionEnabled = sections.map { _ in true }
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
        super.init(frame: frame)
        buildUI(title: title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - Build

    private func buildUI(title: String) {
        backgroundColor = UIColor.clear

        // Backdrop doubles as the tap-to-dismiss target. A full-bleed button rather than a
        // gesture recognizer, so it cannot fire alongside a row button underneath it.
        backdrop.frame = bounds
        backdrop.autoresizingMask = iPadFlexWidthHeight
        backdrop.backgroundColor = UIColor(white: 0, alpha: DownloadOptionsView.backdropAlpha)
        backdrop.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        addSubview(backdrop)

        card.backgroundColor = DownloadOptionsView.cardBG
        // No clipsToBounds: cornerRadius alone rounds the layer background, and clipping would
        // force an off-screen render pass every frame (the OSR rule).
        card.layer.cornerRadius = DownloadOptionsView.cardCorner
        addSubview(card)

        titleLabel.text = title
        titleLabel.textColor = UIColor.white
        titleLabel.backgroundColor = UIColor.clear
        titleLabel.font = UIFont.boldSystemFont(ofSize: 17)
        titleLabel.textAlignment = .center
        card.addSubview(titleLabel)

        scroller.showsVerticalScrollIndicator = true
        scroller.backgroundColor = UIColor.clear
        card.addSubview(scroller)

        buildRows()

        confirmBtn.setTitle(confirmTitle, for: .normal)
        confirmBtn.setTitleColor(UIColor.white, for: .normal)
        confirmBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        confirmBtn.backgroundColor = Theme.accent
        confirmBtn.layer.cornerRadius = DownloadOptionsView.rowCorner
        confirmBtn.addTarget(self, action: #selector(confirmTapped), for: .touchUpInside)
        card.addSubview(confirmBtn)

        cancelBtn.setTitle("Cancel", for: .normal)
        cancelBtn.setTitleColor(UIColor(white: 0.7, alpha: 1), for: .normal)
        cancelBtn.titleLabel?.font = UIFont.systemFont(ofSize: 16)
        cancelBtn.backgroundColor = UIColor.clear
        cancelBtn.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        card.addSubview(cancelBtn)

        layoutCard()
    }

    private func buildRows() {
        for (s, section) in sections.enumerated() {
            if !section.title.isEmpty {
                let header = UILabel()
                header.text = section.title.uppercased()
                header.textColor = UIColor(white: 0.55, alpha: 1)
                header.backgroundColor = UIColor.clear
                header.font = UIFont.boldSystemFont(ofSize: 11)
                scroller.addSubview(header)
                headerLabels.append(header)
                sectionHeaders[s] = header
            }
            for (r, row) in section.rows.enumerated() {
                let btn = UIButton(type: .custom)
                btn.backgroundColor = DownloadOptionsView.rowBG
                btn.layer.cornerRadius = DownloadOptionsView.rowCorner
                btn.isEnabled = row.enabled
                btn.addTarget(self, action: #selector(rowTapped(_:)), for: .touchUpInside)
                btn.tag = rowButtons.count
                scroller.addSubview(btn)

                let name = UILabel()
                name.text = row.title
                name.textColor = row.enabled ? UIColor.white : UIColor(white: 0.45, alpha: 1)
                name.backgroundColor = UIColor.clear
                name.font = UIFont.boldSystemFont(ofSize: 15)
                btn.addSubview(name)

                let detail = UILabel()
                detail.text = row.detail
                detail.textColor = UIColor(white: 0.6, alpha: 1)
                detail.backgroundColor = UIColor.clear
                detail.font = UIFont.systemFont(ofSize: 12)
                detail.textAlignment = .right
                btn.addSubview(detail)

                // Selection tick. Kept as a label (not an image) so it costs nothing and
                // renders identically on every build; "\u{2713}" predates iOS 6's font by
                // decades, unlike the Unicode 7.0 glyphs that render blank there.
                let mark = UILabel()
                mark.text = row.mark
                mark.textColor = Theme.accent
                mark.backgroundColor = UIColor.clear
                mark.font = UIFont.boldSystemFont(ofSize: 15)
                mark.textAlignment = .center
                btn.addSubview(mark)

                rowButtons.append(btn)
                rowIndexPaths.append((s, r))
                rowNameLabels.append(name)
                rowDetailLabels.append(detail)
                rowMarkLabels.append(mark)
            }
        }
        refreshSelectionMarks()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutCard()
    }

    private func layoutCard() {
        let W = bounds.width, H = bounds.height
        guard W > 0, H > 0 else { return }
        let pad = DownloadOptionsView.cardPadding
        let cardW = min(W - pad * 2, DownloadOptionsView.maxCardWidth)

        // Natural content height, then clamp the scroller so the card always fits on screen
        // (a 1080p-capable video can list five tiers, and a 3.5-inch screen is 480pt tall).
        var contentH: CGFloat = 0
        for section in sections {
            if !section.title.isEmpty { contentH += DownloadOptionsView.headerHeight }
            contentH += CGFloat(section.rows.count) * DownloadOptionsView.rowHeight
            contentH += 6
        }
        let chromeH: CGFloat = 44 + DownloadOptionsView.footerHeight + pad
        let maxCardH = H - pad * 2
        let scrollH = min(contentH, maxCardH - chromeH)
        let cardH = chromeH + scrollH

        card.frame = CGRect(x: (W - cardW) / 2, y: (H - cardH) / 2, width: cardW, height: cardH)
        titleLabel.frame = CGRect(x: pad, y: 12, width: cardW - pad * 2, height: 22)
        scroller.frame = CGRect(x: pad, y: 44, width: cardW - pad * 2, height: scrollH)

        // Rows inside the scroller.
        let rowW = scroller.bounds.width
        var y: CGFloat = 0
        var btnIdx = 0
        var headerIdx = 0
        let markW: CGFloat = 26
        let detailW: CGFloat = 92
        for section in sections {
            if !section.title.isEmpty, headerIdx < headerLabels.count {
                headerLabels[headerIdx].frame = CGRect(x: 4, y: y + 6, width: rowW - 8,
                                                       height: DownloadOptionsView.headerHeight - 6)
                headerIdx += 1
                y += DownloadOptionsView.headerHeight
            }
            for _ in section.rows {
                guard btnIdx < rowButtons.count else { break }
                let btn = rowButtons[btnIdx]
                btn.frame = CGRect(x: 0, y: y, width: rowW, height: DownloadOptionsView.rowHeight - 4)
                let h = btn.bounds.height
                // name | detail | mark, the last two right-anchored
                rowNameLabels[btnIdx].frame = CGRect(x: 12, y: 0,
                                                     width: max(0, rowW - markW - detailW - 20), height: h)
                rowDetailLabels[btnIdx].frame = CGRect(x: rowW - markW - detailW - 4, y: 0,
                                                       width: detailW, height: h)
                rowMarkLabels[btnIdx].frame = CGRect(x: rowW - markW - 6, y: 0, width: markW, height: h)
                y += DownloadOptionsView.rowHeight
                btnIdx += 1
            }
            y += 6
        }
        scroller.contentSize = CGSize(width: rowW, height: y)

        let footY = cardH - DownloadOptionsView.footerHeight
        confirmBtn.frame = CGRect(x: pad, y: footY, width: cardW - pad * 2 - 86, height: 42)
        cancelBtn.frame = CGRect(x: cardW - pad - 80, y: footY, width: 80, height: 42)
    }

    // MARK: - Selection

    @objc private func rowTapped(_ sender: UIButton) {
        let idx = sender.tag
        guard idx >= 0, idx < rowIndexPaths.count else { return }
        let path = rowIndexPaths[idx]
        apply(section: path.section, row: path.row)
        refreshSelectionMarks()
        notifyChange()
    }

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

    // The selected row in each section is tinted and ticked; a row that carries its own mark
    // (already downloaded / the Settings default) keeps showing it when it isn't selected.
    private func refreshSelectionMarks() {
        for (i, path) in rowIndexPaths.enumerated() {
            let isSelected = selection[path.section].contains(path.row)
            let row = sections[path.section].rows[path.row]
            rowButtons[i].backgroundColor = isSelected
                ? Theme.accent.withAlphaComponent(0.28)
                : DownloadOptionsView.rowBG
            rowMarkLabels[i].text = isSelected ? "\u{2713}" : row.mark
        }
    }

    // MARK: - Actions

    @objc private func confirmTapped() {
        let picked = selection.map { Array($0).sorted() }
        let handler = onConfirm
        onConfirm = nil                  // a double tap must not fire two downloads
        dismiss()
        handler?(picked)
    }

    @objc private func cancelTapped() {
        onConfirm = nil
        dismiss()
    }
}
