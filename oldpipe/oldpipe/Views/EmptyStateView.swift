import UIKit

// MARK: - EmptyStateView
// A page with nothing to list yet: a glyph on a faint disc, a title, a line of explanation and an
// optional button. Full-size over its table and clear, so it places its own content:
//   regular — centred in the space above the mini player bar (Home's feed with no channels)
//   compact — a smaller block near the top, which stays clear of the keyboard on a 3.5" iPhone
//             (Search, whose field usually has the keyboard up)

final class EmptyStateView: UIView {
    enum Mark { case logo, search }

    private let mark: EmptyStateMarkView
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private var button: UIButton?
    private let compact: Bool
    var onButton: (() -> Void)?

    private static let buttonSize = CGSize(width: 200, height: 44)
    private static let miniPlayerH: CGFloat = 60

    init(mark kind: Mark, title: String, body: String, compact: Bool = false,
         buttonTitle: String? = nil, buttonImage: UIImage? = nil) {
        mark = EmptyStateMarkView(kind)
        self.compact = compact
        super.init(frame: .zero)
        backgroundColor = .clear
        autoresizingMask = iPadFlexWidthHeight
        addSubview(mark)

        titleLabel.backgroundColor = .clear
        titleLabel.textColor = UIColor(white: 0.95, alpha: 1)
        titleLabel.font = UIFont.boldSystemFont(ofSize: compact ? 18 : 20)
        titleLabel.textAlignment = .center
        addSubview(titleLabel)

        bodyLabel.backgroundColor = .clear
        bodyLabel.textColor = UIColor(white: 0.55, alpha: 1)
        bodyLabel.font = UIFont.systemFont(ofSize: compact ? 14 : 15)
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0
        addSubview(bodyLabel)
        setText(title: title, body: body)

        if let t = buttonTitle {
            let b = UIButton(type: .custom)
            b.layer.cornerRadius = 6   // no clipsToBounds: the layer's own background rounds
            b.backgroundColor = Theme.accent
            b.setImage(buttonImage, for: .normal)
            b.setTitle(t, for: .normal)
            b.setTitleColor(.white, for: .normal)
            b.setTitleColor(UIColor(white: 1, alpha: 0.6), for: .highlighted)
            b.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
            if buttonImage != nil {
                // 8pt between the glyph and the title, the pair still centred as one.
                b.imageEdgeInsets = UIEdgeInsets(top: 0, left: -4, bottom: 0, right: 4)
                b.titleEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: -4)
            }
            b.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
            addSubview(b)
            button = b
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func setText(title: String, body: String) {
        titleLabel.text = title
        bodyLabel.text = body
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let textW = min(w - 64, 280)
        let markS: CGFloat = compact ? 56 : 88
        let markGap: CGFloat = compact ? 14 : 20
        let titleH = ceil(titleLabel.font.lineHeight)
        let bodyH = ceil(bodyLabel.sizeThatFits(CGSize(width: textW, height: .greatestFiniteMagnitude)).height)
        let btn = EmptyStateView.buttonSize
        var total = markS + markGap + titleH + 6 + bodyH
        if button != nil { total += 28 + btn.height }

        var y: CGFloat
        if compact {
            y = 20
        } else {
            // Centred above the mini player bar, then lifted a little: dead centre reads low.
            let avail = bounds.height - EmptyStateView.miniPlayerH
            y = max(16, floor((avail - total) / 2) - 16)
        }
        mark.frame = CGRect(x: floor((w - markS) / 2), y: y, width: markS, height: markS)
        y += markS + markGap
        titleLabel.frame = CGRect(x: floor((w - textW) / 2), y: y, width: textW, height: titleH)
        y += titleH + 6
        bodyLabel.frame = CGRect(x: floor((w - textW) / 2), y: y, width: textW, height: bodyH)
        y += bodyH + 28
        button?.frame = CGRect(x: floor((w - btn.width) / 2), y: y, width: btn.width, height: btn.height)
    }

    @objc private func buttonTapped() { onButton?() }
}

// The glyph in the accent colour on a faint disc, drawn rather than loaded so it needs no image
// asset and stays sharp at any size.
private final class EmptyStateMarkView: UIView {
    private let kind: EmptyStateView.Mark

    init(_ kind: EmptyStateView.Mark) {
        self.kind = kind
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func draw(_ rect: CGRect) {
        let s = min(bounds.width, bounds.height)
        UIColor(white: 1, alpha: 0.06).setFill()
        UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: s, height: s)).fill()
        Theme.accent.setFill()
        Theme.accent.setStroke()
        switch kind {
        case .logo: drawLogo(s)
        case .search: drawSearch(s)
        }
    }

    // The play glyph from the app icon. The icon SVG (assets/oldpipe_icon_ios.svg) draws it in a
    // 192-unit box whose disc spans 8...184; map that disc onto ours.
    private func drawLogo(_ s: CGFloat) {
        let k = s / 176
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { return CGPoint(x: (x - 8) * k, y: (y - 8) * k) }
        let glyph = UIBezierPath()
        glyph.move(to: p(62.04, 154.85))
        glyph.addLine(to: p(79.89, 143.47))
        glyph.addLine(to: p(80.26, 68.07))
        glyph.addLine(to: p(126.18, 95.33))
        glyph.addLine(to: p(92.95, 114.50))
        glyph.addLine(to: p(92.95, 136.42))
        glyph.addLine(to: p(161.98, 95.33))
        glyph.addLine(to: p(61.94, 36.54))
        glyph.close()
        glyph.fill()
    }

    // A magnifier with Phosphor's proportions (lens r 80 at 112,112 and a handle out to 224,224
    // in a 256-unit box), set in the middle half of the disc.
    private func drawSearch(_ s: CGFloat) {
        let k = s * 0.5 / 256
        let o = s * 0.25
        func p(_ v: CGFloat) -> CGFloat { return o + v * k }
        let line = 24 * k
        let lens = UIBezierPath(ovalIn: CGRect(x: p(32), y: p(32), width: 160 * k, height: 160 * k))
        lens.lineWidth = line
        lens.stroke()
        let handle = UIBezierPath()
        handle.move(to: CGPoint(x: p(168.57), y: p(168.57)))
        handle.addLine(to: CGPoint(x: p(224), y: p(224)))
        handle.lineWidth = line
        handle.lineCapStyle = .round
        handle.stroke()
    }
}
