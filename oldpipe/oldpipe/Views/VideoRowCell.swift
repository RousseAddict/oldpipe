import UIKit

// MARK: - VideoRowCell
// Shared list cell for videos (Search, Home, Channel): a 16:9 thumbnail with a
// duration badge, a 2-line title, and a subtitle of "channel • date • views".

class VideoRowCell: UITableViewCell {

    static let reuseId = "VideoRowCell"
    static let rowHeight: CGFloat = 80

    // The row's measures, fonts and subtitle, shared with the video page's Related list. That
    // list draws the same row out of plain views (it lives in the page's scroll view, not a
    // table), and reads these so the two can't drift apart again.
    static let pad: CGFloat = 8
    static let thumbSize = CGSize(width: 120, height: 64)
    static let textGap: CGFloat = 10
    static let thumbBG = UIColor(white: 0.15, alpha: 1)
    static let titleFont = UIFont.systemFont(ofSize: 14)
    static let titleColor = UIColor(white: 0.95, alpha: 1)
    static let subtitleFont = UIFont.systemFont(ofSize: 12)
    static let subtitleColor = UIColor(white: 0.55, alpha: 1)
    static let durationFont = UIFont.boldSystemFont(ofSize: 11)
    static let durationBG = UIColor(white: 0, alpha: 0.78)
    static let durationH: CGFloat = 16

    // "channel • date • views", the order every video list uses.
    static func subtitle(for video: Video) -> String {
        return [video.channelName, video.displayPublished, video.viewCountText]
            .filter { !$0.isEmpty }.joined(separator: " • ")
    }

    // AsyncImageView (not a bare UIImageView) so that reusing this cell CANCELS the
    // outgoing thumbnail request instead of just discarding its result — see
    // prepareForReuse. progressTrack is still added as a subview of it, which is fine:
    // AsyncImageView is a UIImageView subclass.
    private let thumb = AsyncImageView()
    private let durationLabel = UILabel()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    // Watched-progress bar (red fill over a dark track) pinned to the thumbnail's bottom
    // edge — hidden by default (fraction 0), so only screens that set it (History) show it.
    private let progressTrack = UIView()
    private let progressFill = UIView()
    var playedFraction: CGFloat = 0 { didSet { setNeedsLayout() } }

    required override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)

        thumb.backgroundColor = VideoRowCell.thumbBG
        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = 4
        thumb.layer.shouldRasterize = true
        thumb.layer.rasterizationScale = UIScreen.main.scale
        contentView.addSubview(thumb)

        durationLabel.backgroundColor = VideoRowCell.durationBG
        durationLabel.textColor = .white
        durationLabel.font = VideoRowCell.durationFont
        durationLabel.textAlignment = .center
        durationLabel.layer.cornerRadius = 3
        durationLabel.clipsToBounds = true
        // Rounded and clipped, so rasterized like the thumbnail — otherwise its corners are
        // rendered off-screen again on every frame of a scroll.
        durationLabel.layer.shouldRasterize = true
        durationLabel.layer.rasterizationScale = UIScreen.main.scale
        contentView.addSubview(durationLabel)

        titleLabel.backgroundColor = .clear
        titleLabel.textColor = VideoRowCell.titleColor
        titleLabel.font = VideoRowCell.titleFont
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)

        subtitleLabel.backgroundColor = .clear
        subtitleLabel.textColor = VideoRowCell.subtitleColor
        subtitleLabel.font = VideoRowCell.subtitleFont
        subtitleLabel.numberOfLines = 2
        contentView.addSubview(subtitleLabel)

        progressTrack.backgroundColor = UIColor(white: 0, alpha: 0.5)
        progressTrack.isHidden = true
        progressFill.backgroundColor = UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 1)
        progressTrack.addSubview(progressFill)
        thumb.addSubview(progressTrack)

        let sel = UIView()
        sel.backgroundColor = UIColor(white: 0.15, alpha: 1)
        selectedBackgroundView = sel
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(with video: Video) {
        playedFraction = 0   // reset for reuse; callers that want the bar set it after configure
        titleLabel.text = video.title
        subtitleLabel.text = VideoRowCell.subtitle(for: video)

        if video.durationText.isEmpty {
            durationLabel.isHidden = true
        } else {
            durationLabel.isHidden = false
            durationLabel.text = "  \(video.durationText)  "
        }

        // load() cancels whatever this cell was previously fetching and clears the image,
        // so no manual stale-URL guard is needed any more.
        thumb.load(url: video.thumbnailURL)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumb.cancel()
        thumb.image = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = contentView.bounds.width
        let pad = VideoRowCell.pad
        let tW = VideoRowCell.thumbSize.width, tH = VideoRowCell.thumbSize.height

        thumb.frame = CGRect(x: pad, y: pad, width: tW, height: tH)

        durationLabel.sizeToFit()
        let dW = durationLabel.bounds.width
        let dH = VideoRowCell.durationH
        durationLabel.frame = CGRect(x: pad + tW - dW - 4, y: pad + tH - dH - 4, width: dW, height: dH)

        let textX = pad + tW + VideoRowCell.textGap
        let textW = max(0, w - textX - pad)
        titleLabel.frame = CGRect(x: textX, y: pad, width: textW, height: 36)
        subtitleLabel.frame = CGRect(x: textX, y: pad + 38, width: textW, height: 32)

        if playedFraction > 0.01 {
            let barH: CGFloat = 3
            progressTrack.isHidden = false
            progressTrack.frame = CGRect(x: 0, y: tH - barH, width: tW, height: barH)
            progressFill.frame = CGRect(x: 0, y: 0, width: tW * min(1, playedFraction), height: barH)
            thumb.bringSubviewToFront(progressTrack)
        } else {
            progressTrack.isHidden = true
        }
    }
}
