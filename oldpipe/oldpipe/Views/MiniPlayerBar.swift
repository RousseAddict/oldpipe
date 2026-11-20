import UIKit
import AVFoundation

// MARK: - MiniPlayerBar
// Persistent bar pinned to the bottom of the app window (added in AppDelegate). It is a thin
// view onto VideoPlayer.shared: it polls the singleton every 0.5s and mirrors the current
// title / thumbnail / play state. Tapping the title area reopens VideoPlayerVC; the close
// button tears playback down. It auto-hides when there is no active video, and on the one
// page that already shows it — that video's own VideoPlayerVC while its video is in view
// (isShowingVideo: not scrolled away, or fullscreen), or Shorts. Any other page, another
// video's included (a related video opened mid-play), gets the bar.
//
// The live video plays in the thumbnail's place. There is one AVPlayerLayer (VideoPlayer.layer)
// and it can only be in one place, so who holds it follows three rules: a page takes it
// whenever it shows the video; a page only ever removes it from itself; and this bar only
// takes it when nobody holds it. A page that hands the video over posts refreshNotification,
// so the bar takes it in the same frame instead of on its next tick. The thumbnail stays
// underneath: it is what shows for an audio-only download (no picture to show), before the
// first frame, and while iOS 5/6 leave a moved, paused layer blank.
//
// While casting it is the TV's remote instead: the video on the TV with "Playing on <TV>",
// play/pause acting on the TV, and close stopping the cast. The phone's own player is stopped
// in cast mode, so there is never a local video competing for the bar.
//
// iPad: a 106x60 picture is tiny on that screen, so the video can float as a 320x180 card,
// bottom-right above the bar to begin with. A toggle on the bar moves it between the bar and
// the card, and the choice is remembered (floating by default). Only the video slot moves —
// the same view, carrying the one layer — so the three rules above do not change. The card
// shows and hides with the bar, and is not used when there is no picture to enlarge (an
// audio-only download, a cast): those stay in the bar as on the iPhone. The card can be
// dragged: let go, it sticks to the nearer side at that height (remembered); dropped onto the
// bar, the video goes back into it. The iPhone never builds any of it.

class MiniPlayerBar: UIView {

    static let barHeight: CGFloat = 60

    // Read once: on an iPhone the toggle and the card are never created.
    static let canFloat = UIDevice.current.userInterfaceIdiom == .pad
    private static let cardSize = CGSize(width: 320, height: 180)
    private static let cardMargin: CGFloat = 12          // from the screen's side edge and the bar
    // "1" = floating, "0" = in the bar; absent = floating, the default.
    private static let floatKey = "miniplayer_floating"
    // Where the card rests: "L" / "R" (absent = right), and its height as a fraction of the band
    // it may use, "0" just under the nav bar to "1" just above this bar (absent = 1). A fraction
    // rather than points, so a rotation keeps it in proportion.
    private static let sideKey = "miniplayer_card_side"
    private static let heightKey = "miniplayer_card_y"
    private static let navBottom: CGFloat = 64           // status bar + nav bar: never covered
    private static let flickSpeed: CGFloat = 500          // pt/s sideways that picks the side
    private static let cardBorder = UIColor(white: 1, alpha: 0.2).cgColor
    private static let liftedBorder = UIColor(white: 1, alpha: 0.6).cgColor

    // Posted by a page that just changed whether it shows its video: poll now.
    static let refreshNotification = Notification.Name("oldpipe.miniPlayerBar.refresh")

    // Callbacks wired up by AppDelegate.
    var onOpen: ((Video) -> Void)?
    var navProvider: (() -> UINavigationController?)?

    private let thumbView = AsyncImageView()
    // Holds the live video, over the thumbnail (see the header).
    private let videoSlot = UIView()
    // Whether the shown video is an audio-only download — worked out once per video, since
    // asking DownloadManager reads its whole store.
    private var shownIsAudio = false
    private let titleLabel = UILabel()
    private let channelLabel = UILabel()
    private let playPauseBtn = UIButton(type: .custom)
    private let closeBtn = UIButton(type: .custom)
    private let openBtn = UIButton(type: .custom)
    private let progressLine = UIView()

    private var shownVideoId: String?
    private var shownThumbURL = ""
    // Whether the labels currently describe a cast rather than local playback.
    private var shownCast = false
    private var pollTimer: Timer?

    // iPad only (nil on an iPhone). The card lives in the window, not in the bar, so the page
    // beside it keeps its touches; it is built the first time the video floats.
    private var floatBtn: UIButton?
    private var card: UIView?
    private var cardThumb: AsyncImageView?
    private var cardTouch: CardTouchView?
    private var floating = MiniPlayerBar.canFloat
        && UserDefaults.standard.string(forKey: MiniPlayerBar.floatKey) != "0"
    private var slotInCard = false      // where the video slot is right now
    private var moving = false          // the slot is on its way between the bar and the card
    private var cardOnLeft = UserDefaults.standard.string(forKey: MiniPlayerBar.sideKey) == "L"
    private var cardHeight: CGFloat = {
        guard let s = UserDefaults.standard.string(forKey: MiniPlayerBar.heightKey),
              let v = Double(s) else { return 1 }
        return CGFloat(max(0, min(1, v)))
    }()
    private var draggingCard = false
    private var dragOrigin = CGPoint.zero   // the card's centre when the drag began

    // The card shows and hides with the bar, whoever hides it.
    override var isHidden: Bool {
        didSet {
            guard card != nil, isHidden != oldValue else { return }
            if moving { videoSlot.isHidden = isHidden }   // mid-trip it sits in the window
            syncCard()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildUI()
        startPolling()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshNow),
                                               name: MiniPlayerBar.refreshNotification, object: nil)
    }

    @objc private func refreshNow() { poll() }

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
        progressLine.backgroundColor = Theme.accent
        addSubview(progressLine)

        // thumbnail (16:9, full height)
        thumbView.frame = CGRect(x: 0, y: 0, width: 106, height: MiniPlayerBar.barHeight)
        thumbView.contentMode = .scaleAspectFill
        thumbView.clipsToBounds = true
        thumbView.backgroundColor = UIColor(white: 0.2, alpha: 1)
        addSubview(thumbView)

        // Same frame as the thumbnail, clipped so an aspect-filled video stays inside it, and
        // transparent: an empty slot shows the thumbnail below. No touches — the open button
        // above it takes them.
        videoSlot.frame = thumbView.frame
        videoSlot.backgroundColor = .clear
        videoSlot.clipsToBounds = true
        videoSlot.isUserInteractionEnabled = false
        addSubview(videoSlot)

        titleLabel.backgroundColor = .clear
        titleLabel.textColor = .white
        titleLabel.font = UIFont.boldSystemFont(ofSize: 14)
        addSubview(titleLabel)

        channelLabel.backgroundColor = .clear
        channelLabel.textColor = UIColor(white: 0.7, alpha: 1)
        channelLabel.font = UIFont.systemFont(ofSize: 12)
        addSubview(channelLabel)

        // play / pause
        playPauseBtn.backgroundColor = .clear
        playPauseBtn.setImage(UIImage(named: "play"), for: .normal)
        playPauseBtn.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        addSubview(playPauseBtn)

        // close
        closeBtn.backgroundColor = .clear
        closeBtn.setImage(UIImage(named: "close"), for: .normal)
        closeBtn.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        addSubview(closeBtn)

        // transparent tap target over thumb + text (NO gesture recognizer — see CLAUDE.md)
        openBtn.backgroundColor = .clear
        openBtn.addTarget(self, action: #selector(openTapped), for: .touchUpInside)
        addSubview(openBtn)

        // iPad: the toggle between the video in the bar and the floating card, left of play.
        if MiniPlayerBar.canFloat {
            let b = UIButton(type: .custom)
            b.backgroundColor = .clear
            b.setImage(UIImage(named: floating ? "float-in" : "float-out"), for: .normal)
            b.addTarget(self, action: #selector(floatTapped), for: .touchUpInside)
            addSubview(b)
            floatBtn = b
        }

        layoutBar()
        bringSubviewToFront(playPauseBtn)
        bringSubviewToFront(closeBtn)
        if let b = floatBtn { bringSubviewToFront(b) }
    }

    // Every frame but the thumbnail's and the video slot's, which never move within the bar.
    // On an iPhone this is the bar's original layout. On an iPad the toggle takes 44 pt left of
    // play, and while the video floats the bar drops its thumbnail and the text starts at the
    // left edge.
    private func layoutBar() {
        let w = bounds.width, h = MiniPlayerBar.barHeight
        let toggleShown = floatBtn.map { !$0.isHidden } ?? false
        let right: CGFloat = toggleShown ? 132 : 88
        let textX: CGFloat = slotInCard ? 12 : 106 + 10
        let textW = max(0, w - textX - right)
        thumbView.isHidden = slotInCard
        titleLabel.frame = CGRect(x: textX, y: 10, width: textW, height: 20)
        channelLabel.frame = CGRect(x: textX, y: 32, width: textW, height: 16)
        floatBtn?.frame = CGRect(x: w - 132, y: 0, width: 44, height: h)
        playPauseBtn.frame = CGRect(x: w - 88, y: 0, width: 44, height: h)
        closeBtn.frame = CGRect(x: w - 44, y: 0, width: 44, height: h)
        openBtn.frame = CGRect(x: 0, y: 0, width: w - right, height: h)
    }

    #if IOS8_TARGET
    // iPad: the bar's flexibleWidth mask stretches its width on rotation, but the fixed-frame
    // children (right-anchored buttons + the text block that fills to them) have to be
    // repositioned for the new width. Compiled only into the iOS 8 build — the iOS 6/7 build
    // never resizes the bar (portrait-locked window) so it keeps its original fixed layout.
    override func layoutSubviews() {
        super.layoutSubviews()
        layoutBar()
        // A rotation resizes the bar; the card keeps its side and relative height.
        if let c = card, !draggingCard, !moving { c.frame = cardRestFrame() }
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
        let cast = CastController.shared
        let playingId = cast.isActive ? cast.video?.id : sp.currentVideo?.id
        var pageShowsIt = top is ShortsPlayerVC
        if !pageShowsIt, let id = playingId, let page = top as? VideoPlayerVC, page.video.id == id {
            pageShowsIt = page.isShowingVideo
        }
        if cast.isActive, let video = cast.video, !pageShowsIt {
            releaseVideo()   // the TV has the video; the phone's player is stopped
            pollCast(cast, video)
            return
        }
        guard let video = sp.currentVideo, !pageShowsIt, !cast.isActive else {
            releaseVideo()
            if !isHidden { isHidden = true }
            return
        }
        if isHidden { isHidden = false }

        if shownVideoId != video.id || shownCast {
            shownVideoId = video.id
            shownCast = false
            shownIsAudio = DownloadManager.isAudioOnly(video.id)
            titleLabel.text = video.title
            channelLabel.text = video.channelName
            showThumbnail(video.thumbnailURL)
            placeVideo()
        }
        takeVideoIfFree()

        // A finished video shows the replay arrow: play starts it over (VideoPlayer.play).
        playPauseBtn.setImage(UIImage(named: sp.isPlaying ? "pause" : (sp.isFinished ? "replay" : "play")),
                              for: .normal)

        let dur = sp.durationSeconds
        let frac = dur > 0 ? CGFloat(sp.currentSeconds / dur) : 0
        progressLine.frame = CGRect(x: 0, y: 0, width: bounds.width * max(0, min(1, frac)), height: 2)
    }

    // MARK: - The live video

    // Only a free layer: a page that holds it is showing the video itself. Aspect-filled, as
    // the thumbnail is, so a video not quite 16:9 still fills the slot; pages put their own
    // gravity back when they take it (attachLayer, fullscreen, Shorts). An audio-only download
    // has no picture, so its thumbnail stays as the artwork. Called on every tick while shown:
    // when it has nothing to do it is one pointer check.
    private func takeVideoIfFree() {
        let layer = VideoPlayer.shared.layer
        guard layer.superlayer == nil, !shownIsAudio else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.videoGravity = AVLayerVideoGravity.resizeAspectFill
        layer.frame = videoSlot.bounds
        videoSlot.layer.addSublayer(layer)
        CATransaction.commit()
    }

    // Hidden, or showing a cast: give the video up — but only from here (rule 2 in the header).
    private func releaseVideo() {
        let layer = VideoPlayer.shared.layer
        if layer.superlayer === videoSlot.layer { layer.removeFromSuperlayer() }
    }

    private func showThumbnail(_ url: String) {
        shownThumbURL = url
        guard !url.isEmpty else { return }
        thumbView.load(url: url)
        cardThumb?.load(url: url)   // the same URL: one download, one decode
    }

    // MARK: - Floating card (iPad)

    // Puts the video slot where it belongs: in the card when floating a picture, else in the
    // bar. Called when the shown content changes and from the toggle — not on every tick.
    private func placeVideo(animated: Bool = false) {
        // iPhone: always in the bar. Mid-trip or mid-drag: the end of either calls back here.
        guard let toggle = floatBtn, !moving, !draggingCard else { return }
        let hasPicture = !shownIsAudio && !shownCast
        if toggle.isHidden == hasPicture {
            toggle.isHidden = !hasPicture
            layoutBar()
        }
        let inCard = floating && hasPicture
        guard inCard != slotInCard, let host = superview,
              let card = inCard ? buildCardIfNeeded() : self.card else { return }
        slotInCard = inCard
        // Where it rests now: a card last dropped onto the bar was left there, hidden.
        if inCard { card.frame = cardRestFrame() }
        let target: UIView = inCard ? card : self
        let targetFrame = inCard ? card.bounds : thumbView.frame

        guard animated, !isHidden else {
            put(videoSlotIn: target, frame: targetFrame)
            layoutBar()
            syncCard()
            return
        }
        // The trip: the slot is lifted into the window, slides to its new place with the text
        // following, then settles into the card or the bar. Black while travelling, because a
        // paused iOS 5/6 layer can draw nothing once moved.
        let from = videoSlot.superview?.convert(videoSlot.frame, to: host) ?? .zero
        let to = target.convert(targetFrame, to: host)
        moving = true
        put(videoSlotIn: host, frame: from)
        videoSlot.backgroundColor = .black
        syncCard()
        if inCard { card.alpha = 0 }
        CATransaction.begin()
        // The video layer is not a view's layer, so it animates implicitly — on this clock.
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeInEaseOut))
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut], animations: {
            self.videoSlot.frame = to
            self.sizeVideo(to: to.size)
            self.layoutBar()
            card.alpha = 1
        }, completion: { _ in
            self.moving = false
            self.videoSlot.backgroundColor = .clear
            self.videoSlot.isHidden = false
            self.put(videoSlotIn: target, frame: targetFrame)
            self.syncCard()
            self.placeVideo()   // anything that changed during the trip
        })
        CATransaction.commit()
    }

    // In the bar: above the thumbnail, under the labels and buttons. In the card: between its
    // thumbnail and its tap target. The layer inside follows the slot's new size.
    private func put(videoSlotIn container: UIView, frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if container === self {
            insertSubview(videoSlot, aboveSubview: thumbView)
        } else if container === card, let touch = cardTouch {
            container.insertSubview(videoSlot, belowSubview: touch)
        } else {
            container.addSubview(videoSlot)
        }
        videoSlot.frame = frame
        sizeVideo(to: frame.size)
        CATransaction.commit()
    }

    private func sizeVideo(to size: CGSize) {
        let layer = VideoPlayer.shared.layer
        if layer.superlayer === videoSlot.layer { layer.frame = CGRect(origin: .zero, size: size) }
    }

    // Visible exactly when the bar is and the video floats.
    private func syncCard() {
        guard let card = card else { return }
        let show = !isHidden && slotInCard
        if card.isHidden == show { card.isHidden = !show }
    }

    // Square corners and no shadow on purpose: a rounded clip over a playing video is an
    // off-screen pass every frame. No autoresizing: on a rotation layoutSubviews re-pins it from
    // its side and relative height, which a margin mask could only do for one side.
    private func buildCardIfNeeded() -> UIView? {
        if let c = card { return c }
        guard let host = superview else { return nil }
        let c = UIView(frame: cardRestFrame())
        c.backgroundColor = UIColor(white: 0.2, alpha: 1)
        c.clipsToBounds = true
        c.layer.borderColor = MiniPlayerBar.cardBorder
        c.layer.borderWidth = 1
        c.isHidden = true

        let thumb = AsyncImageView(frame: c.bounds)
        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        c.addSubview(thumb)

        // The whole card: a tap opens the video, like the bar's title; a drag moves the card.
        let touch = CardTouchView(frame: c.bounds)
        touch.backgroundColor = .clear
        touch.canDrag = { [weak self] in self.map { !$0.moving && $0.slotInCard && !$0.isHidden } ?? false }
        touch.onTap = { [weak self] in self?.openTapped() }
        touch.onDragBegan = { [weak self] in self?.cardDragBegan() }
        touch.onDragMoved = { [weak self] travel in self?.cardDragMoved(travel) }
        touch.onDragEnded = { [weak self] velocity, cancelled in self?.cardDragEnded(velocity, cancelled: cancelled) }
        c.addSubview(touch)

        host.insertSubview(c, belowSubview: self)
        card = c
        cardThumb = thumb
        cardTouch = touch
        if !shownThumbURL.isEmpty { thumb.load(url: shownThumbURL) }
        return c
    }

    // The band the card may rest in: just under the nav bar to just above this bar.
    private func cardBand() -> (top: CGFloat, bottom: CGFloat) {
        let top = MiniPlayerBar.navBottom + MiniPlayerBar.cardMargin
        let bottom = frame.minY - MiniPlayerBar.cardMargin - MiniPlayerBar.cardSize.height
        return (top, max(top, bottom))
    }

    // Against its side, at its height in the band. The bar spans the window, so its frame gives
    // the screen's width in the card's coordinates.
    private func cardRestFrame() -> CGRect {
        let s = MiniPlayerBar.cardSize, m = MiniPlayerBar.cardMargin
        let band = cardBand()
        let x = cardOnLeft ? frame.minX + m : frame.maxX - m - s.width
        let y = band.top + (band.bottom - band.top) * cardHeight
        return CGRect(x: x, y: floor(y), width: s.width, height: s.height)
    }

    // MARK: Dragging the card

    // Dropped with at least half the bar covered: the video goes back into the bar.
    private func cardOverBar(_ c: UIView) -> Bool {
        return c.frame.maxY >= frame.minY + MiniPlayerBar.barHeight / 2
    }

    private func cardDragBegan() {
        guard let c = card else { return }
        draggingCard = true
        dragOrigin = c.center
        c.layer.borderColor = MiniPlayerBar.liftedBorder
    }

    // Follows the finger, kept wholly on screen. Over the bar the border turns the accent colour:
    // letting go there docks the video. Only the card's position changes — the video inside is
    // neither resized nor moved to another layer.
    private func cardDragMoved(_ travel: CGPoint) {
        guard let c = card, let host = superview, !isHidden else { return }
        let hw = c.bounds.width / 2, hh = c.bounds.height / 2
        c.center = CGPoint(x: min(max(dragOrigin.x + travel.x, hw), host.bounds.width - hw),
                           y: min(max(dragOrigin.y + travel.y, hh), host.bounds.height - hh))
        c.layer.borderColor = cardOverBar(c) ? Theme.accent.cgColor : MiniPlayerBar.liftedBorder
    }

    // Onto the bar: dock, as the toggle does. Anywhere else: glide to the nearer side (or the
    // side flicked towards) at the height it was let go, and remember both. Cancelled, or the
    // bar hid mid-drag: back to where it rested, nothing saved.
    private func cardDragEnded(_ velocity: CGPoint, cancelled: Bool) {
        guard let c = card else { return }
        draggingCard = false
        c.layer.borderColor = MiniPlayerBar.cardBorder
        let usable = !cancelled && !isHidden
        if usable && cardOverBar(c) {
            setFloating(false)
            return
        }
        if usable {
            if abs(velocity.x) > MiniPlayerBar.flickSpeed {
                cardOnLeft = velocity.x < 0
            } else {
                cardOnLeft = c.center.x < frame.midX
            }
            let band = cardBand()
            let y = min(max(c.frame.minY, band.top), band.bottom)
            cardHeight = band.bottom > band.top ? (y - band.top) / (band.bottom - band.top) : 1
            let d = UserDefaults.standard
            d.set(cardOnLeft ? "L" : "R", forKey: MiniPlayerBar.sideKey)
            d.set(String(format: "%.3f", Double(cardHeight)), forKey: MiniPlayerBar.heightKey)
        }
        // Plain ease-out: the spring variant is iOS 7+.
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState],
                       animations: { c.frame = self.cardRestFrame() }, completion: nil)
        placeVideo()   // anything that changed during the drag
    }

    @objc private func floatTapped() {
        setFloating(!floating)
    }

    // The toggle, and a card dropped onto the bar.
    private func setFloating(_ on: Bool) {
        guard !moving, !draggingCard, on != floating else { return }
        floating = on
        UserDefaults.standard.set(on ? "1" : "0", forKey: MiniPlayerBar.floatKey)
        floatBtn?.setImage(UIImage(named: on ? "float-in" : "float-out"), for: .normal)
        placeVideo(animated: true)
    }

    private func pollCast(_ cast: CastController, _ video: Video) {
        if isHidden { isHidden = false }
        if shownVideoId != video.id || !shownCast {
            shownVideoId = video.id
            shownCast = true
            titleLabel.text = video.title
            showThumbnail(video.thumbnailURL)
            placeVideo()   // the picture is on the TV: back in the bar, no toggle
        }
        // Rewritten only on change: assigning the same text still relayouts the label twice a second.
        let status = cast.statusText
        if channelLabel.text != status { channelLabel.text = status }

        playPauseBtn.setImage(UIImage(named: cast.isPlaying ? "pause" : "play"), for: .normal)

        let frac = cast.duration > 0 ? CGFloat(cast.position / cast.duration) : 0
        progressLine.frame = CGRect(x: 0, y: 0, width: bounds.width * max(0, min(1, frac)), height: 2)
    }

    // MARK: - Actions

    @objc private func playPauseTapped() {
        if CastController.shared.isActive {
            CastController.shared.togglePlayPause()
        } else {
            VideoPlayer.shared.togglePlayPause()
        }
        poll()
    }

    // While casting, close stops the cast (the TV goes back to its own screen).
    @objc private func closeTapped() {
        if CastController.shared.isActive {
            CastController.shared.stop()
        } else {
            let id = VideoPlayer.shared.currentVideo?.id
            VideoPlayer.shared.stop()
            // Closed from that video's own page, scrolled away from it: the page puts its
            // video area back to how it opened.
            if let id = id, let page = navProvider?()?.topViewController as? VideoPlayerVC {
                page.playbackClosedFromBar(id)
            }
        }
        shownVideoId = nil
        isHidden = true
    }

    @objc private func openTapped() {
        let cast = CastController.shared
        guard let video = cast.isActive ? cast.video : VideoPlayer.shared.currentVideo else { return }
        onOpen?(video)
    }
}

// The floating card's surface (iPad). One view tells a tap from a drag with raw touches, like
// the player's SeekTapView: a gesture recognizer next to buttons misfires on iOS 6, and this
// way nothing runs between touches. A touch that travels more than `slop` is a drag and never
// a tap. Positions are in window coordinates, which the card shares.
private final class CardTouchView: UIView {
    var canDrag: (() -> Bool)?
    var onTap: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragMoved: ((CGPoint) -> Void)?            // finger travel since touch-down
    var onDragEnded: ((CGPoint, Bool) -> Void)?      // velocity in pt/s, cancelled

    private static let slop: CGFloat = 10
    private var start = CGPoint.zero
    private var travelled = false
    private var dragging = false
    private var last = CGPoint.zero
    private var lastTime: TimeInterval = 0
    private var velocity = CGPoint.zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        start = t.location(in: nil)
        last = start
        lastTime = t.timestamp
        travelled = false
        dragging = false
        velocity = .zero
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let p = t.location(in: nil)
        if !travelled {
            let dx = p.x - start.x, dy = p.y - start.y
            guard dx * dx + dy * dy > CardTouchView.slop * CardTouchView.slop else { return }
            travelled = true
            dragging = canDrag?() ?? false
            if dragging { onDragBegan?() }
        }
        guard dragging else { return }
        let dt = t.timestamp - lastTime
        if dt > 0 {
            // Lightly smoothed: one 16 ms step on its own is noisy.
            let vx = (p.x - last.x) / CGFloat(dt), vy = (p.y - last.y) / CGFloat(dt)
            velocity = CGPoint(x: velocity.x * 0.3 + vx * 0.7, y: velocity.y * 0.3 + vy * 0.7)
        }
        last = p
        lastTime = t.timestamp
        onDragMoved?(CGPoint(x: p.x - start.x, y: p.y - start.y))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        if dragging {
            dragging = false
            // A finger that stopped before lifting threw nothing.
            onDragEnded?(t.timestamp - lastTime > 0.1 ? .zero : velocity, false)
        } else if !travelled, bounds.contains(t.location(in: self)) {
            onTap?()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if dragging {
            dragging = false
            onDragEnded?(.zero, true)
        }
    }
}

// Timer target wrapper so the repeating Timer doesn't retain the bar via a selector.
private class BlockProxyBar: NSObject {
    let block: () -> Void
    init(_ b: @escaping () -> Void) { block = b }
    @objc func fire() { block() }
}
