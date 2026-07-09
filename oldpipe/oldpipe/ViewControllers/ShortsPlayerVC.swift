import UIKit
import AVFoundation

// MARK: - ShortsPlayerVC
// TikTok-style full-screen vertical player for Shorts. A paging UIScrollView stacks one
// full-screen page per short; swiping down plays the next one (staying portrait). Only the
// single shared AVPlayer (VideoPlayer.shared) is ever active — off-screen pages show a static
// thumbnail — so memory stays flat on the iPhone 4S. Tapping toggles play/pause. When a short
// plays to the end the shared player's autoplay queue advances to the next (onAdvance scrolls
// this VC to follow); it stops at the last short (no loop). Leaving the screen stops playback.

class ShortsPlayerVC: UIViewController, UIScrollViewDelegate {

    private let shorts: [Video]
    private var currentIndex = 0

    private var scrollView: UIScrollView!
    private var backBtn: UIButton!
    private var pages: [Int: ShortPageView] = [:]   // recycled window around currentIndex
    private var pageW: CGFloat = 0
    private var pageH: CGFloat = 0

    private var didSetup = false
    private var readyTimer: Timer?

    // Prefetch cache (option A): the *network* part of resolving the next short (the slow
    // innertube getStreams call) is done ahead of time and cached here by video id. It stores
    // a PreparedStream (raw remote URL / local file), NOT a proxy-wrapped URL — wrapping via
    // StreamProxy bumps its generation and would abort the currently-playing iOS-6 stream, so
    // that final step is deferred to the moment of the swipe (finalize).
    private var prepared: [String: PreparedStream] = [:]
    private var preparing: Set<String> = []

    private var sp: VideoPlayer { VideoPlayer.shared }

    init(shorts: [Video], startIndex: Int) {
        self.shorts = shorts
        self.currentIndex = max(0, min(startIndex, shorts.count - 1))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didSetup else { return }
        didSetup = true
        setupUI()
        materializePages(around: currentIndex)
        playShort(at: currentIndex)
        // The frontmost VC owns onAdvance (last-writer-wins). When the shared player's queue
        // auto-advances at end-of-video, follow it by scrolling to the new short's page.
        sp.onAdvance = { [weak self] video in self?.handleAutoAdvance(video) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        sp.onAdvance = nil
        readyTimer?.invalidate(); readyTimer = nil
        // Decision E: stop playback when leaving the shorts player.
        sp.stop()
        // Restore the default gravity so a subsequently opened normal video isn't cropped.
        sp.layer.videoGravity = AVLayerVideoGravity.resizeAspect
    }

    private func setupUI() {
        pageW = view.bounds.width
        pageH = view.bounds.height

        scrollView = UIScrollView(frame: view.bounds)
        scrollView.backgroundColor = .black
        scrollView.isPagingEnabled = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentSize = CGSize(width: pageW, height: pageH * CGFloat(shorts.count))
        scrollView.delegate = self
        scrollView.autoresizingMask = iPadFlexWidthHeight
        // iOS 7+ auto-adjusts a scroll view's insets for the status bar; disable it so the
        // full-page frames aren't shifted. The selector doesn't exist on iOS 6 (no auto
        // adjustment there) so guard with respondsToSelector to avoid a crash.
        if responds(to: Selector(("setAutomaticallyAdjustsScrollViewInsets:"))) {
            setValue(false, forKey: "automaticallyAdjustsScrollViewInsets")
        }
        view.addSubview(scrollView)
        scrollView.setContentOffset(CGPoint(x: 0, y: pageH * CGFloat(currentIndex)), animated: false)

        // The nav bar is hidden for the full-screen player, so add our own back affordance.
        // Fixed to view (not the scroll view) so it stays put while pages scroll. Uses the
        // bundled close (X) icon on a rounded semi-transparent disc. Shown only while paused
        // (see updateBackVisibility) — during playback it stays out of the way.
        backBtn = UIButton(type: .custom)
        backBtn.frame = CGRect(x: 12, y: 28, width: 44, height: 44)
        backBtn.backgroundColor = UIColor(white: 0, alpha: 0.45)
        backBtn.layer.cornerRadius = 22
        backBtn.setImage(UIImage(named: "close"), for: .normal)
        backBtn.isHidden = true
        backBtn.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        view.addSubview(backBtn)
    }

    // Back button is visible only while playback is paused.
    private func updateBackVisibility() {
        backBtn.isHidden = sp.isPlaying
    }

    @objc private func backTapped() {
        navigationController?.popViewController(animated: true)
    }

    private func pageFrame(_ i: Int) -> CGRect {
        return CGRect(x: 0, y: pageH * CGFloat(i), width: pageW, height: pageH)
    }

    // Keep only [center-1 ... center+1] materialized; remove the rest to bound memory.
    private func materializePages(around center: Int) {
        let lo = max(0, center - 1)
        let hi = min(shorts.count - 1, center + 1)
        for i in lo...hi where pages[i] == nil {
            let p = ShortPageView(frame: pageFrame(i))
            p.configure(shorts[i])
            p.onTap = { [weak self] in self?.toggleTap() }
            scrollView.addSubview(p)
            pages[i] = p
        }
        for (i, p) in pages where i < lo || i > hi {
            p.removeFromSuperview()
            pages[i] = nil
        }
    }

    // MARK: - Playback

    // Load + play the short at index using the shared player. Sets the autoplay queue so the
    // singleton can auto-advance at end-of-video. No-op reload if it's already the active item.
    private func playShort(at index: Int) {
        guard index >= 0, index < shorts.count else { return }
        currentIndex = index
        let video = shorts[index]
        sp.setQueue(shorts, startIndex: index)

        if sp.isActive(video.id) {
            attachLayerToPage(index)
            sp.play()
            pages[index]?.setPaused(false)
            updateBackVisibility()
            prefetchNext(after: index)
            return
        }

        pages[index]?.setPaused(false)
        backBtn.isHidden = true   // we intend to play; back shows only when the user pauses

        // Use a prefetched preparation if we have one (removes the network round-trip on the
        // swipe); otherwise prepare now. Either way, finalize (proxy-wrap on iOS 6) at play time.
        let startLoad: (PreparedStream) -> Void = { [weak self] prep in
            guard let self = self, self.currentIndex == index else { return }
            guard let r = StreamResolver.finalize(prep) else {
                self.pages[index]?.showUnavailable()
                self.backBtn.isHidden = false
                return
            }
            // Shorts always start from the beginning (resume: 0).
            self.sp.load(video: video, url: r.url, isLocal: r.isLocal, resume: 0, artwork: nil)
            self.sp.layer.videoGravity = AVLayerVideoGravity.resizeAspectFill   // fill the portrait page
            self.attachLayerToPage(index)
            self.pollUntilReady()
            self.prefetchNext(after: index)
        }

        if let prep = prepared[video.id] {
            startLoad(prep)
        } else {
            StreamResolver.prepare(video) { [weak self] prep in
                guard let self = self, self.currentIndex == index else { return }
                guard let prep = prep else {
                    self.pages[index]?.showUnavailable()
                    self.backBtn.isHidden = false
                    return
                }
                self.prepared[video.id] = prep
                startLoad(prep)
            }
        }
    }

    // Option A: prefetch the next short's stream metadata so the swipe doesn't pay for the
    // innertube round-trip. Only the network step runs here (StreamResolver.prepare) — no
    // proxy route is created, so the currently-playing iOS-6 stream is untouched.
    private func prefetchNext(after index: Int) {
        let n = index + 1
        guard n < shorts.count else { return }
        let video = shorts[n]
        guard prepared[video.id] == nil, !preparing.contains(video.id) else { return }
        preparing.insert(video.id)
        StreamResolver.prepare(video) { [weak self] prep in
            guard let self = self else { return }
            self.preparing.remove(video.id)
            if let prep = prep { self.prepared[video.id] = prep }
        }
    }

    // VC-side readiness poll for a user-initiated load (mirrors VideoPlayer.waitForReadyThenPlay,
    // which the singleton uses for auto-advance). 0.25s ticks, 20s ceiling.
    private func pollUntilReady() {
        readyTimer?.invalidate()
        var count = 0
        let t = Timer(timeInterval: 0.25, target: ShortsTickProxy { [weak self] in
            guard let self = self else { return }
            count += 1
            if self.sp.isReady {
                self.readyTimer?.invalidate(); self.readyTimer = nil
                self.sp.applyResumeAndPlay()
            } else if self.sp.isFailed || count > 80 {
                self.readyTimer?.invalidate(); self.readyTimer = nil
            }
        }, selector: #selector(ShortsTickProxy.fire), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        readyTimer = t
    }

    // Re-parent the shared AVPlayerLayer into the given page's player container (adding a
    // layer to a new superlayer removes it from the old page automatically).
    private func attachLayerToPage(_ index: Int) {
        guard let page = pages[index] else { return }
        page.attachPlayerLayer(sp.layer)
    }

    private func toggleTap() {
        sp.togglePlayPause()
        pages[currentIndex]?.setPaused(!sp.isPlaying)
        updateBackVisibility()
    }

    // The shared player's queue advanced at end-of-video: scroll to follow. The singleton has
    // already loaded + will play the next short (its own waitForReadyThenPlay), so here we only
    // move the UI and re-attach the layer.
    private func handleAutoAdvance(_ video: Video) {
        guard let idx = shorts.firstIndex(where: { $0.id == video.id }) else { return }
        currentIndex = idx
        materializePages(around: idx)
        scrollView.setContentOffset(CGPoint(x: 0, y: pageH * CGFloat(idx)), animated: true)
        attachLayerToPage(idx)
        pages[idx]?.setPaused(false)
        backBtn.isHidden = true
        prefetchNext(after: idx)
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settleToPage()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        settleToPage()
    }

    private func settleToPage() {
        guard pageH > 0 else { return }
        let page = Int((scrollView.contentOffset.y / pageH).rounded())
        guard page >= 0, page < shorts.count else { return }
        materializePages(around: page)
        if page != currentIndex {
            playShort(at: page)
        }
    }
}

// MARK: - ShortPageView
// One full-screen page: a static thumbnail, a container that hosts the shared player layer
// when this page is active, bottom title/channel labels, and a center play glyph shown while
// paused. A transparent tap overlay (no gesture recognizer — iOS 6 conflict) toggles play.

private class ShortPageView: UIView {

    private let thumb = AsyncImageView()
    private let playerContainer = UIView()
    private let titleLabel = UILabel()
    private let channelLabel = UILabel()
    private let playGlyph = UIImageView()
    private let unavailableLabel = UILabel()
    private let tapView = ShortTapView()
    var onTap: (() -> Void)? {
        get { tapView.onTap }
        set { tapView.onTap = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black

        thumb.frame = bounds
        thumb.autoresizingMask = iPadFlexWidthHeight
        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.backgroundColor = UIColor(white: 0.1, alpha: 1)
        addSubview(thumb)

        playerContainer.frame = bounds
        playerContainer.autoresizingMask = iPadFlexWidthHeight
        playerContainer.backgroundColor = .clear
        addSubview(playerContainer)

        titleLabel.backgroundColor = .clear
        titleLabel.textColor = .white
        titleLabel.font = UIFont.boldSystemFont(ofSize: 15)
        titleLabel.numberOfLines = 2
        addSubview(titleLabel)

        channelLabel.backgroundColor = .clear
        channelLabel.textColor = UIColor(white: 0.85, alpha: 1)
        channelLabel.font = UIFont.systemFont(ofSize: 13)
        addSubview(channelLabel)

        playGlyph.image = UIImage(named: "play")
        playGlyph.contentMode = .scaleAspectFit
        playGlyph.alpha = 0.85
        playGlyph.isHidden = true
        addSubview(playGlyph)

        unavailableLabel.backgroundColor = .clear
        unavailableLabel.textColor = UIColor(white: 0.7, alpha: 1)
        unavailableLabel.font = UIFont.systemFont(ofSize: 15)
        unavailableLabel.textAlignment = .center
        unavailableLabel.text = "Short unavailable"
        unavailableLabel.isHidden = true
        addSubview(unavailableLabel)

        tapView.frame = bounds
        tapView.autoresizingMask = iPadFlexWidthHeight
        tapView.backgroundColor = .clear
        addSubview(tapView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(_ v: Video) {
        titleLabel.text = v.title
        channelLabel.text = v.channelName
        thumb.image = nil
        if !v.thumbnailURL.isEmpty { thumb.load(url: v.thumbnailURL) }
    }

    // Host the shared AVPlayerLayer, sized to fill the page.
    func attachPlayerLayer(_ layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = playerContainer.bounds
        playerContainer.layer.insertSublayer(layer, at: 0)
        CATransaction.commit()
    }

    func setPaused(_ paused: Bool) {
        playGlyph.isHidden = !paused
    }

    func showUnavailable() {
        unavailableLabel.isHidden = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        let pad: CGFloat = 14
        titleLabel.frame = CGRect(x: pad, y: h - 76, width: w - pad * 2, height: 40)
        channelLabel.frame = CGRect(x: pad, y: h - 34, width: w - pad * 2, height: 18)
        let g: CGFloat = 72
        playGlyph.frame = CGRect(x: (w - g) / 2, y: (h - g) / 2, width: g, height: g)
        unavailableLabel.frame = CGRect(x: 0, y: (h - 24) / 2, width: w, height: 24)
    }
}

// MARK: - ShortTapView
// Transparent tap target. Uses touchesEnded/tapCount (iOS 2+) rather than a
// UITapGestureRecognizer (which conflicts with button taps on iOS 6). Sitting inside a
// paging scroll view, a quick tap fires onTap while a drag is claimed by the scroll view's
// pan recognizer (which cancels these touches), so scrolling still works.
private class ShortTapView: UIView {
    var onTap: (() -> Void)?
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        guard let t = touches.first, t.tapCount >= 1 else { return }
        onTap?()
    }
}

// Timer target wrapper so the repeating readiness Timer doesn't retain the VC via a selector.
private class ShortsTickProxy: NSObject {
    let block: () -> Void
    init(_ b: @escaping () -> Void) { block = b }
    @objc func fire() { block() }
}
