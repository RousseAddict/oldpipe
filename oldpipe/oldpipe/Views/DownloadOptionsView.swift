import UIKit

// MARK: - DownloadOptionsView
//
// The "Download" modal: a card over a dimmed backdrop, built from a list of SECTIONS of
// single-select rows. Quality is the only section populated today; Format (video vs audio-only)
// and Captions are the next two, and they slot in by appending another Section — the layout and
// hit-testing walk the array and know nothing about what a section means.
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

// How a section's rows behave. The modal mixes both: the download target is one choice spread
// over two groups, while caption languages are independent ticks in the same sheet.
enum DownloadOptionMode {
    // Part of the modal-wide SINGLE choice: ticking a row here clears every other exclusive
    // section too, so "720p" and "Audio only" cannot both be chosen.
    case exclusive
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
    private let confirmTitle: String
    private var onConfirm: (([[Int]]) -> Void)?

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
    private var scroller = UIScrollView()

    // MARK: - Presentation

    // Add to `host` (the presenting VC's view) and fade in. Sized from the host's bounds and
    // flexible in both axes, so the iOS 8 build's iPad rotation reflows it for free and the
    // portrait-locked iOS 6/7 builds compile the mask to [] exactly as every other view does.
    @discardableResult
    static func present(in host: UIView, title: String, sections: [DownloadOptionSection],
                        confirmTitle: String,
                        onConfirm: @escaping ([[Int]]) -> Void) -> DownloadOptionsView {
        let v = DownloadOptionsView(frame: host.bounds, title: title, sections: sections,
                                    confirmTitle: confirmTitle, onConfirm: onConfirm)
        v.autoresizingMask = iPadFlexWidthHeight
        v.alpha = 0
        host.addSubview(v)
        UIView.animate(withDuration: 0.18) { v.alpha = 1 }
        return v
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
        switch sections[path.section].mode {
        case .exclusive:
            // Clear every exclusive section, not just this one — the choice spans them.
            for i in sections.indices where sections[i].mode == .exclusive {
                selection[i].removeAll()
            }
            selection[path.section] = [path.row]
        case .multi:
            if selection[path.section].contains(path.row) {
                selection[path.section].remove(path.row)
            } else {
                selection[path.section].insert(path.row)
            }
        }
        refreshSelectionMarks()
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
