import UIKit

// MARK: - EmptyStateView
// A page with nothing to list yet: a glyph on a faint disc, a title, a line of explanation and an
// optional button. Full-size over its table and clear, so it places its own content:
//   regular — centred in the space above the mini player bar (Home's feed with no channels, and
//             the library pages: Subscriptions, Playlists, Downloads, History)
//   compact — a smaller block near the top, which stays clear of the keyboard on a 3.5" iPhone
//             (Search, whose field usually has the keyboard up)

final class EmptyStateView: UIView {
    enum Mark { case logo, search, subscriptions, playlist, download, history }

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
        if kind == .logo { drawLogo(s) } else { drawGlyph(s) }
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

    // Every other mark is a Phosphor icon traced from its 256-unit artboard (the outline
    // weight's centre lines, stroked 24 wide with round ends and corners), set in the middle
    // half of the disc. The same family as the bundled toolbar icons.
    private func drawGlyph(_ s: CGFloat) {
        let k = s * 0.5 / 256
        let o = s * 0.25
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { return CGPoint(x: o + x * k, y: o + y * k) }
        let path = UIBezierPath()
        path.lineWidth = 24 * k
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        func line(_ pts: [(CGFloat, CGFloat)]) {
            path.move(to: p(pts[0].0, pts[0].1))
            for q in pts.dropFirst() { path.addLine(to: p(q.0, q.1)) }
        }
        // Degrees, clockwise on screen unless `cw` is false. Moves to the start first, or the
        // arc would be joined to the previous stroke by a line.
        func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ from: CGFloat, _ to: CGFloat, cw: Bool = true) {
            let a = from * .pi / 180
            path.move(to: p(cx + r * cos(a), cy + r * sin(a)))
            path.addArc(withCenter: p(cx, cy), radius: r * k, startAngle: a,
                        endAngle: to * .pi / 180, clockwise: cw)
        }
        switch kind {
        case .search:          // magnifying-glass
            arc(112, 112, 80, 0, 360)
            line([(168.57, 168.57), (224, 224)])
        case .subscriptions:   // users
            arc(84, 108, 52, 0, 360)
            arc(84, 248, 88, -146.9, -33.1)
            arc(172, 108, 52, -111.8, 90)
            arc(172, 248, 88, -90, -33.1)
        case .playlist:        // playlist
            line([(40, 64), (216, 64)])
            line([(40, 128), (136, 128)])
            line([(40, 192), (136, 192)])
            line([(240, 160), (176, 200), (176, 120)])
            path.close()
        case .download:        // download-simple
            line([(128, 144), (128, 32)])
            line([(168, 104), (128, 144), (88, 104)])
            line([(216, 144), (216, 208), (40, 208), (40, 144)])
        case .history:         // clock-counter-clockwise
            line([(128, 80), (128, 128), (169.57, 152)])
            line([(72, 104), (32, 104), (32, 64)])
            arc(128, 128, 88, 133.34, -135, cw: false)
            path.addCurve(to: p(32, 104), controlPoint1: p(54, 77.69), controlPoint2: p(44, 88.07))
        case .logo:
            return
        }
        path.stroke()
    }
}
