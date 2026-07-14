import UIKit
import AVFoundation

// VideoPlayerVC is a thin view onto VideoPlayer.shared. It does NOT own the AVPlayer —
// the singleton does, so audio keeps playing when this VC is popped (the mini bar takes
// over). On appear it attaches the shared AVPlayerLayer into its video container; on
// disappear it detaches the layer (does NOT stop playback). Audio session, Now Playing
// metadata, remote-control transport, and resume persistence all live in the singleton.

class VideoPlayerVC: UIViewController, UIActionSheetDelegate, UIAlertViewDelegate {

    private var video: Video
    private var streams: [VideoStream] = []
    private var didRequestStreams = false


    // Add-to-playlist chooser state (index → playlist mapping for the action sheet).
    private var pendingPlaylists: [Playlist] = []

    // Chromecast spike: LAN discovery + one live session. castDevices maps the picker
    // action-sheet indices to discovered devices.
    private var castDiscovery: CastDiscovery?
    private var castSession: CastSession?
    private var castDevices: [CastDevice] = []
    // Cast control panel overlaid on the video area while a session is live.
    private var castPanel: UIView?
    private var castTitleLabel: UILabel?
    private var castPlayPauseBtn: UIButton?
    private var castScrubber: UISlider?
    private var castCurLabel: UILabel?
    private var castDurLabel: UILabel?
    private var castDuration: Double = 0
    private var castIsScrubbing = false
    private var castIsPlaying = false
    // Cast button lives in the bottom control bar, just before the fullscreen button (so it
    // rides along into fullscreen with the bar); a spinner sits centered in it while device
    // discovery is running.
    private var castBtn: UIButton?
    private var castBtnSpinner: UIActivityIndicatorView?
    // Quality picker (HLS transmux): "hd" button in the control bar + the HLS-capable
    // video-only streams backing the last-shown sheet (index-aligned with its buttons).
    private var hdBtn: UIButton?
    private var pendingHLSStreams: [VideoStream] = []

    // Everything below the meta line is laid out by relayout() from contentBelowMetaY:
    // description (below meta) → download button → share row → related videos. The
    // description and related arrive asynchronously (in either order) and the description
    // can expand/collapse, so relayout() repositions the action buttons each time.
    private var contentBelowMetaY: CGFloat = 0
    private var descriptionText = ""
    private var descExpanded = false
    private var descRowViews: [UIView] = []
    private var relatedVideos: [Video] = []
    private var didRequestRelated = false
    private var relatedRowViews: [UIView] = []

    private var sp: VideoPlayer { return VideoPlayer.shared }

    // UI
    private var scrollView: UIScrollView?
    private var thumbView: AsyncImageView?
    private var playBtn: UIButton?
    private var statusLabel: UILabel?
    private var spinner: UIActivityIndicatorView?
    private var titleLabel: UILabel?
    private var channelLabel: UILabel?
    private var chanBtn: UIButton?
    private var metaLabel: UILabel?
    private var videoContainer: UIView?
    private var tapCatcher: SeekTapView?
    private var seekIndicator: UIView?
    private var downloadBtn: UIButton?
    private var shareBtn: UIButton?
    private var addPlaylistBtn: UIButton?
    private var fsOverlay: UIView?

    // Playback controls (play/pause + scrubber)
    private var controlsView: UIView?
    private var playPauseBtn: UIButton?
    private var scrubber: UISlider?
    private var currentTimeLabel: UILabel?
    private var durationLabel: UILabel?
    private var fsButton: UIButton?
    private var isScrubbing = false
    private var fsAngle: CGFloat = CGFloat(Double.pi / 2)
    private var fsActive = false

    // iOS 7+ view-controller-based status bar control (ignored on iOS 6).
    override var prefersStatusBarHidden: Bool { return fsActive }

    // MARK: - Init

    init(video: Video) {
        self.video = video
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Video"
        view.backgroundColor = UIColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
    }

    // Show the cast glyph (idle, or active where a tap stops the session); stops the spinner.
    private func showCastGlyph() {
        castBtnSpinner?.stopAnimating()
        castBtn?.setImage(UIImage(named: "cast"), for: .normal)
        castBtn?.isHidden = false
    }

    // Swap the cast glyph for a spinning indicator while cast discovery runs.
    private func showCastSpinner() {
        castBtn?.setImage(nil, for: .normal)
        castBtnSpinner?.startAnimating()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self, selector: #selector(orientationChanged),
            name: UIDevice.orientationDidChangeNotification, object: nil)
        // Re-sync UI + audio session when returning from background / lock screen.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)

        if scrollView == nil { setupUI() }

        // If the singleton is already playing this video (reopened from the mini bar, or
        // returning from a pushed VC), reattach onto the live playback. Otherwise load.
        if sp.isActive(video.id) {
            showActivePlayback()
            // Reopened onto live playback (e.g. from the mini bar) — still fetch the
            // description in the background without disturbing the playing UI.
            if !didRequestStreams { loadStreams(updateStatus: false) }
        } else if !didRequestStreams {
            loadStreams()
        }

        // A download started here may still be running in the manager after we navigated
        // away and back — reattach its progress UI.
        if DownloadManager.isDownloading(video.id) {
            downloadBtn?.isEnabled = false
            downloadBtn?.setTitle("Downloading \(Int(DownloadManager.progress(for: video.id) * 100))%...", for: .normal)
            observeDownload(autoPlay: false)
        }

        // Fetch related videos immediately on open (once per VC instance).
        if !didRequestRelated { loadRelated() }

        // Own the singleton's autoplay-advance callback while we're the frontmost player,
        // so a playlist auto-advance swaps this VC's content in place.
        sp.onAdvance = { [weak self] v in self?.handleAutoAdvance(v) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Release the advance callback — the next frontmost VC (or none) takes over. When
        // no VC is on screen, autoplay still advances; only the mini bar reflects it.
        sp.onAdvance = nil
        NotificationCenter.default.removeObserver(self)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        if let t = objc_getAssociatedObject(self, &timerKey) as? Timer { t.invalidate() }
        if let t = objc_getAssociatedObject(self, &progressTimerKey) as? Timer { t.invalidate() }
        if let t = objc_getAssociatedObject(self, &downloadPollKey) as? Timer { t.invalidate() }
        if let t = objc_getAssociatedObject(self, &controlsHideKey) as? Timer { t.invalidate() }
        if fsOverlay != nil { exitFullscreen() }
        // Detach the shared layer — do NOT stop. Playback (audio) continues; the mini bar
        // takes over the UI. The layer is reattached on the next appear.
        detachLayer()
    }

    @objc private func appDidBecomeActive() {
        // The audio session can be deactivated by the system in the background; re-arm it
        // and resync the scrubber to the player's real position.
        sp.reactivateSession()
        updateProgress()
    }

    // MARK: - Shared layer attach / detach

    private func attachLayer() {
        guard let container = videoContainer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sp.layer.frame = container.bounds
        sp.layer.videoGravity = AVLayerVideoGravity.resizeAspect
        if let thumbLayer = thumbView?.layer {
            container.layer.insertSublayer(sp.layer, below: thumbLayer)
        } else {
            container.layer.addSublayer(sp.layer)
        }
        CATransaction.commit()
    }

    private func detachLayer() {
        sp.layer.removeFromSuperlayer()
    }

    // Reattach onto already-running playback (from mini bar / returning to the VC).
    private func showActivePlayback() {
        playBtn?.isHidden = true
        statusLabel?.isHidden = true
        thumbView?.isHidden = true
        attachLayer()
        sp.setArtwork(thumbView?.image)
        showControls()
        updateProgress()
    }

    // MARK: - Autoplay advance

    // The singleton auto-advanced the playlist queue to a new video (playback is already
    // loading in the singleton). Swap this VC's content in place: reflow the title/channel/
    // meta block (title height depends on the new text), reset the async description/related
    // state, and re-fetch them for the new video without flashing "Loading..." over the
    // live layer.
    private func handleAutoAdvance(_ newVideo: Video) {
        video = newVideo
        streams = []
        didRequestStreams = false
        didRequestRelated = false
        descriptionText = ""
        descExpanded = false
        relatedVideos = []

        let w = UIScreen.main.bounds.width
        let padding: CGFloat = 12

        var y = (videoContainer?.frame.maxY ?? floor(w * 9.0 / 16.0)) + 12
        titleLabel?.text = newVideo.title
        let titleH = titleLabel?.sizeThatFits(CGSize(width: w - padding * 2, height: 200)).height ?? 20
        titleLabel?.frame = CGRect(x: padding, y: y, width: w - padding * 2, height: titleH)
        y += titleH + 8

        channelLabel?.text = newVideo.channelName
        channelLabel?.textColor = newVideo.channelId.isEmpty
            ? UIColor(white: 0.6, alpha: 1)
            : UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 1)
        channelLabel?.frame = CGRect(x: padding, y: y, width: w - padding * 2, height: 20)
        chanBtn?.frame = channelLabel?.frame ?? .zero
        chanBtn?.isHidden = newVideo.channelId.isEmpty
        y += 24

        let meta = [newVideo.durationText, newVideo.displayPublished, newVideo.viewCountText]
            .filter { !$0.isEmpty }.joined(separator: " • ")
        metaLabel?.text = meta
        if !meta.isEmpty {
            metaLabel?.frame = CGRect(x: padding, y: y, width: w - padding * 2, height: 18)
            metaLabel?.isHidden = false
            y += 26
        } else {
            metaLabel?.isHidden = true
        }
        contentBelowMetaY = y

        // Thumbnail (hidden behind the live layer, but used for lock-screen artwork).
        if !newVideo.thumbnailURL.isEmpty { thumbView?.load(url: newVideo.thumbnailURL) }

        updateDownloadButton()
        showActivePlayback()   // re-attach layer + show controls + resync progress
        relayout()

        // Fetch the new video's description + related quietly (no status label changes).
        loadStreams(updateStatus: false)
        loadRelated()
    }

    // MARK: - Orientation → fullscreen

    // The app window stays portrait (iOS 6-safe); rotating the device drives the
    // fullscreen overlay's rotation so the video fills the screen in landscape.
    @objc private func orientationChanged() {
        #if IOS8_TARGET
        // iPad rotates its window natively: rotating to landscape already gives a landscape
        // view, so the in-page layout just reflows (see viewWillTransition). Driving the
        // manual rotated fullscreen overlay on top of an already-rotated window would
        // double-transform it, so the rotate-to-fullscreen behavior is suppressed on iPad.
        if UIDevice.current.userInterfaceIdiom == .pad { return }
        #endif
        guard sp.isActive(video.id) else { return }   // only while a video is loaded
        // Short (portrait) videos stay portrait — device rotation doesn't drive a
        // landscape fullscreen for them (fullscreen is entered only via the button).
        if sp.isPortraitVideo { return }
        switch UIDevice.current.orientation {
        case .landscapeLeft:
            setFullscreen(true, angle: CGFloat(Double.pi / 2))
        case .landscapeRight:
            setFullscreen(true, angle: CGFloat(-Double.pi / 2))
        case .portrait:
            setFullscreen(false, angle: 0)
        default:
            break
        }
    }

    private func setFullscreen(_ on: Bool, angle: CGFloat) {
        if on {
            fsAngle = angle
            if fsOverlay == nil {
                enterFullscreen()
            } else {
                // Already fullscreen — just re-orient to the new landscape side.
                fsOverlay?.transform = CGAffineTransform(rotationAngle: angle)
            }
        } else if fsOverlay != nil {
            exitFullscreen()
        }
    }

    #if IOS8_TARGET
    // iPad rotates its window natively; reflow the whole page to the new width. This whole
    // path is compiled ONLY into the iOS 8 build (-D IOS8_TARGET) — the iOS 6/7 build never
    // sees it, so iOS 6 behavior is provably untouched.
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        guard UIDevice.current.userInterfaceIdiom == .pad, scrollView != nil else { return }
        // Reflow using the target `size` from the coordinator, NOT UIScreen.main.bounds —
        // the latter can still report the OLD (portrait) dimensions when read from inside
        // the transition/completion, leaving the page stuck at portrait width. Do it in
        // alongsideTransition so it tracks the rotation animation, and again on completion
        // as a snap-to-final safety net.
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.relayoutForRotation(size: size)
        }, completion: { [weak self] _ in
            self?.relayoutForRotation(size: size)
        })
    }

    // Recompute every width-dependent frame from the new screen size and re-run relayout()
    // (which already reflows the description → buttons → related block from scrollView width).
    private func relayoutForRotation(size: CGSize) {
        guard let sv = scrollView, let container = videoContainer else { return }
        // Derive frames from the POST-rotation bounds, not the coordinator `size`: with
        // edgesForExtendedLayout = [] the VC view is inset below the bars, so `size` (the
        // container size) would over-count by the bar height. UIKit sets the final bounds
        // before running the transition-coordinator blocks, so view.bounds is the true
        // below-bar content area, and window.bounds is the full screen (for the fullscreen
        // overlay, which must cover the bars too).
        let w = view.bounds.width
        let h = view.bounds.height
        let padding: CGFloat = 12

        // If the button-driven fullscreen overlay is up, resize IT to the new (already-
        // rotated) FULL screen and re-anchor the layer / bar / tap-catcher inside it; the
        // page underneath is hidden behind the overlay, but reflow it too so it's correct
        // on exit.
        if let overlay = fsOverlay {
            let full = view.window?.bounds ?? CGRect(x: 0, y: 0, width: w, height: h)
            overlay.frame = CGRect(x: 0, y: 0, width: full.width, height: full.height)
            overlay.transform = .identity
            sp.layer.frame = overlay.bounds
            tapCatcher?.frame = overlay.bounds
            let barH: CGFloat = 40
            controlsView?.frame = CGRect(x: 0, y: overlay.bounds.height - barH, width: overlay.bounds.width, height: barH)
            layoutControls(width: overlay.bounds.width)
        }

        // The VC view is already below the bars (edges = []), so the scroll view fills it.
        sv.frame = CGRect(x: 0, y: 0, width: w, height: h)

        let videoH = floor(w * 9.0 / 16.0)
        container.frame = CGRect(x: 0, y: 0, width: w, height: videoH)
        thumbView?.frame = CGRect(x: 0, y: 0, width: w, height: videoH)
        playBtn?.frame = CGRect(x: (w - 64) / 2, y: (videoH - 64) / 2, width: 64, height: 64)
        statusLabel?.frame = CGRect(x: 0, y: videoH - 28, width: w, height: 28)
        spinner?.center = CGPoint(x: w / 2, y: videoH / 2)

        if fsOverlay == nil {
            tapCatcher?.frame = CGRect(x: 0, y: 0, width: w, height: videoH)
            sp.layer.frame = container.bounds
            controlsView?.frame = CGRect(x: 0, y: videoH - 40, width: w, height: 40)
            layoutControls(width: w)
        }

        // Title / channel / meta block (title height depends on width).
        var y = videoH + 12
        if let titleL = titleLabel {
            let titleH = titleL.sizeThatFits(CGSize(width: w - padding * 2, height: 200)).height
            titleL.frame = CGRect(x: padding, y: y, width: w - padding * 2, height: titleH)
            y += titleH + 8
        }
        if let chL = channelLabel {
            chL.frame = CGRect(x: padding, y: y, width: w - padding * 2, height: 20)
            chanBtn?.frame = chL.frame
            y += 24
        }
        if let mL = metaLabel, !(mL.isHidden) {
            mL.frame = CGRect(x: padding, y: y, width: w - padding * 2, height: 18)
            y += 26
        }
        contentBelowMetaY = y

        relayout()
    }
    #endif

    // MARK: - UI Setup

    private func setupUI() {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height

        let sv = UIScrollView(frame: CGRect(x: 0, y: 0, width: w, height: h - 64))
        sv.backgroundColor = UIColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
        // iPad rotates natively; resize with the view during the rotation animation. The
        // internal content (video, labels, controls) is snapped into place by
        // relayoutForRotation() on completion. iOS 6/7 build: [] (portrait-locked, no-op).
        sv.autoresizingMask = iPadFlexWidthHeight
        view.addSubview(sv)
        scrollView = sv

        var y: CGFloat = 0

        // Video container (16:9 ratio)
        let videoH = floor(w * 9.0 / 16.0)
        let container = UIView(frame: CGRect(x: 0, y: y, width: w, height: videoH))
        container.backgroundColor = .black
        sv.addSubview(container)
        videoContainer = container
        y += videoH

        // Thumbnail (shown before playback)
        let thumb = AsyncImageView(frame: CGRect(x: 0, y: 0, width: w, height: videoH))
        thumb.contentMode = .scaleAspectFit
        thumb.backgroundColor = .black
        thumb.load(url: video.thumbnailURL)
        container.addSubview(thumb)
        thumbView = thumb

        // Transparent tap-catcher over the video: single tap toggles the control bar, a
        // double tap on the left/right third seeks -15s / +15s. A custom UIView reading
        // UITouch.tapCount (NOT a UITapGestureRecognizer, which conflicts with button taps
        // on iOS 6). Added here so it sits BELOW the play button / controls / cast button —
        // those keep their own taps; taps anywhere else on the video hit this.
        let tap = SeekTapView(frame: CGRect(x: 0, y: 0, width: w, height: videoH))
        tap.backgroundColor = .clear
        tap.onSingleTap = { [weak self] in self?.videoAreaTapped() }
        tap.onSeekBackward = { [weak self] in self?.seekBackwardTapped() }
        tap.onSeekForward = { [weak self] in self?.seekForwardTapped() }
        container.addSubview(tap)
        tapCatcher = tap

        // Play button overlay
        let btn = UIButton(type: .custom)
        btn.frame = CGRect(x: (w - 64) / 2, y: (videoH - 64) / 2, width: 64, height: 64)
        btn.backgroundColor = UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 0.9)
        btn.layer.cornerRadius = 32
        btn.setImage(UIImage(named: "play"), for: .normal)
        btn.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        container.addSubview(btn)
        playBtn = btn

        // Status label (loading/error messages)
        let sl = UILabel()
        // Translucent black plate so the text stays readable over any thumbnail behind it.
        sl.backgroundColor = UIColor(white: 0, alpha: 0.55)
        sl.textColor = .white
        sl.textAlignment = .center
        sl.font = UIFont.systemFont(ofSize: 13)
        sl.numberOfLines = 2
        sl.isHidden = true
        sl.frame = CGRect(x: 0, y: videoH - 28, width: w, height: 28)
        container.addSubview(sl)
        statusLabel = sl

        // Spinner shown while a stream is being prepared — sits where the play button was,
        // so the wait reads as "working" rather than "stuck". whiteLarge = iOS 2+ safe.
        let spin = UIActivityIndicatorView(style: .whiteLarge)
        spin.hidesWhenStopped = true
        spin.center = CGPoint(x: w / 2, y: videoH / 2)
        container.addSubview(spin)
        spinner = spin

        buildControls(width: w, videoHeight: videoH, in: container)

        // Title
        let padding: CGFloat = 12
        y += 12
        let titleL = UILabel()
        titleL.backgroundColor = .clear
        titleL.textColor = UIColor(white: 0.95, alpha: 1)
        titleL.font = UIFont.boldSystemFont(ofSize: 16)
        titleL.numberOfLines = 3
        titleL.text = video.title
        let titleH = titleL.sizeThatFits(CGSize(width: w - padding * 2, height: 200)).height
        titleL.frame = CGRect(x: padding, y: y, width: w - padding * 2, height: titleH)
        sv.addSubview(titleL)
        titleLabel = titleL
        y += titleH + 8

        // Channel (tappable → channel page, when we know the channel id)
        let channelL = UILabel()
        channelL.backgroundColor = .clear
        channelL.textColor = video.channelId.isEmpty
            ? UIColor(white: 0.6, alpha: 1)
            : UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 1)
        channelL.font = UIFont.systemFont(ofSize: 14)
        channelL.text = video.channelName
        channelL.frame = CGRect(x: padding, y: y, width: w - padding * 2, height: 20)
        sv.addSubview(channelL)
        channelLabel = channelL
        // Always create the tap target (stored so auto-advance can retarget/toggle it);
        // it's only enabled when we know the channel id.
        let cb = UIButton(type: .custom)
        cb.frame = channelL.frame
        cb.backgroundColor = .clear
        cb.addTarget(self, action: #selector(channelTapped), for: .touchUpInside)
        cb.isHidden = video.channelId.isEmpty
        sv.addSubview(cb)
        chanBtn = cb
        y += 24

        // Meta (duration + published + views)
        let meta = [video.durationText, video.displayPublished, video.viewCountText].filter { !$0.isEmpty }.joined(separator: " • ")
        if !meta.isEmpty {
            let metaL = UILabel()
            metaL.backgroundColor = .clear
            metaL.textColor = UIColor(white: 0.5, alpha: 1)
            metaL.font = UIFont.systemFont(ofSize: 13)
            metaL.text = meta
            metaL.frame = CGRect(x: padding, y: y, width: w - padding * 2, height: 18)
            sv.addSubview(metaL)
            metaLabel = metaL
            y += 26
        }

        // Everything from here down is positioned by relayout() (description sits directly
        // below the meta line and pushes the buttons + related down when it loads).
        contentBelowMetaY = y

        // Download-for-offline button (frame set in relayout).
        let dl = UIButton(type: .custom)
        dl.layer.cornerRadius = 6
        dl.setTitleColor(.white, for: .normal)
        dl.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
        dl.setImage(UIImage(named: "download"), for: .normal)
        dl.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        dl.addTarget(self, action: #selector(downloadTapped), for: .touchUpInside)
        sv.addSubview(dl)
        downloadBtn = dl
        updateDownloadButton()

        // Share + Add-to-playlist row (two equal buttons; frames set in relayout).
        let secondaryBg = UIColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1)

        let share = UIButton(type: .custom)
        share.layer.cornerRadius = 6
        share.backgroundColor = secondaryBg
        share.setTitle("Share", for: .normal)
        share.setTitleColor(.white, for: .normal)
        share.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
        share.setImage(UIImage(named: "share"), for: .normal)
        share.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        share.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        sv.addSubview(share)
        shareBtn = share

        let addPl = UIButton(type: .custom)
        addPl.layer.cornerRadius = 6
        addPl.backgroundColor = secondaryBg
        addPl.setTitle("Playlist", for: .normal)
        addPl.setTitleColor(.white, for: .normal)
        addPl.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
        addPl.setImage(UIImage(named: "playlist"), for: .normal)
        addPl.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        addPl.addTarget(self, action: #selector(addToPlaylistTapped), for: .touchUpInside)
        sv.addSubview(addPl)
        addPlaylistBtn = addPl

        relayout()
    }

    @objc private func channelTapped() {
        guard !video.channelId.isEmpty else { return }
        let vc = ChannelVC(channelId: video.channelId, name: video.channelName)
        navigationController?.pushViewController(vc, animated: true)
    }

    private func updateDownloadButton() {
        if DownloadManager.isDownloaded(video.id) {
            downloadBtn?.setTitle("Downloaded \u{2713}", for: .normal)
            downloadBtn?.isEnabled = false
            downloadBtn?.backgroundColor = UIColor(red: 0.15, green: 0.4, blue: 0.15, alpha: 1)
        } else {
            downloadBtn?.setTitle("Download for offline", for: .normal)
            downloadBtn?.isEnabled = true
            downloadBtn?.backgroundColor = UIColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1)
        }
    }

    // MARK: - Related videos

    private func loadRelated() {
        didRequestRelated = true
        YoutubeAPI.getRelated(videoId: video.id, priority: true) { [weak self] vids in
            guard let self = self else { return }
            self.relatedVideos = Array(vids.prefix(12))
            self.relayout()
        }
    }

    @objc private func descToggleTapped() {
        descExpanded = !descExpanded
        relayout()
    }

    // Lay out everything below the meta line: description → download button → share row →
    // related videos. Called from setupUI and whenever async content (description, related)
    // arrives or the description is expanded/collapsed. Repositions the (already-created)
    // action buttons and re-lays the async sections, then sizes the scroll content once.
    private func relayout() {
        guard let sv = scrollView else { return }
        for v in descRowViews { v.removeFromSuperview() }
        descRowViews.removeAll()
        for v in relatedRowViews { v.removeFromSuperview() }
        relatedRowViews.removeAll()

        let w = sv.bounds.width
        let padding: CGFloat = 12
        var y = contentBelowMetaY

        // Description (directly under the meta line).
        y = buildDescriptionSection(startY: y, width: w)

        // Download button.
        downloadBtn?.frame = CGRect(x: padding, y: y, width: w - padding * 2, height: 44)
        y += 44 + 12

        // Share + add-to-playlist row.
        let gap: CGFloat = 10
        let halfW = (w - padding * 2 - gap) / 2
        shareBtn?.frame = CGRect(x: padding, y: y, width: halfW, height: 44)
        addPlaylistBtn?.frame = CGRect(x: padding + halfW + gap, y: y, width: halfW, height: 44)
        y += 44 + 12

        // Related videos.
        y = buildRelatedRows(startY: y, width: w)

        sv.contentSize = CGSize(width: w, height: y + 80)   // +80 clears the mini player bar
    }

    // Collapsible description block. Collapsed to 4 lines; a "Show more"/"Show less"
    // toggle appears only when the text is actually longer than the collapsed cap.
    private func buildDescriptionSection(startY: CGFloat, width w: CGFloat) -> CGFloat {
        guard !descriptionText.isEmpty, let sv = scrollView else { return startY }
        let padding: CGFloat = 12
        let bodyW = w - padding * 2
        var y = startY

        let sep = UIView(frame: CGRect(x: 0, y: y, width: w, height: 0.5))
        sep.backgroundColor = UIColor(white: 0.2, alpha: 1)
        sv.addSubview(sep); descRowViews.append(sep)
        y += 12

        let header = UILabel()
        header.backgroundColor = .clear
        header.textColor = UIColor(white: 0.95, alpha: 1)
        header.font = UIFont.boldSystemFont(ofSize: 16)
        header.text = "Description"
        header.frame = CGRect(x: padding, y: y, width: bodyW, height: 22)
        sv.addSubview(header); descRowViews.append(header)
        y += 30

        let bodyFont = UIFont.systemFont(ofSize: 13)
        // Measure collapsed (4-line) vs full height to decide whether a toggle is needed.
        let collapsedH = heightForText(descriptionText, font: bodyFont, width: bodyW, maxLines: 4)
        let fullH = heightForText(descriptionText, font: bodyFont, width: bodyW, maxLines: 0)
        let truncated = fullH > collapsedH + 1

        let body = UILabel()
        body.backgroundColor = .clear
        body.textColor = UIColor(white: 0.8, alpha: 1)
        body.font = bodyFont
        body.numberOfLines = descExpanded ? 0 : 4
        body.text = descriptionText
        let bodyH = descExpanded ? fullH : collapsedH
        body.frame = CGRect(x: padding, y: y, width: bodyW, height: bodyH)
        sv.addSubview(body); descRowViews.append(body)
        y += bodyH + 4

        if truncated {
            let toggle = UIButton(type: .custom)
            toggle.setTitle(descExpanded ? "Show less" : "Show more", for: .normal)
            toggle.setTitleColor(UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 1), for: .normal)
            toggle.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
            toggle.contentHorizontalAlignment = .left
            toggle.frame = CGRect(x: padding, y: y, width: bodyW, height: 24)
            toggle.addTarget(self, action: #selector(descToggleTapped), for: .touchUpInside)
            sv.addSubview(toggle); descRowViews.append(toggle)
            y += 28
        }
        y += 6
        return y
    }

    private func heightForText(_ text: String, font: UIFont, width: CGFloat, maxLines: Int) -> CGFloat {
        let l = UILabel()
        l.font = font
        l.numberOfLines = maxLines
        l.text = text
        return ceil(l.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height)
    }

    // Related-videos list. Returns the y after the last row (or startY if empty).
    private func buildRelatedRows(startY: CGFloat, width w: CGFloat) -> CGFloat {
        guard !relatedVideos.isEmpty, let sv = scrollView else { return startY }
        let padding: CGFloat = 12
        var y = startY

        let sep = UIView(frame: CGRect(x: 0, y: y, width: w, height: 0.5))
        sep.backgroundColor = UIColor(white: 0.2, alpha: 1)
        sv.addSubview(sep)
        relatedRowViews.append(sep)
        y += 12

        let header = UILabel()
        header.backgroundColor = .clear
        header.textColor = UIColor(white: 0.95, alpha: 1)
        header.font = UIFont.boldSystemFont(ofSize: 16)
        header.text = "Related videos"
        header.frame = CGRect(x: padding, y: y, width: w - padding * 2, height: 22)
        sv.addSubview(header)
        relatedRowViews.append(header)
        y += 30

        for (i, v) in relatedVideos.enumerated() {
            let row = makeRelatedRow(v, index: i, width: w)
            row.frame = CGRect(x: 0, y: y, width: w, height: 80)
            sv.addSubview(row)
            relatedRowViews.append(row)
            y += 80
        }
        return y
    }

    private func makeRelatedRow(_ v: Video, index: Int, width w: CGFloat) -> UIView {
        let padding: CGFloat = 12
        let row = UIView()

        let thumbW: CGFloat = 120
        let thumbH: CGFloat = 68
        let thumb = AsyncImageView(frame: CGRect(x: padding, y: 6, width: thumbW, height: thumbH))
        thumb.backgroundColor = UIColor(white: 0.12, alpha: 1)
        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = 4
        if !v.thumbnailURL.isEmpty { thumb.load(url: v.thumbnailURL) }
        row.addSubview(thumb)

        if !v.durationText.isEmpty {
            let dur = UILabel()
            dur.backgroundColor = UIColor(white: 0, alpha: 0.75)
            dur.textColor = .white
            dur.font = UIFont.boldSystemFont(ofSize: 10)
            dur.textAlignment = .center
            dur.text = " \(v.durationText) "
            let dW = dur.sizeThatFits(CGSize(width: 100, height: 16)).width + 6
            dur.frame = CGRect(x: thumb.frame.maxX - dW - 4, y: thumb.frame.maxY - 18, width: dW, height: 14)
            dur.layer.cornerRadius = 2
            dur.clipsToBounds = true
            row.addSubview(dur)
        }

        let textX = thumbW + padding + 8
        let textW = w - textX - padding

        let titleL = UILabel()
        titleL.backgroundColor = .clear
        titleL.textColor = UIColor(white: 0.95, alpha: 1)
        titleL.font = UIFont.systemFont(ofSize: 13)
        titleL.numberOfLines = 2
        titleL.text = v.title
        titleL.frame = CGRect(x: textX, y: 6, width: textW, height: 34)
        row.addSubview(titleL)

        let subParts = [v.channelName, v.viewCountText, v.displayPublished].filter { !$0.isEmpty }
        let subL = UILabel()
        subL.backgroundColor = .clear
        subL.textColor = UIColor(white: 0.5, alpha: 1)
        subL.font = UIFont.systemFont(ofSize: 11)
        subL.numberOfLines = 2
        subL.text = subParts.joined(separator: " • ")
        subL.frame = CGRect(x: textX, y: 42, width: textW, height: 30)
        row.addSubview(subL)

        let tapBtn = UIButton(type: .custom)
        tapBtn.frame = CGRect(x: 0, y: 0, width: w, height: 80)
        tapBtn.backgroundColor = .clear
        tapBtn.tag = index
        tapBtn.addTarget(self, action: #selector(relatedRowTapped(_:)), for: .touchUpInside)
        row.addSubview(tapBtn)

        return row
    }

    @objc private func relatedRowTapped(_ sender: UIButton) {
        let idx = sender.tag
        guard idx >= 0, idx < relatedVideos.count else { return }
        let vc = VideoPlayerVC(video: relatedVideos[idx])
        navigationController?.pushViewController(vc, animated: true)
    }

    // MARK: - Share

    private func shareURL() -> String {
        return "https://www.youtube.com/watch?v=\(video.id)"
    }

    @objc private func shareTapped() {
        // UIActionSheet (NOT UIActivityViewController) — iOS-6-reliable; matches our pattern.
        // Build buttons explicitly (the variadic otherButtonTitles: convenience init crashes
        // on the 5.1.5 runtime — same reason addToPlaylistTapped builds buttons one by one).
        let sheet = UIActionSheet()
        sheet.delegate = self
        sheet.title = shareURL()
        sheet.addButton(withTitle: "Copy Link")
        sheet.addButton(withTitle: "Open in Safari")
        let cancelIdx = sheet.addButton(withTitle: "Cancel")
        sheet.cancelButtonIndex = cancelIdx
        sheet.tag = 1
        sheet.show(in: view)
    }

    // MARK: - Add to playlist

    @objc private func addToPlaylistTapped() {
        pendingPlaylists = PlaylistManager.all()
        // Build buttons explicitly: [playlist…] then "New Playlist…" then "Cancel".
        let sheet = UIActionSheet()
        sheet.delegate = self
        sheet.title = "Add to playlist"
        for pl in pendingPlaylists { sheet.addButton(withTitle: pl.name) }
        sheet.addButton(withTitle: "New Playlist\u{2026}")
        let cancelIdx = sheet.addButton(withTitle: "Cancel")
        sheet.cancelButtonIndex = cancelIdx
        sheet.tag = 2
        sheet.show(in: view)
    }

    private func promptNewPlaylist() {
        let alert = UIAlertView()
        alert.delegate = self
        alert.title = "New Playlist"
        alert.message = "Enter a name"
        alert.alertViewStyle = .plainTextInput
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Create")
        alert.cancelButtonIndex = 0
        alert.show()
    }

    // Briefly flash a button's title to confirm an action, then revert.
    private func flash(_ btn: UIButton?, _ text: String, revertTo: String) {
        btn?.setTitle(text, for: .normal)
        let t = Timer(timeInterval: 1.5, target: BlockTarget { [weak btn] in
            btn?.setTitle(revertTo, for: .normal)
        }, selector: #selector(BlockTarget.fire), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
    }

    // MARK: - UIActionSheetDelegate

    func actionSheet(_ actionSheet: UIActionSheet, clickedButtonAt buttonIndex: Int) {
        if actionSheet.tag == 1 {
            // Compare titles (robust to button-index ordering across iOS versions).
            switch actionSheet.buttonTitle(at: buttonIndex) {
            case "Copy Link":
                UIPasteboard.general.string = shareURL()
                flash(shareBtn, "Copied \u{2713}", revertTo: "Share")
            case "Open in Safari":
                if let u = URL(string: shareURL()) { UIApplication.shared.openURL(u) }
            default:
                break
            }
        } else if actionSheet.tag == 2 {
            if buttonIndex < pendingPlaylists.count {
                let pl = pendingPlaylists[buttonIndex]
                PlaylistManager.add(video: video, to: pl.id)
                flash(addPlaylistBtn, "Added \u{2713}", revertTo: "Playlist")
            } else if actionSheet.buttonTitle(at: buttonIndex) == "New Playlist\u{2026}" {
                promptNewPlaylist()
            }
        } else if actionSheet.tag == 3 {
            if buttonIndex < castDevices.count {
                startCasting(to: castDevices[buttonIndex])
            }
        } else if actionSheet.tag == 4 {
            // Quality sheet: button 0 = 360p, then pendingHLSStreams in order, then Cancel.
            guard buttonIndex != actionSheet.cancelButtonIndex else { return }
            if buttonIndex == 0 {
                playTapped()   // the default 360p path (offline copy / direct / proxied)
            } else if buttonIndex - 1 < pendingHLSStreams.count {
                playHLS(pendingHLSStreams[buttonIndex - 1])
            }
        }
    }

    // MARK: - UIAlertViewDelegate (new-playlist name entry)

    func alertView(_ alertView: UIAlertView, clickedButtonAt buttonIndex: Int) {
        guard buttonIndex == 1 else { return }   // 0 = Cancel, 1 = Create
        let name = (alertView.textField(at: 0)?.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let pl = PlaylistManager.create(name: name)
        PlaylistManager.add(video: video, to: pl.id)
        flash(addPlaylistBtn, "Added \u{2713}", revertTo: "Playlist")
    }

    // MARK: - Chromecast (discovery + handshake spike)

    @objc private func castTapped() {
        if castSession != nil { stopCast(); return }
        showCastSpinner()

        let disco = CastDiscovery()
        castDiscovery = disco
        disco.onUpdate = { [weak self] devices in self?.castDevices = devices }
        disco.start()

        // Give mDNS a couple of seconds to resolve, then present whatever we found.
        let t = Timer(timeInterval: 2.5, target: BlockTarget { [weak self] in
            self?.showCastPicker()
        }, selector: #selector(BlockTarget.fire), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
    }

    private func showCastPicker() {
        castDiscovery?.stop()
        showCastGlyph()   // stop the spinner regardless of outcome
        guard !castDevices.isEmpty else {
            let alert = UIAlertView()
            alert.title = "No Chromecast found"
            alert.message = "Make sure a Chromecast is on the same Wi-Fi network."
            alert.addButton(withTitle: "OK")
            alert.cancelButtonIndex = 0
            alert.show()
            return
        }
        let sheet = UIActionSheet()
        sheet.delegate = self
        sheet.title = "Cast to\u{2026}"
        for dev in castDevices { sheet.addButton(withTitle: dev.name) }
        let cancelIdx = sheet.addButton(withTitle: "Cancel")
        sheet.cancelButtonIndex = cancelIdx
        sheet.tag = 3
        sheet.show(in: view)
    }

    private func startCasting(to device: CastDevice) {
        guard let preferred = preferredStream() else {
            statusLabel?.text = "No stream to cast yet"
            statusLabel?.isHidden = false
            return
        }
        // Playback moves to the TV — stop the local player so audio doesn't double up.
        sp.pause()

        // Hand the Chromecast the direct googlevideo MP4 (itag 18/22 = H.264+AAC, which the
        // Default Media Receiver plays natively).
        let session = CastSession(device: device)
        castSession = session
        session.onState = { [weak self] state in
            self?.castTitleLabel?.text = "Casting to \(device.name) — \(state)"
        }
        session.onProgress = { [weak self] cur, dur, playing in
            self?.updateCastProgress(current: cur, duration: dur, playing: playing)
        }
        session.start(mediaURL: preferred.url, contentType: "video/mp4")
        // The glyph stays; while a session is live a tap on it stops casting.
        showCastGlyph()
        showCastPanel(deviceName: device.name)
    }

    @objc private func stopCastTapped() { stopCast() }

    private func stopCast() {
        castSession?.stop()
        castSession = nil
        castDiscovery?.stop()
        castPanel?.isHidden = true
        showCastGlyph()
        // Restore the pre-cast state so the video can be replayed on-device immediately:
        // the big play button over the thumbnail, local controls hidden.
        controlsView?.isHidden = true
        thumbView?.isHidden = false
        playBtn?.isHidden = false
        statusLabel?.isHidden = true
    }

    // MARK: Cast control panel (overlaid on the video area while casting)

    private func showCastPanel(deviceName: String) {
        guard let container = videoContainer else { return }
        // Hide the local playback affordances behind the cast overlay.
        controlsView?.isHidden = true
        playBtn?.isHidden = true
        spinner?.stopAnimating()
        statusLabel?.isHidden = true

        if castPanel == nil { buildCastPanel(in: container) }
        castTitleLabel?.text = "Casting to \(deviceName)\u{2026}"
        castIsPlaying = true
        castPlayPauseBtn?.setImage(UIImage(named: "pause"), for: .normal)
        castScrubber?.value = 0
        castCurLabel?.text = "0:00"
        castDurLabel?.text = "0:00"
        castPanel?.isHidden = false
        container.bringSubviewToFront(castPanel!)
    }

    private func buildCastPanel(in container: UIView) {
        let w = container.bounds.width
        let hgt = container.bounds.height
        let panel = UIView(frame: container.bounds)
        panel.backgroundColor = UIColor(white: 0, alpha: 0.85)
        container.addSubview(panel)
        castPanel = panel

        // "Cast" glyph — the bundled cast PNG, scaled up to fill the 44pt badge.
        let icon = UIImageView(image: UIImage(named: "cast"))
        icon.contentMode = .scaleAspectFit
        icon.frame = CGRect(x: (w - 44) / 2, y: hgt / 2 - 46, width: 44, height: 44)
        panel.addSubview(icon)

        let title = UILabel()
        title.backgroundColor = .clear
        title.textColor = .white
        title.textAlignment = .center
        title.font = UIFont.systemFont(ofSize: 13)
        title.numberOfLines = 2
        title.frame = CGRect(x: 8, y: hgt / 2, width: w - 16, height: 34)
        panel.addSubview(title)
        castTitleLabel = title

        // Stop-casting button, top-right of the panel — replaces the old floating cast glyph
        // (now that the cast icon lives in the auto-hiding control bar, the panel needs its
        // own always-visible stop affordance).
        let stop = UIButton(type: .custom)
        stop.frame = CGRect(x: w - 40, y: 4, width: 36, height: 36)
        stop.setImage(UIImage(named: "close"), for: .normal)
        stop.addTarget(self, action: #selector(stopCastTapped), for: .touchUpInside)
        panel.addSubview(stop)

        // Bottom control bar: [play/pause 44][cur 44] ==slider== [dur 44]
        let barH: CGFloat = 40
        let bar = UIView(frame: CGRect(x: 0, y: hgt - barH, width: w, height: barH))
        bar.backgroundColor = UIColor(white: 0, alpha: 0.4)
        panel.addSubview(bar)

        let pp = UIButton(type: .custom)
        pp.frame = CGRect(x: 0, y: 0, width: 44, height: barH)
        pp.setImage(UIImage(named: "pause"), for: .normal)
        pp.addTarget(self, action: #selector(castTogglePlayPause), for: .touchUpInside)
        bar.addSubview(pp)
        castPlayPauseBtn = pp

        let cur = UILabel()
        cur.backgroundColor = .clear
        cur.textColor = .white
        cur.font = UIFont.systemFont(ofSize: 11)
        cur.textAlignment = .center
        cur.text = "0:00"
        cur.frame = CGRect(x: 44, y: 0, width: 44, height: barH)
        bar.addSubview(cur)
        castCurLabel = cur

        let dur = UILabel()
        dur.backgroundColor = .clear
        dur.textColor = .white
        dur.font = UIFont.systemFont(ofSize: 11)
        dur.textAlignment = .center
        dur.text = "0:00"
        dur.frame = CGRect(x: w - 44, y: 0, width: 44, height: barH)
        bar.addSubview(dur)
        castDurLabel = dur

        let sl = UISlider(frame: CGRect(x: 88, y: 0, width: w - 88 - 44, height: barH))
        sl.minimumValue = 0
        sl.maximumValue = 1
        sl.value = 0
        sl.minimumTrackTintColor = UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 1)
        sl.addTarget(self, action: #selector(castScrubTouchDown), for: .touchDown)
        sl.addTarget(self, action: #selector(castScrubTouchUp), for: [.touchUpInside, .touchUpOutside])
        bar.addSubview(sl)
        castScrubber = sl
    }

    private func updateCastProgress(current: Double, duration: Double, playing: Bool) {
        if duration > 0 { castDuration = duration; castDurLabel?.text = timeString(duration) }
        castCurLabel?.text = timeString(current)
        if castDuration > 0 && !castIsScrubbing {
            castScrubber?.value = Float(current / castDuration)
        }
        castIsPlaying = playing
        castPlayPauseBtn?.setImage(UIImage(named: playing ? "pause" : "play"), for: .normal)
    }

    @objc private func castTogglePlayPause() {
        if castIsPlaying { castSession?.pause() } else { castSession?.play() }
        castIsPlaying = !castIsPlaying
        castPlayPauseBtn?.setImage(UIImage(named: castIsPlaying ? "pause" : "play"), for: .normal)
    }

    @objc private func castScrubTouchDown() { castIsScrubbing = true }

    @objc private func castScrubTouchUp() {
        castIsScrubbing = false
        guard castDuration > 0, let v = castScrubber?.value else { return }
        castSession?.seek(to: Double(v) * castDuration)
    }

    // MARK: - Playback controls UI

    // A 40px control bar pinned to the bottom of the video area: play/pause, elapsed
    // time, scrubber, total time. Hidden until playback begins.
    private func buildControls(width w: CGFloat, videoHeight videoH: CGFloat, in container: UIView) {
        let barH: CGFloat = 40
        let bar = UIView(frame: CGRect(x: 0, y: videoH - barH, width: w, height: barH))
        bar.backgroundColor = UIColor(white: 0, alpha: 0.45)
        bar.isHidden = true
        container.addSubview(bar)
        controlsView = bar

        let pp = UIButton(type: .custom)
        pp.frame = CGRect(x: 0, y: 0, width: 40, height: barH)
        pp.setImage(UIImage(named: "pause"), for: .normal)
        pp.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)
        bar.addSubview(pp)
        playPauseBtn = pp

        // Elapsed time — left-aligned so it hugs the play button (no dead gap between them).
        let cur = UILabel()
        cur.backgroundColor = .clear
        cur.textColor = .white
        cur.font = UIFont.systemFont(ofSize: 11)
        cur.textAlignment = .left
        cur.text = "0:00"
        bar.addSubview(cur)
        currentTimeLabel = cur

        // Total time — right-aligned so it hugs the cast/fullscreen buttons (mirrors the left).
        let dur = UILabel()
        dur.backgroundColor = .clear
        dur.textColor = .white
        dur.font = UIFont.systemFont(ofSize: 11)
        dur.textAlignment = .right
        dur.text = "0:00"
        bar.addSubview(dur)
        durationLabel = dur

        let sl = UISlider()
        sl.minimumValue = 0
        sl.maximumValue = 1
        sl.value = 0
        sl.minimumTrackTintColor = UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 1)
        sl.addTarget(self, action: #selector(scrubChanged), for: .valueChanged)
        sl.addTarget(self, action: #selector(scrubTouchDown), for: .touchDown)
        sl.addTarget(self, action: #selector(scrubTouchUp), for: [.touchUpInside, .touchUpOutside])
        bar.addSubview(sl)
        scrubber = sl

        // Cast button — lives in the bar just before the fullscreen button.
        let cast = UIButton(type: .custom)
        cast.setImage(UIImage(named: "cast"), for: .normal)
        cast.addTarget(self, action: #selector(castTapped), for: .touchUpInside)
        bar.addSubview(cast)
        castBtn = cast

        // Spinner shown in place of the cast glyph while discovery runs (subview of the button).
        let castSpin = UIActivityIndicatorView(style: .white)
        castSpin.hidesWhenStopped = true
        castSpin.center = CGPoint(x: 18, y: barH / 2)
        cast.addSubview(castSpin)
        castBtnSpinner = castSpin

        let fs = UIButton(type: .custom)
        fs.setImage(UIImage(named: "fullscreen"), for: .normal)
        fs.addTarget(self, action: #selector(fullscreenTapped), for: .touchUpInside)
        bar.addSubview(fs)
        fsButton = fs

        // Quality button — opens the 360p/HLS quality sheet. Left of the cast button.
        let hd = UIButton(type: .custom)
        hd.setImage(UIImage(named: "hd"), for: .normal)
        hd.addTarget(self, action: #selector(hdTapped), for: .touchUpInside)
        bar.addSubview(hd)
        hdBtn = hd

        layoutControls(width: w)
    }

    // Position the control bar's children for a given bar width (bar frame set by caller).
    // Layout: [play 36][cur 46] ===slider=== [dur 46][hd 36][cast 36][fullscreen 36]
    // Times are left/right-aligned so they hug the adjacent buttons — spacing is uniform
    // on both ends and the slider is centered between them.
    private func layoutControls(width w: CGFloat) {
        let barH: CGFloat = 40
        let btnW: CGFloat = 36
        let timeW: CGFloat = 46
        playPauseBtn?.frame = CGRect(x: 0, y: 0, width: btnW, height: barH)
        currentTimeLabel?.frame = CGRect(x: btnW, y: 0, width: timeW, height: barH)
        fsButton?.frame = CGRect(x: w - btnW, y: 0, width: btnW, height: barH)
        castBtn?.frame = CGRect(x: w - btnW * 2, y: 0, width: btnW, height: barH)
        hdBtn?.frame = CGRect(x: w - btnW * 3, y: 0, width: btnW, height: barH)
        durationLabel?.frame = CGRect(x: w - btnW * 3 - timeW, y: 0, width: timeW, height: barH)
        let leftEdge = btnW + timeW
        let rightEdge = btnW * 3 + timeW
        // A UISlider reserves ~half its thumb width of empty space at each end of its frame
        // before the visible track begins, so the track looks like it has more padding than
        // the tight play/time gaps. Bleed the slider frame outward by that inset so the
        // visible track lines up with the time-label edges (matching the rest of the bar).
        let thumbInset: CGFloat = 12
        scrubber?.frame = CGRect(x: leftEdge - thumbInset, y: 0,
                                 width: (w - leftEdge - rightEdge) + thumbInset * 2, height: barH)
    }

    private func showSpinner() { spinner?.startAnimating() }
    private func hideSpinner() { spinner?.stopAnimating() }

    private func showControls() {
        controlsView?.isHidden = false
        playPauseBtn?.setImage(UIImage(named: sp.isPlaying ? "pause" : "play"), for: .normal)
        updateProgress()
        startProgressTimer()
        armControlsHideTimer()
    }

    // Hide the control bar (and stop the 0.5s progress ticker while hidden — a net perf win,
    // no need to update a bar nobody can see). Called by the auto-hide timer / tap toggle.
    private func hideControls() {
        controlsView?.isHidden = true
        stopProgressTimer()
    }

    // Toggle the bar on a tap anywhere on the video (only while a video is loaded and not
    // casting — the cast panel has its own controls).
    @objc private func videoAreaTapped() {
        guard sp.isActive(video.id), castSession == nil else { return }
        if controlsView?.isHidden ?? true {
            showControls()
        } else {
            hideControls()
        }
    }

    // Double-tap left/right → skip 15s back/forward, with a fading on-screen indicator.
    @objc private func seekBackwardTapped() {
        guard sp.isActive(video.id), castSession == nil else { return }
        sp.seek(bySeconds: -15)
        showSeekIndicator(forward: false)
        showControls()
    }

    @objc private func seekForwardTapped() {
        guard sp.isActive(video.id), castSession == nil else { return }
        sp.seek(bySeconds: 15)
        showSeekIndicator(forward: true)
        showControls()
    }

    // A ~96pt rounded plate on the left/right of the video showing the rewind/forward
    // glyph + "15s", fading in then out. Hosted in the fullscreen overlay when active so
    // it follows rotation, else in the video container.
    private func showSeekIndicator(forward: Bool) {
        guard let host = fsOverlay ?? videoContainer else { return }
        seekIndicator?.removeFromSuperview()

        let size: CGFloat = 96
        let cont = UIView()
        cont.backgroundColor = UIColor(white: 0, alpha: 0.6)
        cont.layer.cornerRadius = size / 2
        let cx = forward ? host.bounds.width * 0.75 : host.bounds.width * 0.25
        let cy = host.bounds.height / 2
        cont.frame = CGRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size)

        let iv = UIImageView(image: UIImage(named: forward ? "forward" : "rewind"))
        iv.contentMode = .scaleAspectFit
        iv.frame = CGRect(x: (size - 32) / 2, y: 20, width: 32, height: 32)
        cont.addSubview(iv)

        let lbl = UILabel(frame: CGRect(x: 0, y: 54, width: size, height: 20))
        lbl.backgroundColor = .clear
        lbl.textColor = .white
        lbl.font = UIFont.boldSystemFont(ofSize: 13)
        lbl.textAlignment = .center
        lbl.text = "15s"
        cont.addSubview(lbl)

        host.addSubview(cont)
        seekIndicator = cont

        cont.alpha = 0
        UIView.animate(withDuration: 0.15, animations: { cont.alpha = 1 }, completion: { _ in
            UIView.animate(withDuration: 0.35, delay: 0.3, options: [], animations: {
                cont.alpha = 0
            }, completion: { [weak self] _ in
                cont.removeFromSuperview()
                if self?.seekIndicator === cont { self?.seekIndicator = nil }
            })
        })
    }

    // Arm a one-shot 5s timer to auto-hide the controls. Stays visible while PAUSED
    // (re-arming does nothing when paused) so a paused user isn't left with a bare frame.
    private func armControlsHideTimer() {
        cancelControlsHideTimer()
        guard sp.isPlaying else { return }
        let t = Timer(timeInterval: 5.0, target: BlockTarget { [weak self] in
            self?.hideControls()
        }, selector: #selector(BlockTarget.fire), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
        objc_setAssociatedObject(self, &controlsHideKey, t, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func cancelControlsHideTimer() {
        if let t = objc_getAssociatedObject(self, &controlsHideKey) as? Timer { t.invalidate() }
        objc_setAssociatedObject(self, &controlsHideKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func startProgressTimer() {
        if let t = objc_getAssociatedObject(self, &progressTimerKey) as? Timer { t.invalidate() }
        let t = Timer(timeInterval: 0.5, target: BlockTarget { [weak self] in
            self?.updateProgress()
        }, selector: #selector(BlockTarget.fire), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        objc_setAssociatedObject(self, &progressTimerKey, t, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func stopProgressTimer() {
        if let t = objc_getAssociatedObject(self, &progressTimerKey) as? Timer { t.invalidate() }
        objc_setAssociatedObject(self, &progressTimerKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func updateProgress() {
        guard sp.isReady else { return }
        let dur = sp.durationSeconds
        let cur = sp.currentSeconds
        guard dur > 0 else { return }
        durationLabel?.text = timeString(dur)
        if !isScrubbing {
            scrubber?.value = Float(cur / dur)
            currentTimeLabel?.text = timeString(cur)
        }
        // Keep button glyph in sync with actual rate.
        playPauseBtn?.setImage(UIImage(named: sp.isPlaying ? "pause" : "play"), for: .normal)
    }

    private func timeString(_ seconds: Double) -> String {
        let s = Int(seconds)
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    @objc private func togglePlayPause() {
        sp.togglePlayPause()
        playPauseBtn?.setImage(UIImage(named: sp.isPlaying ? "pause" : "play"), for: .normal)
        // Re-arm the auto-hide (arms only if now playing; stays visible if now paused).
        armControlsHideTimer()
    }

    @objc private func scrubTouchDown() {
        isScrubbing = true
        cancelControlsHideTimer()   // don't hide the bar mid-scrub
    }

    @objc private func scrubChanged() {
        let dur = sp.durationSeconds
        guard dur > 0, let v = scrubber?.value else { return }
        currentTimeLabel?.text = timeString(Double(v) * dur)
    }

    @objc private func scrubTouchUp() {
        if let v = scrubber?.value { sp.seek(toFraction: Double(v)) }
        isScrubbing = false
        armControlsHideTimer()
    }

    // MARK: - Stream loading

    // updateStatus == false when called purely to fetch the description while playback
    // is already live (reopened from the mini bar) — leaves the status label untouched.
    private func loadStreams(updateStatus: Bool = true) {
        didRequestStreams = true
        // Already downloaded — no network needed, play offline.
        if DownloadManager.isDownloaded(video.id) {
            if updateStatus {
                statusLabel?.text = "Downloaded \u{2022} tap > to play"
                statusLabel?.isHidden = false
            }
            return
        }

        if updateStatus {
            statusLabel?.text = "Loading..."
            statusLabel?.isHidden = false
        }

        YoutubeAPI.getStreams(videoId: video.id) { [weak self] streams, _, desc in
            guard let self = self else { return }
            self.streams = streams
            if updateStatus {
                self.statusLabel?.text = streams.isEmpty ? "No streams available" : "Tap > to play"
            }
            if !desc.isEmpty {
                self.descriptionText = desc
                self.relayout()
            }
        }
    }

    // MARK: - Stream selection

    private func preferredStream() -> VideoStream? {
        // Prefer muxed 360p MP4 (itag 18) — plays on AVPlayer, small, castable.
        return streams.first { $0.itag == 18 }
            ?? streams.first { $0.mimeType.contains("mp4") && !$0.mimeType.contains("av01") }
            ?? streams.first { $0.mimeType.contains("video") }
            ?? streams.first
    }

    // MARK: - HLS quality selection (>360p via local transmux)

    // The DASH audio track backing every HLS quality. indexEnd > 0 = fMP4 with a sidx head.
    private func audioStreamForHLS() -> VideoStream? {
        return streams.first { $0.itag == 140 && $0.indexEnd > 0 }
    }

    // Video-only H.264 streams the transmux pipeline can serve, ascending quality
    // (480p, 720p, 1080p). Empty when the audio track is missing (no way to mux).
    private func hlsQualityOptions() -> [VideoStream] {
        guard audioStreamForHLS() != nil else { return [] }
        return [135, 136, 137].compactMap { tag in
            streams.first { $0.itag == tag && $0.indexEnd > 0 && $0.mimeType.contains("avc1") }
        }
    }

    @objc private func hdTapped() {
        let opts = hlsQualityOptions()
        guard !opts.isEmpty else {
            let alert = UIAlertView()
            alert.title = "Quality"
            alert.message = streams.isEmpty ? "Still loading streams..."
                                            : "No higher qualities available for this video."
            alert.addButton(withTitle: "OK")
            alert.cancelButtonIndex = 0
            alert.show()
            return
        }
        pendingHLSStreams = opts
        let sheet = UIActionSheet()
        sheet.delegate = self
        sheet.title = "Quality"
        sheet.addButton(withTitle: "360p")
        for s in opts { sheet.addButton(withTitle: s.quality.isEmpty ? "itag \(s.itag)" : s.quality) }
        let cancelIdx = sheet.addButton(withTitle: "Cancel")
        sheet.cancelButtonIndex = cancelIdx
        sheet.tag = 4
        sheet.show(in: view)
    }

    // Play a >360p quality through the local HLS transmux pipeline. Goes through StreamProxy
    // on ALL iOS versions (the transmux runs locally — a direct googlevideo URL can't help),
    // with the proxy-length readiness window: the first playlist request triggers two ranged
    // head fetches + parse before AVPlayer even sees the segment list. Falls back to a 360p
    // download-then-play via tryStream's onFail, same as the proxied 360p path.
    private func playHLS(_ vStream: VideoStream) {
        guard let aStream = audioStreamForHLS(),
              let local = StreamProxy.shared.hlsURL(videoURL: vStream.url, audioURL: aStream.url,
                                                    videoIndexEnd: vStream.indexEnd,
                                                    audioIndexEnd: aStream.indexEnd) else {
            statusLabel?.text = "Quality unavailable"
            statusLabel?.isHidden = false
            return
        }
        playBtn?.isHidden = true
        statusLabel?.text = "Loading stream..."
        statusLabel?.isHidden = false
        showSpinner()
        let fallback = preferredStream()?.url ?? vStream.url
        // 120 ticks = 30s: first-play needs 2 head fetches + 2 ranged GETs + transmux per
        // segment before AVPlayer reports ready — generous headroom on an iPhone 4S.
        tryStream(urlStr: local.absoluteString, fallbackDownload: fallback, maxTicks: 120)
    }

    // MARK: - Playback

    @objc private func playTapped() {
        // Offline copy takes priority.
        if DownloadManager.isDownloaded(video.id) {
            playBtn?.isHidden = true
            statusLabel?.isHidden = true
            startPlayback(url: URL(fileURLWithPath: DownloadManager.filePath(for: video.id)), isLocal: true)
            return
        }

        guard let preferred = preferredStream() else {
            statusLabel?.text = "Still loading streams..."
            statusLabel?.isHidden = false
            return
        }

        playBtn?.isHidden = true
        statusLabel?.isHidden = false
        showSpinner()

        // iOS 6 Secure Transport cannot negotiate GCM/CHACHA20 ciphers with googlevideo.com,
        // so AVPlayer cannot connect to it directly. Route AVPlayer through the local
        // HTTP->HTTPS proxy (StreamProxy): AVPlayer talks plain HTTP to 127.0.0.1, the proxy
        // forwards to googlevideo over libcurl+OpenSSL (which speaks the required ciphers).
        // iOS 7+ supports the ciphers natively, so it streams the googlevideo URL directly.
        // Either way, a quick download-then-play fallback covers a stream that won't start.
        // maxTicks are in 0.25s poll units: 16 = 4s (direct), 80 = 20s (proxy).
        let iosVersion = (UIDevice.current.systemVersion as NSString).floatValue
        statusLabel?.text = "Loading stream..."
        if iosVersion >= 7.0 {
            tryStream(urlStr: preferred.url, fallbackDownload: preferred.url, maxTicks: 16)
        } else if let local = StreamProxy.shared.localURL(for: preferred.url) {
            // Give the proxy path more time — the first read primes a TLS handshake to
            // googlevideo through libcurl before AVPlayer sees any bytes.
            tryStream(urlStr: local.absoluteString, fallbackDownload: preferred.url, maxTicks: 80)
        } else {
            statusLabel?.text = "Downloading..."
            download(url: preferred.url, autoPlay: true)
        }
    }

    @objc private func downloadTapped() {
        guard !DownloadManager.isDownloaded(video.id) else { return }
        guard let preferred = preferredStream() else {
            statusLabel?.text = "Still loading streams..."
            statusLabel?.isHidden = false
            return
        }
        downloadBtn?.isEnabled = false
        downloadBtn?.setTitle("Downloading...", for: .normal)
        download(url: preferred.url, autoPlay: false)
    }

    // Load a URL into the singleton, attach the shared layer, and play once ready.
    private func startPlayback(url: URL, isLocal: Bool) {
        let resume = DownloadManager.position(for: video.id)
        sp.load(video: video, url: url, isLocal: isLocal, resume: resume, artwork: thumbView?.image)
        attachLayer()
        pollUntilReady(maxTicks: 40, interval: 0.25, onReady: { [weak self] in
            guard let self = self else { return }
            self.hideSpinner()
            self.thumbView?.isHidden = true
            self.statusLabel?.isHidden = true
            self.sp.applyResumeAndPlay()
            self.showControls()
        }, onFail: { [weak self] in
            guard let self = self else { return }
            self.hideSpinner()
            self.statusLabel?.text = "Playback failed"
            self.statusLabel?.isHidden = false
            self.playBtn?.isHidden = false
        })
    }

    // Direct/proxied streaming with a quick download-then-play fallback.
    private func tryStream(urlStr: String, fallbackDownload: String, maxTicks: Int = 16) {
        guard let nsurl = URL(string: urlStr) else {
            statusLabel?.text = "Invalid stream URL"
            statusLabel?.isHidden = false
            playBtn?.isHidden = false
            return
        }
        sp.load(video: video, url: nsurl, isLocal: false, resume: DownloadManager.position(for: video.id), artwork: thumbView?.image)
        attachLayer()
        pollUntilReady(maxTicks: maxTicks, interval: 0.25, onReady: { [weak self] in
            guard let self = self else { return }
            self.hideSpinner()
            self.thumbView?.isHidden = true
            self.statusLabel?.isHidden = true
            self.sp.applyResumeAndPlay()
            self.showControls()
        }, onFail: { [weak self] in
            guard let self = self else { return }
            // Keep the spinner running — we're falling through to a download attempt.
            // Tear down the never-ready item FIRST: a timed-out (not failed) item keeps
            // AVPlayer fetching in the background (starving the download), and its non-nil
            // item makes isActive() true so the completion handler would never auto-play.
            self.sp.abandonLoad()
            self.detachLayer()
            self.statusLabel?.text = "Downloading..."
            self.statusLabel?.isHidden = false
            self.download(url: fallbackDownload, autoPlay: true)
        })
    }

    // Poll the singleton's item status; fire onReady when ready, onFail on failure/timeout.
    private func pollUntilReady(maxTicks: Int, interval: TimeInterval,
                                onReady: @escaping () -> Void, onFail: @escaping () -> Void) {
        if let t = objc_getAssociatedObject(self, &timerKey) as? Timer { t.invalidate() }
        var count = 0
        let timer = Timer(timeInterval: interval, target: BlockTarget { [weak self] in
            guard let self = self else { return }
            count += 1
            if self.sp.isReady {
                if let t = objc_getAssociatedObject(self, &timerKey) as? Timer { t.invalidate() }
                onReady()
            } else if self.sp.isFailed || count > maxTicks {
                if let t = objc_getAssociatedObject(self, &timerKey) as? Timer { t.invalidate() }
                onFail()
            }
        }, selector: #selector(BlockTarget.fire), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        objc_setAssociatedObject(self, &timerKey, timer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // Hand the transfer to DownloadManager (which owns the completion), then poll for UI.
    // Because the manager — not this VC — holds the curl completion, the download keeps
    // running and registers as complete even after this VC is popped.
    private func download(url: String, autoPlay: Bool) {
        DownloadManager.startDownload(video, url: url)
        observeDownload(autoPlay: autoPlay)
    }

    // VC-owned poll timer that mirrors the manager-owned download's state into the UI.
    // Safe to lose (it's torn down on disappear) — the transfer itself lives in the manager.
    private func observeDownload(autoPlay: Bool) {
        if let t = objc_getAssociatedObject(self, &downloadPollKey) as? Timer { t.invalidate() }
        let t = Timer(timeInterval: 0.5, target: BlockTarget { [weak self] in
            guard let self = self else { return }
            if DownloadManager.isDownloading(self.video.id) {
                let pct = Int(DownloadManager.progress(for: self.video.id) * 100)
                self.statusLabel?.text = "Downloading \(pct)%..."
                self.statusLabel?.isHidden = false
                if !autoPlay { self.downloadBtn?.setTitle("Downloading \(pct)%...", for: .normal) }
                return
            }
            // Transfer finished (success or failure) — stop polling and resolve the UI.
            if let t = objc_getAssociatedObject(self, &downloadPollKey) as? Timer { t.invalidate() }
            if DownloadManager.isDownloaded(self.video.id) {
                self.updateDownloadButton()
                if autoPlay && !self.sp.isActive(self.video.id) {
                    self.statusLabel?.isHidden = true
                    self.thumbView?.isHidden = true
                    self.startPlayback(url: URL(fileURLWithPath: DownloadManager.filePath(for: self.video.id)), isLocal: true)
                } else if !autoPlay {
                    self.hideSpinner()
                    self.statusLabel?.text = "Saved for offline"
                    self.statusLabel?.isHidden = false
                }
            } else {
                self.hideSpinner()
                self.statusLabel?.text = "Download failed"
                self.statusLabel?.isHidden = false
                self.playBtn?.isHidden = false
                self.updateDownloadButton()
            }
        }, selector: #selector(BlockTarget.fire), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        objc_setAssociatedObject(self, &downloadPollKey, t, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // MARK: - Fullscreen

    @objc private func fullscreenTapped() {
        guard sp.isActive(video.id) else {
            statusLabel?.text = "Start playback first"
            statusLabel?.isHidden = false
            return
        }
        if fsOverlay == nil {
            #if IOS8_TARGET
            if UIDevice.current.userInterfaceIdiom == .pad {
                // iPad's window rotates natively — UIScreen.main.bounds already reflects the
                // current orientation, so the overlay just fills it at angle 0 (no manual
                // rotate transform). Works for both landscape and portrait device states.
                setFullscreen(true, angle: 0)
                return
            }
            #endif
            if sp.isPortraitVideo {
                // Short video → portrait fullscreen, no rotation.
                setFullscreen(true, angle: 0)
            } else {
                // Match the current device orientation if it's already landscape.
                let o = UIDevice.current.orientation
                let angle: CGFloat = (o == .landscapeRight) ? CGFloat(-Double.pi / 2) : CGFloat(Double.pi / 2)
                setFullscreen(true, angle: angle)
            }
        } else {
            setFullscreen(false, angle: 0)
        }
    }

    private func enterFullscreen() {
        guard sp.isActive(video.id), let window = view.window else { return }
        let pLayer = sp.layer

        // The app is portrait-locked, so UIScreen.main.bounds is always the portrait
        // (320x568) frame. The overlay is sized to landscape (dims swapped) and rotated
        // to fill the screen — this is what makes the controls span the full width.
        let screen = UIScreen.main.bounds
        let overlay = UIView()
        overlay.backgroundColor = .black
        #if IOS8_TARGET
        if UIDevice.current.userInterfaceIdiom == .pad {
            // iPad: window already rotated by the OS → overlay fills the (already correctly
            // oriented) screen bounds upright, no rotation transform. viewWillTransition /
            // relayoutForRotation resizes this overlay on subsequent rotations.
            overlay.frame = CGRect(x: 0, y: 0, width: screen.width, height: screen.height)
            overlay.transform = CGAffineTransform.identity
        } else if sp.isPortraitVideo {
            overlay.bounds = CGRect(x: 0, y: 0, width: screen.width, height: screen.height)
            overlay.center = CGPoint(x: screen.midX, y: screen.midY)
            overlay.transform = CGAffineTransform.identity
        } else {
            overlay.bounds = CGRect(x: 0, y: 0, width: screen.height, height: screen.width)
            overlay.center = CGPoint(x: screen.midX, y: screen.midY)
            overlay.transform = CGAffineTransform(rotationAngle: fsAngle)
        }
        #else
        if sp.isPortraitVideo {
            // Short video: a full portrait overlay, no rotation — fills the upright screen.
            overlay.bounds = CGRect(x: 0, y: 0, width: screen.width, height: screen.height)
            overlay.center = CGPoint(x: screen.midX, y: screen.midY)
            overlay.transform = CGAffineTransform.identity
        } else {
            overlay.bounds = CGRect(x: 0, y: 0, width: screen.height, height: screen.width)
            overlay.center = CGPoint(x: screen.midX, y: screen.midY)
            overlay.transform = CGAffineTransform(rotationAngle: fsAngle)
        }
        #endif
        window.addSubview(overlay)
        fsOverlay = overlay

        // Hide the system status bar (the portrait clock at the top would otherwise
        // float over the rotated video — it can't rotate while the app is portrait-locked).
        setFSStatusBar(hidden: true)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pLayer.frame = overlay.bounds
        pLayer.videoGravity = AVLayerVideoGravity.resizeAspect
        overlay.layer.addSublayer(pLayer)
        CATransaction.commit()

        // Transparent tap-catcher fills the overlay so tapping in fullscreen toggles the
        // bar too. Added FIRST so it sits behind the controls bar + cast button.
        if let tap = tapCatcher {
            tap.frame = overlay.bounds
            overlay.addSubview(tap)
        }

        // Move the controls bar into the (rotated) overlay so it's usable in fullscreen.
        // Reparent UNCONDITIONALLY even when hidden — otherwise a tap in fullscreen would
        // reveal the bar back in the (portrait) container behind the overlay. The cast +
        // fullscreen buttons are children of the bar, so they ride along automatically.
        if let bar = controlsView {
            let barH: CGFloat = 40
            bar.frame = CGRect(x: 0, y: overlay.bounds.height - barH, width: overlay.bounds.width, height: barH)
            overlay.addSubview(bar)
            layoutControls(width: overlay.bounds.width)
        }
    }

    private func setFSStatusBar(hidden: Bool) {
        fsActive = hidden
        let v = (UIDevice.current.systemVersion as NSString).floatValue
        if v >= 7.0 { setNeedsStatusBarAppearanceUpdate() }   // iOS 7+ only — crashes on iOS 6
        UIApplication.shared.setStatusBarHidden(hidden, with: .fade)
    }

    private func exitFullscreen() {
        guard let overlay = fsOverlay else { return }
        setFSStatusBar(hidden: false)
        let pLayer = sp.layer
        if let container = videoContainer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pLayer.frame = container.bounds
            if let thumbLayer = thumbView?.layer {
                container.layer.insertSublayer(pLayer, below: thumbLayer)
            } else {
                container.layer.addSublayer(pLayer)
            }
            CATransaction.commit()
        }
        // Restore the tap-catcher into the container (below the play button / controls / cast).
        if let tap = tapCatcher, let container = videoContainer {
            tap.frame = container.bounds
            container.addSubview(tap)
        }
        // Restore the controls bar back into the video container.
        if let bar = controlsView, let container = videoContainer {
            let w = container.bounds.width
            let barH: CGFloat = 40
            bar.frame = CGRect(x: 0, y: container.bounds.height - barH, width: w, height: barH)
            container.addSubview(bar)
            layoutControls(width: w)
        }
        overlay.removeFromSuperview()
        fsOverlay = nil
    }
}

// MARK: - Timer helper (avoids retain cycles with closures on iOS 6)

private var timerKey = "timerKey"
private var progressTimerKey = "progressTimerKey"
private var downloadPollKey = "downloadPollKey"
private var controlsHideKey = "controlsHideKey"

private class BlockTarget: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}

// MARK: - Double-tap seek view

// Transparent overlay over the video that distinguishes single vs double taps WITHOUT a
// UITapGestureRecognizer (which conflicts with button taps on iOS 6). A double tap on the
// left third seeks back, on the right third seeks forward; single taps and center double
// taps fall through to onSingleTap (toggle controls). A single tap is deferred ~0.28s so a
// following second tap can cancel it (via UITouch.tapCount, iOS 2+).
private class SeekTapView: UIView {
    var onSingleTap: (() -> Void)?
    var onSeekBackward: (() -> Void)?
    var onSeekForward: (() -> Void)?
    private var pendingSingle: Timer?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        if touch.tapCount >= 2 {
            pendingSingle?.invalidate(); pendingSingle = nil
            let x = touch.location(in: self).x
            let w = bounds.width
            if x < w * 0.35 { onSeekBackward?() }
            else if x > w * 0.65 { onSeekForward?() }
            else { onSingleTap?() }
        } else {
            pendingSingle?.invalidate()
            let t = Timer(timeInterval: 0.28, target: BlockTarget { [weak self] in
                self?.pendingSingle = nil
                self?.onSingleTap?()
            }, selector: #selector(BlockTarget.fire), userInfo: nil, repeats: false)
            RunLoop.main.add(t, forMode: .common)
            pendingSingle = t
        }
    }
}
