import UIKit

// MARK: - MiniPlayerBar
// Persistent bar pinned to the bottom of the app window (added in AppDelegate). It is a thin
// view onto VideoPlayer.shared: it polls the singleton every 0.5s and mirrors the current
// title / thumbnail / play state. Tapping the title area reopens VideoPlayerVC; the close
// button tears playback down. It auto-hides when there is no active video or when a
// VideoPlayerVC is already on screen (avoids a double player).

class MiniPlayerBar: UIView {

    static let barHeight: CGFloat = 60

    // Callbacks wired up by AppDelegate.
    var onOpen: ((Video) -> Void)?
    var navProvider: (() -> UINavigationController?)?

    private let thumbView = AsyncImageView()
    private let titleLabel = UILabel()
    private let channelLabel = UILabel()
    private let playPauseBtn = UIButton(type: .custom)
    private let closeBtn = UIButton(type: .custom)
    private let openBtn = UIButton(type: .custom)
    private let progressLine = UIView()

    private var shownVideoId: String?
    private var pollTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildUI()
        startPolling()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - UI

    private func buildUI() {
        backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)
        isHidden = true

        // top hairline + red progress line
        let hairline = UIView(frame: CGRect(x: 0, y: 0, width: bounds.width, height: 0.5))
        hairline.backgroundColor = UIColor(white: 1, alpha: 0.15)
        hairline.autoresizingMask = iPadFlexWidth
        addSubview(hairline)

        progressLine.frame = CGRect(x: 0, y: 0, width: 0, height: 2)
        progressLine.backgroundColor = UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 1)
        addSubview(progressLine)

        // thumbnail (16:9, full height)
        thumbView.frame = CGRect(x: 0, y: 0, width: 106, height: MiniPlayerBar.barHeight)
        thumbView.contentMode = .scaleAspectFill
        thumbView.clipsToBounds = true
        thumbView.backgroundColor = UIColor(white: 0.2, alpha: 1)
        addSubview(thumbView)

        let textX: CGFloat = 106 + 10
        let textW = bounds.width - textX - 88

        titleLabel.frame = CGRect(x: textX, y: 10, width: textW, height: 20)
        titleLabel.backgroundColor = .clear
        titleLabel.textColor = .white
        titleLabel.font = UIFont.boldSystemFont(ofSize: 14)
        addSubview(titleLabel)

        channelLabel.frame = CGRect(x: textX, y: 32, width: textW, height: 16)
        channelLabel.backgroundColor = .clear
        channelLabel.textColor = UIColor(white: 0.7, alpha: 1)
        channelLabel.font = UIFont.systemFont(ofSize: 12)
        addSubview(channelLabel)

        // play / pause
        playPauseBtn.frame = CGRect(x: bounds.width - 88, y: 0, width: 44, height: MiniPlayerBar.barHeight)
        playPauseBtn.backgroundColor = .clear
        playPauseBtn.setImage(UIImage(named: "play"), for: .normal)
        playPauseBtn.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        addSubview(playPauseBtn)

        // close
        closeBtn.frame = CGRect(x: bounds.width - 44, y: 0, width: 44, height: MiniPlayerBar.barHeight)
        closeBtn.backgroundColor = .clear
        closeBtn.setImage(UIImage(named: "close"), for: .normal)
        closeBtn.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        addSubview(closeBtn)

        // transparent tap target over thumb + text (NO gesture recognizer — see CLAUDE.md)
        openBtn.frame = CGRect(x: 0, y: 0, width: bounds.width - 88, height: MiniPlayerBar.barHeight)
        openBtn.backgroundColor = .clear
        openBtn.addTarget(self, action: #selector(openTapped), for: .touchUpInside)
        addSubview(openBtn)

        bringSubviewToFront(playPauseBtn)
        bringSubviewToFront(closeBtn)
    }

    #if IOS8_TARGET
    // iPad: the bar's flexibleWidth mask stretches its width on rotation, but the fixed-frame
    // children (right-anchored buttons + the text block that fills to them) have to be
    // repositioned for the new width. Compiled only into the iOS 8 build — the iOS 6/7 build
    // never resizes the bar (portrait-locked window) so it keeps its original fixed layout.
    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let textX: CGFloat = 106 + 10
        let textW = max(0, w - textX - 88)
        titleLabel.frame = CGRect(x: textX, y: 10, width: textW, height: 20)
        channelLabel.frame = CGRect(x: textX, y: 32, width: textW, height: 16)
        playPauseBtn.frame = CGRect(x: w - 88, y: 0, width: 44, height: MiniPlayerBar.barHeight)
        closeBtn.frame = CGRect(x: w - 44, y: 0, width: 44, height: MiniPlayerBar.barHeight)
        openBtn.frame = CGRect(x: 0, y: 0, width: w - 88, height: MiniPlayerBar.barHeight)
    }
    #endif

    // MARK: - Polling

    private func startPolling() {
        let t = Timer(timeInterval: 0.5, target: BlockProxyBar { [weak self] in self?.poll() },
                      selector: #selector(BlockProxyBar.fire), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func poll() {
        let sp = VideoPlayer.shared
        let top = navProvider?()?.topViewController
        let topIsPlayer = (top is VideoPlayerVC) || (top is ShortsPlayerVC)
        guard let video = sp.currentVideo, !topIsPlayer else {
            if !isHidden { isHidden = true }
            return
        }
        if isHidden { isHidden = false }

        if shownVideoId != video.id {
            shownVideoId = video.id
            titleLabel.text = video.title
            channelLabel.text = video.channelName
            if !video.thumbnailURL.isEmpty { thumbView.load(url: video.thumbnailURL) }
        }

        playPauseBtn.setImage(UIImage(named: sp.isPlaying ? "pause" : "play"), for: .normal)

        let dur = sp.durationSeconds
        let frac = dur > 0 ? CGFloat(sp.currentSeconds / dur) : 0
        progressLine.frame = CGRect(x: 0, y: 0, width: bounds.width * max(0, min(1, frac)), height: 2)
    }

    // MARK: - Actions

    @objc private func playPauseTapped() { VideoPlayer.shared.togglePlayPause(); poll() }

    @objc private func closeTapped() {
        VideoPlayer.shared.stop()
        shownVideoId = nil
        isHidden = true
    }

    @objc private func openTapped() {
        guard let video = VideoPlayer.shared.currentVideo else { return }
        onOpen?(video)
    }
}

// Timer target wrapper so the repeating Timer doesn't retain the bar via a selector.
private class BlockProxyBar: NSObject {
    let block: () -> Void
    init(_ b: @escaping () -> Void) { block = b }
    @objc func fire() { block() }
}
