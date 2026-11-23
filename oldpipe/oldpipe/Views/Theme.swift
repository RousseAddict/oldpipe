import UIKit

// App-wide palette. Previously every view controller carried its own private copy of the
// accent constant, so a tweak meant finding eleven literals spread over ten files.
enum Theme {
    // YouTube red — tab underlines, progress fills, switches, primary buttons.
    static let accent = UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 1)

    // A tab strip's titles (the video page's Related / Comments, a channel's Videos / Shorts /
    // Playlists / About): the selected one white over the red underline, the others grey.
    static let tabSelected = UIColor(white: 0.95, alpha: 1)
    static let tabIdle = UIColor(white: 0.55, alpha: 1)

    // Row accessories, drawn by the app so a list looks the same on every iOS. Before iOS 7
    // the stock chevron is a dark grey that vanishes on these near-black rows, and the stock
    // check (blue on every iOS here) matched nothing else in the app.

    // "Opens a page": a grey chevron. A new view per call: a view has one superview, so each
    // cell needs its own.
    static func chevron() -> UIView {
        return ChevronView(frame: CGRect(x: 0, y: 0, width: 12, height: 20))
    }

    // "This one is in": a red tick, as a menu marks the choice in force.
    static func checkmark() -> UIView {
        let l = UILabel(frame: CGRect(x: 0, y: 0, width: 22, height: 22))
        l.backgroundColor = .clear
        l.text = "\u{2713}"
        l.textColor = accent
        l.font = UIFont.boldSystemFont(ofSize: 17)
        l.textAlignment = .center
        return l
    }
}

// Two strokes, the shape of iOS 7's disclosure chevron, in a grey these dark rows can show.
private final class ChevronView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        let midX = bounds.width / 2, midY = bounds.height / 2
        let p = UIBezierPath()
        p.move(to: CGPoint(x: midX - 3, y: midY - 6.5))
        p.addLine(to: CGPoint(x: midX + 3.5, y: midY))
        p.addLine(to: CGPoint(x: midX - 3, y: midY + 6.5))
        p.lineWidth = 2
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        UIColor(white: 0.5, alpha: 1).setStroke()
        p.stroke()
    }
}
