import UIKit

// MARK: - VideoRowCell
// Shared list cell for videos (Search, Home, Channel): a 16:9 thumbnail with a
// duration badge, a 2-line title, and a subtitle of "channel • date • views".

class VideoRowCell: UITableViewCell {

    static let reuseId = "VideoRowCell"
    static let rowHeight: CGFloat = 80

    private let thumb = UIImageView()
    private let durationLabel = UILabel()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private var currentURL = ""

    // Watched-progress bar (red fill over a dark track) pinned to the thumbnail's bottom
    // edge — hidden by default (fraction 0), so only screens that set it (History) show it.
    private let progressTrack = UIView()
    private let progressFill = UIView()
    var playedFraction: CGFloat = 0 { didSet { setNeedsLayout() } }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)

        thumb.backgroundColor = UIColor(white: 0.15, alpha: 1)
        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = 4
        thumb.layer.shouldRasterize = true
        thumb.layer.rasterizationScale = UIScreen.main.scale
        contentView.addSubview(thumb)

        durationLabel.backgroundColor = UIColor(white: 0, alpha: 0.78)
        durationLabel.textColor = .white
        durationLabel.font = UIFont.boldSystemFont(ofSize: 11)
        durationLabel.textAlignment = .center
        durationLabel.layer.cornerRadius = 3
        durationLabel.clipsToBounds = true
        contentView.addSubview(durationLabel)

        titleLabel.backgroundColor = .clear
        titleLabel.textColor = UIColor(white: 0.95, alpha: 1)
        titleLabel.font = UIFont.systemFont(ofSize: 14)
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)

        subtitleLabel.backgroundColor = .clear
        subtitleLabel.textColor = UIColor(white: 0.55, alpha: 1)
        subtitleLabel.font = UIFont.systemFont(ofSize: 12)
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
        subtitleLabel.text = [video.channelName, video.displayPublished, video.viewCountText]
            .filter { !$0.isEmpty }.joined(separator: " • ")

        if video.durationText.isEmpty {
            durationLabel.isHidden = true
        } else {
            durationLabel.isHidden = false
            durationLabel.text = "  \(video.durationText)  "
        }

        thumb.image = nil
        currentURL = video.thumbnailURL
        let url = video.thumbnailURL
        AsyncImageView.loadCell(url: url) { [weak self] img in
            guard let self = self, self.currentURL == url else { return }
            self.thumb.image = img
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = contentView.bounds.width
        let pad: CGFloat = 8
        let tW: CGFloat = 120, tH: CGFloat = 64

        thumb.frame = CGRect(x: pad, y: pad, width: tW, height: tH)

        durationLabel.sizeToFit()
        let dW = durationLabel.bounds.width
        let dH: CGFloat = 16
        durationLabel.frame = CGRect(x: pad + tW - dW - 4, y: pad + tH - dH - 4, width: dW, height: dH)

        let textX = pad + tW + 10
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
