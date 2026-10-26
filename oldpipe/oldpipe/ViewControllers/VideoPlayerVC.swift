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
    // Set when an attempt failed hard (AVPlayerItem.status == .failed), which usually means
    // the resolved URL itself is bad (expired signature, unplayable format). The next play
    // tap then re-resolves the player response instead of replaying the same broken URL.
    private var streamsStale = false


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
    // Whether the quality sheet's row 0 was the direct muxed "360p" entry — absent when the
    // player response has no muxed format, in which case the rows map 1:1 onto pendingHLSStreams.
    private var qualitySheetMuxedRow = false
    // Row indices in the top-level sheet. Each row opens a submenu; quality and captions are
    // dropped when the video has none, so the indices have to be captured as the sheet is
    // built rather than assumed. -1 = row absent.
    private var qualitySheetIndex = -1
    private var captionsSheetIndex = -1
    private var speedSheetIndex = -1
    // What the top-level sheet reports next to "Quality:". Tracks the user's pick (or the
    // automatic one) rather than being derived, because the playing stream is owned by the
    // singleton and a downloaded copy has no itag at all. Reset per video.
    private var activeQualityLabel = "Auto"
    // The itag behind that label (StreamTiers.muxed360 for the direct 360p row). Once a tier is
    // in effect for this video, it wins over Settings > Default Video Quality — retrying after a
    // dropped stream, or picking 360p by hand with a default of 720p, must not bounce back to
    // the default. Mirrored onto the singleton so its reconnect watchdog re-resolves the same
    // tier. nil = nothing has played yet. Reset per video.
    private var activeItag: Int?

    // Captions. The track list arrives with the streams (same player response); cues are
    // fetched only when the user picks a track. Rendered into captionPlate/captionLabel by
    // captionTick() — AVPlayer cannot render external subtitles on iOS 6.
    private var captionTracks: [CaptionTrack] = []
    private var captionCues: [CaptionCue] = []
    private var activeCaptionIndex = -1   // index into captionTracks, -1 = off
    private var captionCueIndex = -1
    private var captionPlate: UIView?
    private var captionLabel: UILabel?

    // Progress of one asynchronously-loaded section. `unavailable` is deliberately distinct
    // from `ready`-with-nothing and from `failed`: it means the server answered that there is
    // nothing to show, so the UI must say so instead of offering a retry.
    private enum LoadState {
        case idle, loading, ready, failed, unavailable
    }

    // Everything below the meta line is laid out by relayout() from contentBelowMetaY:
    // description (below meta) → download button → share row → Related/Comments tabs. The
    // description and related arrive asynchronously (in either order) and the description
    // can expand/collapse, so relayout() repositions the action buttons each time.
    private var contentBelowMetaY: CGFloat = 0
    private var descriptionText = ""
    private var descExpanded = false
    private var descRowViews: [UIView] = []
    private var relatedVideos: [Video] = []
    private var relatedState = LoadState.idle

    // Chapters, shown as tappable rows above the description. The watch-page list and the
    // description arrive from two different calls in either order, so the authored list is
    // kept apart from what is actually displayed and refreshChapters() re-picks a winner
    // each time one of them lands.
    private var apiChapters: [Chapter] = []
    private var chapters: [Chapter] = []
    private var chaptersExpanded = false

    // The tab section lives in its own container so that a description expand/collapse —
    // which only moves it down the page — costs one frame assignment instead of rebuilding
    // every comment row. Its contents are rebuilt only when the data behind them changed.
    private var tabContainer: UIView?
    private var tabContentDirty = true
    private var tabContentWidth: CGFloat = 0

    // Bumped whenever this VC swaps to a different video (playlist auto-advance). Every
    // async completion captures it and bails if it no longer matches, so a response for the
    // previous video can't append its comments onto the new one.
    private var contentGen = 0

    // Related / Comments tab strip at the bottom of the page. Comments are fetched lazily
    // (first time the tab is opened) in batches of 20, each batch handed back with the token
    // for the next one; the token for the FIRST batch rides in on the related-videos
    // response, which is the same watch-page call.
    private var detailTab = 0            // 0 = Related, 1 = Comments
    private var comments: [Comment] = []
    private var commentsToken = ""       // next batch ("" = none left / not known yet)
    private var commentsState = LoadState.idle
    // Replies are fetched on demand, one thread at a time, and kept keyed by parent id so
    // that a relayout() (description toggle, tab switch, next batch) does not lose them.
    // Replies arrive 10 on the first page then ~50 per page after that, so a thread
    // advertising "962 replies" needs its own continuation chain — kept per parent id
    // alongside the replies themselves.
    private var expandedReplies: [String: [Comment]] = [:]
    private var replyNextToken: [String: String] = [:]
    private var replyStates: [String: LoadState] = [:]
    // Wrapping a comment body is the expensive part of laying the list out, and relayout()
    // can fire for reasons unrelated to the comments. Measured once per comment per width.
    private var commentBodyHeights: [String: CGFloat] = [:]

    private var sp: VideoPlayer { return VideoPlayer.shared }

    // UI
    private var scrollView: UIScrollView?
    private var thumbView: AsyncImageView?
    private var playBtn: UIButton?
    private var statusLabel: UILabel?
    private var spinner: UIActivityIndicatorView?
    private var titleLabel: CopyableLabel?
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
    // Hosts action sheets while fullscreen is up on iOS 8+ (see ensureSheetWindow).
    private var sheetWindow: UIWindow?

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
            observeDownload()
        }
        // Same for a Save to Photos, which reports on the Share button. One that finished while
        // we were away must not leave its last "Saving 90%" there.
        if PhotoExporter.shared.isBusy(video.id) {
            observePhotoExport()
        } else {
            shareBtn?.setTitle("Share", for: .normal)
        }

        // Fetch related videos immediately on open (once per VC instance).
        if relatedState == .idle { loadRelated() }

        // Own the singleton's autoplay-advance callback while we're the frontmost player,
        // so a playlist auto-advance swaps this VC's content in place.
        sp.onAdvance = { [weak self] v in self?.handleAutoAdvance(v) }

        // Same ownership deal for the mid-playback recovery callback: report what the
        // watchdog is doing rather than leaving a frozen frame with no explanation.
        sp.onRecovery = { [weak self] state in self?.handleRecovery(state) }

        // A speed that the stream turns out not to hold is refused after the fact, so the
        // singleton has to be able to reach us to say so.
        sp.onRateReverted = { [weak self] in self?.handleRateReverted() }

        // Captions survive a push/pop of another VC (cues stay parsed) — restart the ticker
        // that viewWillDisappear stopped.
        if activeCaptionIndex >= 0, !captionCues.isEmpty {
            captionCueIndex = -1
            ensureCaptionPlate()
            startCaptionTimer()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Release the advance callback — the next frontmost VC (or none) takes over. When
        // no VC is on screen, autoplay still advances; only the mini bar reflects it.
        sp.onAdvance = nil
        sp.onRecovery = nil
        sp.onRateReverted = nil
        NotificationCenter.default.removeObserver(self)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        if let t = objc_getAssociatedObject(self, &timerKey) as? Timer { t.invalidate() }
        if let t = objc_getAssociatedObject(self, &progressTimerKey) as? Timer { t.invalidate() }
        if let t = objc_getAssociatedObject(self, &downloadPollKey) as? Timer { t.invalidate() }
        if let t = objc_getAssociatedObject(self, &photoPollKey) as? Timer { t.invalidate() }
        if let t = objc_getAssociatedObject(self, &controlsHideKey) as? Timer { t.invalidate() }
        stopCaptionTimer()
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sp.layer.videoGravity = AVLayerVideoGravity.resizeAspect
        if let overlay = fsOverlay {
            // Switching quality while fullscreen rebuilds the player layer; it must go
            // back onto the overlay, not the (hidden) inline container, or the video
            // disappears while audio keeps playing. At index 0 so the tap-catcher,
            // controls bar and caption plate stay in front of it.
            sp.layer.frame = overlay.bounds
            overlay.layer.insertSublayer(sp.layer, at: 0)
        } else if let container = videoContainer {
            sp.layer.frame = container.bounds
            if let thumbLayer = thumbView?.layer {
                container.layer.insertSublayer(sp.layer, below: thumbLayer)
            } else {
                container.layer.addSublayer(sp.layer)
            }
        }
        CATransaction.commit()
    }

    // The status label and spinner follow the player between the inline container and the
    // fullscreen overlay. Left in the container they render behind the overlay, so a quality
    // switch (or a reconnect) made in fullscreen showed no "Loading stream..." feedback at all.
    // Fullscreen parks the label above the controls bar instead of under it.
    private func layoutStatusViews(in host: UIView, fullscreen: Bool) {
        let w = host.bounds.width
        let h = host.bounds.height
        if let sl = statusLabel {
            sl.frame = CGRect(x: 0, y: fullscreen ? h - 74 : h - 34, width: w, height: 34)
            if sl.superview !== host { host.addSubview(sl) }
        }
        if let spin = spinner {
            spin.center = CGPoint(x: w / 2, y: h / 2)
            if spin.superview !== host { host.addSubview(spin) }
        }
    }

    private func detachLayer() {
        sp.layer.removeFromSuperlayer()
    }

    // An audio-only download has no video track, so hiding the thumbnail would leave a black
    // rectangle for the whole track. Keep the artwork up instead — it doubles as the "this is
    // audio" cue. Every site that reveals live playback goes through this.
    private func hideThumbForPlayback() {
        thumbView?.isHidden = !DownloadManager.isAudioOnly(video.id)
    }

    // Reattach onto already-running playback (from mini bar / returning to the VC).
    private func showActivePlayback() {
        playBtn?.isHidden = true
        statusLabel?.isHidden = true
        hideThumbForPlayback()
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
    // The singleton's watchdog found the stream dead mid-playback and is re-resolving it.
    // Nothing to drive here — the singleton reloads and replays on its own — so this only
    // narrates what is happening, and puts the play button back if it ran out of attempts.
    private func handleRecovery(_ state: VideoPlayer.RecoveryState) {
        switch state {
        case .reconnecting(let attempt):
            showSpinner()
            statusLabel?.text = "Connection lost \u{2022} reconnecting (\(attempt)/3)..."
            statusLabel?.isHidden = false
            showControls()
        case .recovered:
            hideSpinner()
            statusLabel?.isHidden = true
        case .failed:
            hideSpinner()
            // The resolved URLs are the prime suspect after repeated drops on the same stream,
            // so make the next tap re-fetch them instead of reusing what just failed.
            streamsStale = true
            detachLayer()
            statusLabel?.text = "Connection lost \u{2022} tap > to retry"
            statusLabel?.isHidden = false
            playBtn?.isHidden = false
        }
    }

    private func handleAutoAdvance(_ newVideo: Video) {
        video = newVideo
        contentGen += 1   // invalidates every in-flight response for the previous video
        streams = []
        didRequestStreams = false
        streamsStale = false
        relatedState = .idle
        descriptionText = ""
        descExpanded = false
        apiChapters = []
        chapters = []
        chaptersExpanded = false
        relatedVideos = []
        detailTab = 0
        comments = []
        commentsToken = ""
        commentsState = .idle
        expandedReplies.removeAll()
        replyNextToken.removeAll()
        replyStates.removeAll()
        commentBodyHeights.removeAll()
        tabContentDirty = true
        activeQualityLabel = "Auto"   // the next video picks its own tier
        activeItag = nil
        resetCaptions()   // the new video has its own track list (refetched by loadStreams)

        let w = UIScreen.main.bounds.width
        let padding: CGFloat = 12

        var y = (videoContainer?.frame.maxY ?? floor(w * 9.0 / 16.0)) + 12
        titleLabel?.text = newVideo.title
        // The label is reused across videos, so the copy payload has to follow the text.
        titleLabel?.copyText = newVideo.title
        let titleH = titleLabel?.sizeThatFits(CGSize(width: w - padding * 2, height: 200)).height ?? 20
        titleLabel?.frame = CGRect(x: padding, y: y, width: w - padding * 2, height: titleH)
        y += titleH + 8

        channelLabel?.text = newVideo.channelName
        channelLabel?.textColor = newVideo.channelId.isEmpty
            ? UIColor(white: 0.6, alpha: 1)
            : Theme.accent
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
                syncSheetWindow()
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
            layoutStatusViews(in: overlay, fullscreen: true)
            syncSheetWindow()
        }

        // The VC view is already below the bars (edges = []), so the scroll view fills it.
        sv.frame = CGRect(x: 0, y: 0, width: w, height: h)

        let videoH = floor(w * 9.0 / 16.0)
        container.frame = CGRect(x: 0, y: 0, width: w, height: videoH)
        thumbView?.frame = CGRect(x: 0, y: 0, width: w, height: videoH)
        playBtn?.frame = CGRect(x: (w - 64) / 2, y: (videoH - 64) / 2, width: 64, height: 64)

        if fsOverlay == nil {
            layoutStatusViews(in: container, fullscreen: false)
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

        layoutCaptionPlate()
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
        btn.backgroundColor = Theme.accent.withAlphaComponent(0.9)
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
        sl.frame = CGRect(x: 0, y: videoH - 34, width: w, height: 34)
        container.addSubview(sl)
        statusLabel = sl

        // Spinner shown while a stream is being prepared — sits where the play button was,
        // so the wait reads as "working" rather than "stuck". whiteLarge = iOS 2+ safe.
        let spin = UIActivityIndicatorView(style: .whiteLarge)
        spin.hidesWhenStopped = true
        // Sits over the tap-catcher in fullscreen — must not swallow the tap that shows the bar.
        spin.isUserInteractionEnabled = false
        spin.center = CGPoint(x: w / 2, y: videoH / 2)
        container.addSubview(spin)
        spinner = spin

        buildControls(width: w, videoHeight: videoH, in: container)

        // Title
        let padding: CGFloat = 12
        y += 12
        let titleL = CopyableLabel()
        titleL.backgroundColor = .clear
        titleL.textColor = UIColor(white: 0.95, alpha: 1)
        titleL.font = UIFont.boldSystemFont(ofSize: 16)
        titleL.numberOfLines = 3
        titleL.text = video.title
        // UILabel does not take touches by default — without this the long press never fires.
        titleL.isUserInteractionEnabled = true
        titleL.copyText = video.title
        titleL.copyMenuTitle = "Copy title"
        titleL.addGestureRecognizer(UILongPressGestureRecognizer(
            target: self, action: #selector(copyableLongPressed(_:))))
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
            : Theme.accent
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
            // Name the quality it was saved at, so a 360p copy is visibly not the 1080p one.
            let q = DownloadManager.qualityLabel(for: video.id)
            downloadBtn?.setTitle(q.isEmpty ? "Downloaded \u{2713}" : "Downloaded \(q) \u{2713}",
                                  for: .normal)
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
        relatedState = .loading
        let gen = contentGen
        YoutubeAPI.getRelated(videoId: video.id, priority: true) { [weak self] vids, cToken, chaps in
            guard let self = self, gen == self.contentGen else { return }
            self.relatedState = .ready
            self.relatedVideos = Array(vids.prefix(12))
            self.apiChapters = chaps
            self.refreshChapters()
            if let cToken = cToken {
                self.commentsToken = cToken
                // No comment section on this watch page (comments off, or an age/region gate):
                // mark it resolved so the tab stops saying "Loading".
                if cToken.isEmpty { self.commentsState = .unavailable }
            } else {
                // The watch-page call itself failed, so whether this video has comments is
                // unknown — offer a retry rather than claiming they are unavailable.
                self.commentsState = .failed
            }
            self.tabContentDirty = true
            self.relayout()
            // The user may have opened the Comments tab before the token arrived.
            if self.detailTab == 1 && self.comments.isEmpty && self.commentsState != .loading {
                self.loadMoreComments()
            }
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
        // The description label is a copy target; a visible menu would be left pointing at a
        // view that is about to be removed (same reason layoutTabSection hides it).
        UIMenuController.shared.setMenuVisible(false, animated: false)
        for v in descRowViews { v.removeFromSuperview() }
        descRowViews.removeAll()

        let w = sv.bounds.width
        let padding: CGFloat = 12
        var y = contentBelowMetaY

        // Chapters, then the description (directly under the meta line).
        y = buildChaptersSection(startY: y, width: w)
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

        // Related / Comments tabs.
        y = layoutTabSection(startY: y, width: w)

        sv.contentSize = CGSize(width: w, height: y + 80)   // +80 clears the mini player bar
    }

    // The watch page's own chapter list when it has one, else the timestamps written into
    // the description. Both are offered on plenty of videos and they usually agree; the
    // authored list wins because its titles are already clean.
    private func refreshChapters() {
        chapters = apiChapters.isEmpty ? Chapter.parse(description: descriptionText) : apiChapters
    }

    @objc private func chaptersToggleTapped() {
        chaptersExpanded = !chaptersExpanded
        relayout()
    }

    private static let chapterRowColor = UIColor(white: 0.13, alpha: 1)
    private static let chapterRowHighlight = UIColor(white: 0.28, alpha: 1)

    @objc private func chapterRowDown(_ sender: UIButton) {
        sender.backgroundColor = VideoPlayerVC.chapterRowHighlight
    }

    @objc private func chapterRowUp(_ sender: UIButton) {
        sender.backgroundColor = VideoPlayerVC.chapterRowColor
    }

    @objc private func chapterTapped(_ sender: UIButton) {
        let i = sender.tag
        guard i >= 0, i < chapters.count else { return }
        let target = chapters[i].startSeconds
        if castSession != nil {
            castSession?.seek(to: target)
            return
        }
        guard sp.isActive(video.id) else { return }
        sp.seek(toSeconds: target)
        showControls()
    }

    // Chapter rows above the description: [time][title], the whole row tappable. Collapsed
    // to the first few — a long tutorial can carry 70+ chapters, and one row is two labels
    // inside a button, so showing them all by default would be the heaviest thing on the
    // page on a 4S.
    private func buildChaptersSection(startY: CGFloat, width w: CGFloat) -> CGFloat {
        guard !chapters.isEmpty, let sv = scrollView else { return startY }
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
        header.text = "Chapters"
        header.frame = CGRect(x: padding, y: y, width: bodyW, height: 22)
        sv.addSubview(header); descRowViews.append(header)
        y += 30

        let collapsedCount = 5
        let shown = chaptersExpanded ? chapters.count : min(collapsedCount, chapters.count)
        let rowH: CGFloat = 34
        let inset: CGFloat = 10
        let timeW: CGFloat = 58
        for i in 0..<shown {
            let chapter = chapters[i]
            let row = UIButton(type: .custom)
            row.frame = CGRect(x: padding, y: y, width: bodyW, height: rowH)
            row.tag = i
            // A plate so the row reads as a control rather than two runs of coloured text.
            // cornerRadius alone rounds the layer's own background — no clipsToBounds, so no
            // off-screen render pass per row.
            row.backgroundColor = VideoPlayerVC.chapterRowColor
            row.layer.cornerRadius = 6
            row.addTarget(self, action: #selector(chapterTapped(_:)), for: .touchUpInside)
            // A .custom button has no highlight state of its own, so a tap produced no
            // feedback at all until the video moved. Driven by colour rather than a
            // highlighted background image: an image is drawn by a square subview and would
            // need clipsToBounds to respect the rounded corners.
            row.addTarget(self, action: #selector(chapterRowDown(_:)), for: [.touchDown, .touchDragEnter])
            row.addTarget(self, action: #selector(chapterRowUp(_:)),
                          for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])

            let time = UILabel(frame: CGRect(x: inset, y: 0, width: timeW, height: rowH))
            time.backgroundColor = .clear
            time.textColor = Theme.accent
            time.font = UIFont.boldSystemFont(ofSize: 13)
            time.text = chapter.timeLabel
            row.addSubview(time)

            let titleX = inset + timeW
            let title = UILabel(frame: CGRect(x: titleX, y: 0, width: bodyW - titleX - inset, height: rowH))
            title.backgroundColor = .clear
            title.textColor = UIColor(white: 0.8, alpha: 1)
            title.font = UIFont.systemFont(ofSize: 13)
            title.lineBreakMode = .byTruncatingTail
            title.text = chapter.title
            row.addSubview(title)

            sv.addSubview(row); descRowViews.append(row)
            y += rowH + 4
        }

        if chapters.count > collapsedCount {
            let toggle = UIButton(type: .custom)
            toggle.setTitle(chaptersExpanded ? "Show less" : "Show all \(chapters.count) chapters", for: .normal)
            toggle.setTitleColor(Theme.accent, for: .normal)
            toggle.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
            toggle.contentHorizontalAlignment = .left
            toggle.frame = CGRect(x: padding, y: y + 4, width: bodyW, height: 24)
            toggle.addTarget(self, action: #selector(chaptersToggleTapped), for: .touchUpInside)
            sv.addSubview(toggle); descRowViews.append(toggle)
            y += 32
        }
        y += 6
        return y
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

        let body = CopyableLabel()
        body.backgroundColor = .clear
        body.textColor = UIColor(white: 0.8, alpha: 1)
        body.font = bodyFont
        body.numberOfLines = descExpanded ? 0 : 4
        body.text = descriptionText
        body.isUserInteractionEnabled = true
        // The whole description, not the 4 lines on screen — copying works while collapsed.
        body.copyText = descriptionText
        body.copyMenuTitle = "Copy description"
        body.addGestureRecognizer(UILongPressGestureRecognizer(
            target: self, action: #selector(copyableLongPressed(_:))))
        let bodyH = descExpanded ? fullH : collapsedH
        body.frame = CGRect(x: padding, y: y, width: bodyW, height: bodyH)
        sv.addSubview(body); descRowViews.append(body)
        y += bodyH + 4

        if truncated {
            let toggle = UIButton(type: .custom)
            toggle.setTitle(descExpanded ? "Show less" : "Show more", for: .normal)
            toggle.setTitleColor(Theme.accent, for: .normal)
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

    // Positions the tab section. Its contents are expensive to build (one view tree per
    // comment, with no reuse) and most relayout() calls — description toggle, action button
    // reflow — only change where the section starts, so the container is simply moved unless
    // the data behind it actually changed.
    private func layoutTabSection(startY: CGFloat, width w: CGFloat) -> CGFloat {
        guard let sv = scrollView else { return startY }
        let container: UIView
        if let c = tabContainer {
            container = c
        } else {
            container = UIView()
            sv.addSubview(container)
            tabContainer = container
        }
        // A width change (rotation) invalidates every measured body height.
        if w != tabContentWidth {
            tabContentWidth = w
            commentBodyHeights.removeAll()
            tabContentDirty = true
        }
        if tabContentDirty {
            UIMenuController.shared.setMenuVisible(false, animated: false)
            for v in container.subviews { v.removeFromSuperview() }
            let h = buildTabContent(width: w, into: container)
            container.frame = CGRect(x: 0, y: startY, width: w, height: h)
            tabContentDirty = false
        } else {
            container.frame = CGRect(x: 0, y: startY, width: w, height: container.frame.height)
        }
        return startY + container.frame.height
    }

    // Tab strip ("Related" / "Comments") plus whichever list is selected. Returns the height
    // of the built content. The strip is drawn as soon as the page exists so the user can
    // open Comments while related videos are still in flight. All coordinates are relative
    // to the container.
    private func buildTabContent(width w: CGFloat, into sv: UIView) -> CGFloat {
        let padding: CGFloat = 12
        var y: CGFloat = 0

        let sep = UIView(frame: CGRect(x: 0, y: y, width: w, height: 0.5))
        sep.backgroundColor = UIColor(white: 0.2, alpha: 1)
        sv.addSubview(sep)
        y += 8

        let tabH: CGFloat = 38
        let tabW = (w - padding * 2) / 2
        for (i, title) in ["Related", "Comments"].enumerated() {
            let selected = (detailTab == i)
            let b = UIButton(type: .custom)
            b.frame = CGRect(x: padding + CGFloat(i) * tabW, y: y, width: tabW, height: tabH)
            b.setTitle(title, for: .normal)
            b.setTitleColor(selected ? UIColor(white: 0.95, alpha: 1) : UIColor(white: 0.45, alpha: 1),
                            for: .normal)
            b.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
            b.tag = i
            b.addTarget(self, action: #selector(detailTabTapped(_:)), for: .touchUpInside)
            sv.addSubview(b)

            let underline = UIView(frame: CGRect(x: b.frame.minX, y: y + tabH - 2, width: tabW, height: 2))
            underline.backgroundColor = selected
                ? Theme.accent
                : UIColor(white: 0.2, alpha: 1)
            sv.addSubview(underline)
        }
        y += tabH + 10

        return detailTab == 0
            ? buildRelatedRows(startY: y, width: w, into: sv)
            : buildCommentRows(startY: y, width: w, into: sv)
    }

    @objc private func detailTabTapped(_ sender: UIButton) {
        guard sender.tag != detailTab else { return }
        detailTab = sender.tag
        tabContentDirty = true
        if detailTab == 1 && commentsState == .idle { loadMoreComments() }
        relayout()
    }

    // Related-videos list. Returns the y after the last row.
    private func buildRelatedRows(startY: CGFloat, width w: CGFloat, into sv: UIView) -> CGFloat {
        guard !relatedVideos.isEmpty else {
            if relatedState == .ready {
                return addPlaceholder("No related videos.", startY: startY, width: w, into: sv)
            }
            return addPlaceholder("Loading related videos\u{2026}", startY: startY, width: w,
                                  into: sv, busy: true)
        }
        var y = startY
        for (i, v) in relatedVideos.enumerated() {
            let row = makeRelatedRow(v, index: i, width: w)
            row.frame = CGRect(x: 0, y: y, width: w, height: 80)
            sv.addSubview(row)
            y += 80
        }
        return y
    }

    // MARK: - Comments

    private func loadMoreComments() {
        guard commentsState != .loading else { return }
        // The token for the first batch arrives with the related-videos response; if it is
        // not here yet, loadRelated()'s completion retries this.
        guard !commentsToken.isEmpty else { return }
        commentsState = .loading
        let token = commentsToken
        let gen = contentGen
        tabContentDirty = true
        relayout()
        YoutubeAPI.getComments(token: token, priority: true) { [weak self] batch, next in
            guard let self = self, gen == self.contentGen else { return }
            if let next = next {
                self.comments.append(contentsOf: batch)
                self.commentsToken = next
                self.commentsState = .ready
            } else {
                // Request failed. commentsToken is deliberately left alone — overwriting it
                // would strand the list with no way to ask for this batch again.
                self.commentsState = .failed
            }
            self.tabContentDirty = true
            self.relayout()
        }
    }

    @objc private func loadMoreCommentsTapped() {
        loadMoreComments()
    }

    // Retry after a failure. If the first token never arrived the watch-page call is what
    // failed, so that is what has to be redone.
    @objc private func retryCommentsTapped() {
        commentsState = .idle
        if commentsToken.isEmpty {
            relatedState = .idle
            tabContentDirty = true
            relayout()
            loadRelated()
        } else {
            loadMoreComments()
        }
    }

    // Tapping "View N replies" pulls that one thread's replies and keeps them expanded;
    // tapping it again collapses and discards them.
    @objc private func repliesTapped(_ sender: UIButton) {
        let idx = sender.tag
        guard idx >= 0, idx < comments.count else { return }
        let c = comments[idx]
        if expandedReplies[c.id] != nil {
            expandedReplies.removeValue(forKey: c.id)
            replyNextToken.removeValue(forKey: c.id)
            replyStates.removeValue(forKey: c.id)
            tabContentDirty = true
            relayout()
            return
        }
        fetchReplies(parent: c, token: c.repliesToken)
    }

    @objc private func moreRepliesTapped(_ sender: UIButton) {
        let idx = sender.tag
        guard idx >= 0, idx < comments.count else { return }
        let c = comments[idx]
        // After a failure the stored token is still the one that has not been consumed yet,
        // so the same button doubles as the retry.
        fetchReplies(parent: c, token: replyNextToken[c.id] ?? c.repliesToken)
    }

    private func fetchReplies(parent c: Comment, token: String) {
        guard !token.isEmpty, replyStates[c.id] != .loading else { return }
        replyStates[c.id] = .loading
        let gen = contentGen
        tabContentDirty = true
        relayout()
        YoutubeAPI.getComments(token: token, priority: true) { [weak self] batch, next in
            guard let self = self, gen == self.contentGen else { return }
            if let next = next {
                self.expandedReplies[c.id] = (self.expandedReplies[c.id] ?? []) + batch
                self.replyNextToken[c.id] = next
                self.replyStates[c.id] = .ready
            } else {
                // Same as above: keep the token so "More replies" can ask again.
                self.replyStates[c.id] = .failed
            }
            self.tabContentDirty = true
            self.relayout()
        }
    }

    // Comment list: text-only rows, replies indented under their parent, and an explicit
    // "Load more comments" button rather than scroll-triggered paging.
    private func buildCommentRows(startY: CGFloat, width w: CGFloat, into sv: UIView) -> CGFloat {
        var y = startY

        if comments.isEmpty {
            switch commentsState {
            case .failed:
                y = addPlaceholder("Couldn't load comments.", startY: y, width: w, into: sv)
                return addWideButton("Retry", startY: y, width: w, into: sv,
                                     action: #selector(retryCommentsTapped))
            case .ready, .unavailable:
                return addPlaceholder("Comments are unavailable for this video.",
                                      startY: y, width: w, into: sv)
            case .idle, .loading:
                return addPlaceholder("Loading comments\u{2026}", startY: y, width: w,
                                      into: sv, busy: true)
            }
        }

        for (i, c) in comments.enumerated() {
            let row = makeCommentRow(c, width: w, topLevelIndex: i)
            row.frame = CGRect(x: 0, y: y, width: w, height: row.frame.height)
            sv.addSubview(row)
            y += row.frame.height

            for r in expandedReplies[c.id] ?? [] {
                let rr = makeCommentRow(r, width: w, topLevelIndex: nil)
                rr.frame = CGRect(x: 0, y: y, width: w, height: rr.frame.height)
                sv.addSubview(rr)
                y += rr.frame.height
            }
            switch replyStates[c.id] {
            case .some(.loading):
                y = addPlaceholder("Loading replies\u{2026}", startY: y, width: w,
                                   into: sv, indent: 36, busy: true)
            case .some(.failed):
                y = addReplyButton("Couldn't load replies \u{2022} Retry", startY: y, width: w,
                                   into: sv, index: i)
            default:
                if !(replyNextToken[c.id] ?? "").isEmpty {
                    y = addReplyButton("More replies", startY: y, width: w, into: sv, index: i)
                }
            }
        }

        if commentsState == .loading {
            y = addPlaceholder("Loading more\u{2026}", startY: y, width: w, into: sv, busy: true)
        } else if commentsState == .failed {
            y = addPlaceholder("Couldn't load more comments.", startY: y, width: w, into: sv)
            y = addWideButton("Retry", startY: y, width: w, into: sv,
                              action: #selector(retryCommentsTapped))
        } else if !commentsToken.isEmpty {
            y = addWideButton("Load more comments", startY: y, width: w, into: sv,
                              action: #selector(loadMoreCommentsTapped))
        }
        return y
    }

    private func addWideButton(_ title: String, startY: CGFloat, width w: CGFloat,
                               into sv: UIView, action: Selector) -> CGFloat {
        let padding: CGFloat = 12
        let b = UIButton(type: .custom)
        b.frame = CGRect(x: padding, y: startY + 8, width: w - padding * 2, height: 44)
        b.setTitle(title, for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
        b.backgroundColor = UIColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1)
        b.layer.cornerRadius = 6
        b.addTarget(self, action: action, for: .touchUpInside)
        sv.addSubview(b)
        return startY + 60
    }

    private func addReplyButton(_ title: String, startY: CGFloat, width w: CGFloat,
                                into sv: UIView, index: Int) -> CGFloat {
        let b = UIButton(type: .custom)
        b.frame = CGRect(x: 48, y: startY, width: w - 60, height: 28)
        b.setTitle(title, for: .normal)
        b.setTitleColor(Theme.accent, for: .normal)
        b.titleLabel?.font = UIFont.boldSystemFont(ofSize: 11)
        b.contentHorizontalAlignment = .left
        b.tag = index
        b.addTarget(self, action: #selector(moreRepliesTapped(_:)), for: .touchUpInside)
        sv.addSubview(b)
        return startY + 30
    }

    // A UILabel cannot select text, and one UITextView per comment would mean dozens of
    // UIWebDocumentViews on iOS 6, so a long press copies the whole comment body instead.
    @objc private func commentLongPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let row = g.view as? CommentRowView,
              !row.copyText.isEmpty, row.becomeFirstResponder() else { return }
        let menu = UIMenuController.shared
        menu.menuItems = [UIMenuItem(title: "Copy comment",
                                     action: #selector(CommentRowView.copyComment(_:)))]
        menu.setTargetRect(row.bounds, in: row)
        menu.setMenuVisible(true, animated: true)
    }

    // Same deal for the title and the description body, which are labels rather than row
    // containers — a UILabel is a UIResponder, so it can host the menu itself.
    @objc private func copyableLongPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let lbl = g.view as? CopyableLabel,
              !lbl.copyText.isEmpty, lbl.becomeFirstResponder() else { return }
        let menu = UIMenuController.shared
        menu.menuItems = [UIMenuItem(title: lbl.copyMenuTitle,
                                     action: #selector(CopyableLabel.copyValue(_:)))]
        menu.setTargetRect(lbl.bounds, in: lbl)
        menu.setMenuVisible(true, animated: true)
    }

    private static let commentBodyFont = UIFont.systemFont(ofSize: 13)

    // Wrapping a long comment is the single most expensive thing in the list, so each body
    // is measured once per width. Replies are narrower than top-level rows, hence the flag
    // in the key. Cleared on rotation and when the VC swaps video.
    private func commentBodyHeight(_ c: Comment, indented: Bool,
                                   width: CGFloat, font: UIFont) -> CGFloat {
        let key = indented ? c.id + "|r" : c.id
        if let h = commentBodyHeights[key] { return h }
        let h = heightForText(c.text, font: font, width: width, maxLines: 0)
        commentBodyHeights[key] = h
        return h
    }

    // Self-sizing comment row: header line, body (full text), then likes + a replies toggle.
    // topLevelIndex is the row's index in `comments` — nil marks a reply, which is indented
    // and never gets a replies toggle of its own (replies do not nest further).
    private func makeCommentRow(_ c: Comment, width w: CGFloat, topLevelIndex: Int?) -> UIView {
        let indented = topLevelIndex == nil
        let padding: CGFloat = 12
        let x = padding + (indented ? 24 : 0)
        let bodyW = w - x - padding
        let row = CommentRowView()
        row.copyText = c.text
        row.addGestureRecognizer(UILongPressGestureRecognizer(
            target: self, action: #selector(commentLongPressed(_:))))
        var y: CGFloat = 8

        if c.isPinned {
            let pin = UILabel()
            pin.backgroundColor = .clear
            pin.textColor = Theme.accent
            pin.font = UIFont.boldSystemFont(ofSize: 10)
            pin.text = "PINNED"
            pin.frame = CGRect(x: x, y: y, width: bodyW, height: 13)
            row.addSubview(pin)
            y += 15
        }

        let head = UILabel()
        head.backgroundColor = .clear
        head.textColor = UIColor(white: 0.55, alpha: 1)
        head.font = UIFont.boldSystemFont(ofSize: 12)
        head.text = c.headerText
        head.frame = CGRect(x: x, y: y, width: bodyW, height: 16)
        row.addSubview(head)
        y += 19

        let bodyFont = VideoPlayerVC.commentBodyFont
        let bodyH = commentBodyHeight(c, indented: indented, width: bodyW, font: bodyFont)
        let body = UILabel()
        body.backgroundColor = .clear
        body.textColor = UIColor(white: 0.92, alpha: 1)
        body.font = bodyFont
        body.numberOfLines = 0
        body.text = c.text
        body.frame = CGRect(x: x, y: y, width: bodyW, height: bodyH)
        row.addSubview(body)
        y += bodyH + 6

        let likes = c.likeText
        if !likes.isEmpty {
            let l = UILabel()
            l.backgroundColor = .clear
            l.textColor = UIColor(white: 0.45, alpha: 1)
            l.font = UIFont.systemFont(ofSize: 11)
            l.text = likes
            l.frame = CGRect(x: x, y: y, width: 120, height: 16)
            row.addSubview(l)
        }

        // Replies toggle (top-level rows only — replies never nest further).
        let repliesLabel = c.repliesText
        let showsReplyToggle = topLevelIndex != nil && !repliesLabel.isEmpty
        if let index = topLevelIndex, showsReplyToggle {
            let expanded = expandedReplies[c.id] != nil
            let btnX = likes.isEmpty ? x : x + 130
            let b = UIButton(type: .custom)
            b.frame = CGRect(x: btnX, y: y - 4, width: w - btnX - padding, height: 24)
            b.setTitle(expanded ? "Hide replies" : repliesLabel, for: .normal)
            b.setTitleColor(Theme.accent, for: .normal)
            b.titleLabel?.font = UIFont.boldSystemFont(ofSize: 11)
            b.contentHorizontalAlignment = .left
            b.tag = index
            b.addTarget(self, action: #selector(repliesTapped(_:)), for: .touchUpInside)
            row.addSubview(b)
        }
        if !likes.isEmpty || showsReplyToggle { y += 20 }

        y += 6
        row.frame = CGRect(x: 0, y: 0, width: w, height: y)
        return row
    }

    // One-line status used by both tabs while loading / when empty, with a spinner in front
    // of the text when something is actually in flight.
    private func addPlaceholder(_ text: String, startY: CGFloat, width w: CGFloat,
                                into sv: UIView, indent: CGFloat = 0,
                                busy: Bool = false) -> CGFloat {
        let padding: CGFloat = 12
        var x = padding + indent

        if busy {
            let spin = UIActivityIndicatorView(style: .white)
            spin.frame = CGRect(x: x, y: startY + 6, width: 20, height: 20)
            spin.startAnimating()
            sv.addSubview(spin)
            x += 26
        }

        let l = UILabel()
        l.backgroundColor = .clear
        l.textColor = UIColor(white: 0.45, alpha: 1)
        l.font = UIFont.systemFont(ofSize: 13)
        l.text = text
        l.frame = CGRect(x: x, y: startY + 6, width: w - x - padding, height: 20)
        sv.addSubview(l)
        return startY + 32
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
        // Copy Title and Copy Description used to sit here; both still copy with a long press.
        if let photos = photosSheetTitle() {
            let idx = sheet.addButton(withTitle: photos)
            if photos == "Stop Saving to Photos" { sheet.destructiveButtonIndex = idx }
        }
        sheet.addButton(withTitle: "Open in Safari")
        let cancelIdx = sheet.addButton(withTitle: "Cancel")
        sheet.cancelButtonIndex = cancelIdx
        sheet.tag = 1
        sheet.show(in: view)
    }

    // MARK: - Save to Photos (the work is PhotoExporter's; this is the asking and the progress)

    private static let photosSaveTag = 41       // UIAlertView: save the download
    private static let photosWhenDoneTag = 42   // UIAlertView: save it once it has downloaded

    // The Share sheet's Photos entry, nil for none: an audio-only download has no video to
    // save, and once a file is with Photos (or a Stop is under way) there is nothing to undo.
    private func photosSheetTitle() -> String? {
        let id = video.id
        if PhotoExporter.shared.canStop(id) { return "Stop Saving to Photos" }
        if PhotoExporter.shared.isBusy(id) { return nil }
        if DownloadManager.isAudioOnly(id),
           DownloadManager.isDownloaded(id) || DownloadManager.isDownloading(id) { return nil }
        return "Save to Photos"
    }

    // Every route asks first: a save can be a long conversion and a big file in the Camera Roll.
    private func saveToPhotosTapped() {
        let id = video.id
        if DownloadManager.isDownloading(id) {
            let pct = Int(DownloadManager.progress(for: id) * 100)
            confirmPhotos(tag: VideoPlayerVC.photosWhenDoneTag, title: "Save to Photos",
                          message: "This video is still downloading (\(pct)%). "
                                 + "Save it to Photos when the download finishes?",
                          go: "Save When Done")
        } else if PhotoExporter.canExport(id) {
            let what = [DownloadManager.qualityLabel(for: id), DownloadManager.fileSizeText(for: id)]
                .filter { !$0.isEmpty }.joined(separator: " \u{2022} ")
            var message = (what.isEmpty ? "This video" : what) + " will be added to your photo library."
            if PhotoExporter.shared.wasSaved(id) {
                message += " It was already saved once, so this adds a second copy."
            }
            confirmPhotos(tag: VideoPlayerVC.photosSaveTag, title: "Save to Photos?",
                          message: message, go: "Save")
        } else {
            showPhotosDownloadPicker()   // its Download & Save button is the confirmation
        }
    }

    // Answered in alertView(_:clickedButtonAt:).
    private func confirmPhotos(tag: Int, title: String, message: String, go: String) {
        let alert = UIAlertView()
        alert.delegate = self
        alert.tag = tag
        alert.title = title
        alert.message = message
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: go)
        alert.cancelButtonIndex = 0
        alert.show()
    }

    // Not downloaded: the Download picker with the video tiers only (audio-only is no use to
    // Photos, and captions can't go with it). What it downloads is deleted once Photos has it,
    // so it never shows up in Downloads.
    private func showPhotosDownloadPicker() {
        let choices = downloadChoices()
        guard !choices.isEmpty else {
            statusLabel?.text = streams.isEmpty ? "Still loading streams..."
                                               : "This video can't be saved to Photos (no usable stream)"
            statusLabel?.isHidden = false
            return
        }
        let pick = preselection(choices, audio: nil)
        let section = DownloadOptionSection(
            title: "Video",
            rows: choices.map { downloadRow($0, downloaded: false) },
            mode: .exclusive,
            initialSelection: [pick.row])
        DownloadOptionsView.present(in: view, title: "Save to Photos", sections: [section],
                                    confirmTitle: "Download & Save") { [weak self] picked in
            guard let self = self, let idx = picked.first?.first,
                  idx >= 0, idx < choices.count else { return }
            let c = choices[idx]
            let audio = c.isProgressive ? nil : self.audioStreamForHLS()
            guard c.isProgressive || audio != nil else { return }
            PhotoExporter.shared.downloadAndSave(self.video, quality: c.label, videoStream: c.stream,
                                                 audioStream: audio, estimatedBytes: c.estimatedBytes)
            self.observePhotoExport()
        }
    }

    // Mirrors a Save to Photos onto the Share button ("Saving 34%"), the way observeDownload
    // does for the Download button. Torn down on disappear; the export itself carries on.
    private func observePhotoExport() {
        if let t = objc_getAssociatedObject(self, &photoPollKey) as? Timer { t.invalidate() }
        // Only an export seen running here earns a "Saved" flash — not one that never started
        // (no room), and not an earlier save of the same video.
        var sawBusy = false
        let tick = { [weak self] in
            guard let self = self else { return }
            let id = self.video.id
            if PhotoExporter.shared.isBusy(id), let s = PhotoExporter.shared.statusText(id) {
                sawBusy = true
                self.shareBtn?.setTitle(s, for: .normal)
                return
            }
            if let t = objc_getAssociatedObject(self, &photoPollKey) as? Timer { t.invalidate() }
            if sawBusy && PhotoExporter.shared.wasSaved(id) {
                self.flash(self.shareBtn, "Saved \u{2713}", revertTo: "Share")
            } else {
                self.shareBtn?.setTitle("Share", for: .normal)
            }
        }
        let t = Timer(timeInterval: 0.5, target: BlockTarget(tick),
                      selector: #selector(BlockTarget.fire), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        objc_setAssociatedObject(self, &photoPollKey, t, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        tick()   // "Waiting..." at once, not half a second later
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
            case "Save to Photos":
                // Its confirmation (an alert, or the quality picker) waits for this sheet to
                // finish dismissing — same reason as the Playback menu below.
                let t = Timer(timeInterval: 0.35, target: BlockTarget { [weak self] in
                    self?.saveToPhotosTapped()
                }, selector: #selector(BlockTarget.fire), userInfo: nil, repeats: false)
                RunLoop.main.add(t, forMode: .common)
            case "Stop Saving to Photos":
                PhotoExporter.shared.cancel(video.id)
                observePhotoExport()
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
            // Playback menu: each row opens a submenu. Present it only after this sheet has
            // finished dismissing — showing one from inside the delegate fights the dismissal
            // animation on iOS 6.
            guard buttonIndex != actionSheet.cancelButtonIndex else { return }
            let next: () -> Void
            if buttonIndex == qualitySheetIndex { next = { [weak self] in self?.showQualitySheet() } }
            else if buttonIndex == captionsSheetIndex { next = { [weak self] in self?.showCaptionSheet() } }
            else if buttonIndex == speedSheetIndex { next = { [weak self] in self?.showSpeedSheet() } }
            else { return }
            let t = Timer(timeInterval: 0.35, target: BlockTarget(next),
                          selector: #selector(BlockTarget.fire), userInfo: nil, repeats: false)
            RunLoop.main.add(t, forMode: .common)
        } else if actionSheet.tag == 5 {
            // Captions sheet: button 0 = Off, then captionTracks in order, then Cancel.
            guard buttonIndex != actionSheet.cancelButtonIndex else { return }
            selectCaption(buttonIndex - 1)
        } else if actionSheet.tag == 6 {
            // Speed sheet: speedOptions in order, then Cancel.
            guard buttonIndex != actionSheet.cancelButtonIndex else { return }
            guard buttonIndex >= 0, buttonIndex < VideoPlayerVC.speedOptions.count else { return }
            // Only the slow options can still be refused outright (the item is asked about
            // those, and it answers honestly). A fast one that the stream cannot really hold
            // comes back through handleRateReverted a few seconds later instead.
            if !sp.setPlaybackRate(VideoPlayerVC.speedOptions[buttonIndex].rate) {
                showSpeedAlert("This stream only plays at normal speed or faster.")
            }
        } else if actionSheet.tag == 7 {
            // Quality sheet: [360p?, pendingHLSStreams...], then Cancel.
            guard buttonIndex != actionSheet.cancelButtonIndex else { return }
            if qualitySheetMuxedRow, buttonIndex == 0 {
                activeQualityLabel = "360p"
                // Set before playTapped(), which otherwise sees the tier being switched AWAY
                // from and replays that instead.
                activeItag = StreamTiers.muxed360
                playTapped()   // the default 360p path (offline copy / direct / proxied)
            } else {
                let idx = qualitySheetMuxedRow ? buttonIndex - 1 : buttonIndex
                if idx >= 0, idx < pendingHLSStreams.count { playHLS(pendingHLSStreams[idx]) }
            }
        }
    }

    // MARK: - UIAlertViewDelegate (new-playlist name entry, Save to Photos confirmations)

    func alertView(_ alertView: UIAlertView, clickedButtonAt buttonIndex: Int) {
        // The two Save to Photos confirmations: 0 = Cancel, 1 = go.
        if alertView.tag == VideoPlayerVC.photosSaveTag || alertView.tag == VideoPlayerVC.photosWhenDoneTag {
            guard buttonIndex == 1 else { return }
            if alertView.tag == VideoPlayerVC.photosSaveTag {
                PhotoExporter.shared.export(video)
                observePhotoExport()
            } else {
                PhotoExporter.shared.saveWhenDownloaded(video.id)
            }
            return
        }
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
        // Cast sits in the control bar, so this sheet can be raised from fullscreen too.
        sheet.show(in: sheetHost)
    }

    private func startCasting(to device: CastDevice) {
        // A Chromecast fetches the URL itself, so it needs a self-contained muxed file — it can
        // neither reach the local transmux proxy nor mux two adaptive tracks on its own.
        guard let preferred = preferredStream() else {
            statusLabel?.text = streams.isEmpty ? "No stream to cast yet"
                                               : "This video can't be cast (no muxed stream)"
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
        sl.minimumTrackTintColor = Theme.accent
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
        sl.minimumTrackTintColor = Theme.accent
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

        // Settings button — opens the quality + captions sheet. Left of the cast button.
        // A gear, not an "hd" glyph: the sheet now hosts captions as well as quality.
        let hd = UIButton(type: .custom)
        hd.setImage(UIImage(named: "gear"), for: .normal)
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
    private func loadStreams(updateStatus: Bool = true, completion: (() -> Void)? = nil) {
        didRequestStreams = true
        // Already downloaded — no network needed, play offline.
        if DownloadManager.isDownloaded(video.id) {
            if updateStatus {
                statusLabel?.text = "Downloaded \u{2022} tap > to play"
                statusLabel?.isHidden = false
            }
            // Captions saved with the download: the only way a downloaded video has any,
            // since this path never reaches getStreams. Empty for one downloaded before
            // captions were saved, which simply shows no CC row — as it always did.
            captionTracks = Captions.offlineTracks(for: video.id)
            restoreCaptionSelection()
            completion?()
            return
        }

        if updateStatus {
            statusLabel?.text = "Loading..."
            statusLabel?.isHidden = false
        }

        DebugLog.log("Player", "loadStreams start id=\(video.id) updateStatus=\(updateStatus)")
        YoutubeAPI.getStreams(videoId: video.id) { [weak self] streams, _, desc, failure, captions in
            guard let self = self else { return }
            self.streams = streams
            self.captionTracks = captions
            DebugLog.log("Player", "getStreams result id=\(self.video.id) formats=\(streams.count) itags=\(streams.map { $0.itag }) failure=\"\(failure)\"")
            if updateStatus {
                // Report YouTube's own explanation (bot check, purchase required, live not
                // started, region/age gate...) rather than a catch-all string.
                self.statusLabel?.text = streams.isEmpty
                    ? (failure.isEmpty ? "No streams available" : failure)
                    : "Tap > to play"
            }
            if !desc.isEmpty {
                self.descriptionText = desc
                self.refreshChapters()
                self.relayout()
            }
            self.restoreCaptionSelection()
            completion?()
        }
    }

    // MARK: - Stream selection

    // The muxed stream to play/download/cast directly, or nil when the player response carries
    // none (the IOS fallback client is adaptive-only). Fallbacks are restricted to progressive
    // formats: an adaptive match would be video-only and play silently.
    private func preferredStream() -> VideoStream? {
        // Prefer muxed 360p MP4 (itag 18) — plays on AVPlayer, small, castable.
        return streams.first { $0.itag == StreamTiers.muxed360 }
            ?? streams.first { $0.isProgressive && $0.mimeType.contains("mp4") && !$0.mimeType.contains("av01") }
            ?? streams.first { $0.isProgressive && $0.mimeType.contains("video") }
            ?? streams.first { $0.isProgressive }
    }

    // MARK: - HLS quality selection (>360p via local transmux)

    // The DASH audio track backing every HLS quality. indexEnd > 0 = fMP4 with a sidx head.
    private func audioStreamForHLS() -> VideoStream? {
        return streams.first { $0.itag == StreamTiers.audio && $0.indexEnd > 0 }
    }

    // Video-only H.264 streams the transmux pipeline can serve, ascending quality
    // (480p, 720p, 1080p). Empty when the audio track is missing (no way to mux).
    // 360p (itag 134) joins the list only when the response has no muxed format to play
    // directly — otherwise it would duplicate the sheet's hardcoded "360p" row.
    private func hlsQualityOptions() -> [VideoStream] {
        guard audioStreamForHLS() != nil else { return [] }
        var tags = StreamTiers.h264
        if preferredStream() == nil { tags.insert(StreamTiers.base360, at: 0) }
        return tags.compactMap { tag in
            streams.first { $0.itag == tag && $0.indexEnd > 0 && $0.mimeType.contains("avc1") }
        }
    }

    // Settings > Default Video Quality. Steps DOWN from the user's preferred tier through
    // 720p/480p if the exact match isn't available for this video, so playback still starts
    // at the closest quality instead of falling all the way back to 360p. Returns nil for
    // "auto" (no preference — caller falls through to the normal 360p path unchanged) or when
    // streams haven't loaded yet / no HLS tier at all exists for this video.
    private func defaultQualityStream() -> VideoStream? {
        let pref = AppSettings.defaultQuality
        guard pref != "auto" else { return nil }
        let opts = hlsQualityOptions()
        guard !opts.isEmpty else { return nil }
        let order = StreamTiers.qualityOrder
        guard let startIdx = order.firstIndex(of: pref) else { return nil }
        for key in order[startIdx...] {
            for itag in StreamTiers.itags(forQuality: key) {
                if let s = opts.first(where: { $0.itag == itag }) { return s }
            }
        }
        return nil
    }

    // The "hd" button opens the playback menu: one row per setting, each opening its own
    // submenu (the control bar has no room for separate CC/speed buttons at 320pt, and
    // listing every quality, caption track and speed in one sheet was far too long).
    // Each row shows its current value, so the menu doubles as a status readout.
    @objc private func hdTapped() {
        // Nothing resolved yet means the quality and captions rows can't be populated at all,
        // and the menu would be a lone speed row with no explanation of what's missing.
        guard !streams.isEmpty || !captionTracks.isEmpty else {
            let alert = UIAlertView()
            alert.title = "Playback"
            alert.message = "Still loading streams..."
            alert.addButton(withTitle: "OK")
            alert.cancelButtonIndex = 0
            alert.show()
            return
        }
        qualitySheetIndex = -1
        captionsSheetIndex = -1
        speedSheetIndex = -1
        let sheet = UIActionSheet()
        sheet.delegate = self
        sheet.title = "Playback"
        if !hlsQualityOptions().isEmpty || preferredStream() != nil {
            qualitySheetIndex = sheet.addButton(withTitle: "Quality: \(activeQualityLabel)")
        }
        if !captionTracks.isEmpty {
            captionsSheetIndex = sheet.addButton(withTitle: "Captions: \(currentCaptionLabel())")
        }
        speedSheetIndex = sheet.addButton(withTitle: "Speed: \(currentSpeedLabel())")
        let cancelIdx = sheet.addButton(withTitle: "Cancel")
        sheet.cancelButtonIndex = cancelIdx
        sheet.tag = 4
        sheet.show(in: sheetHost)
    }

    // Host view for the player's action sheets.
    //
    // On iOS 6/7 a UIActionSheet is drawn as a real subview of the host, so in fullscreen it
    // must go into fsOverlay — shown in `view` it would be buried behind the overlay.
    //
    // iOS 8 rebuilt UIActionSheet on top of UIAlertController, which is presented by the view
    // controller found by walking up from the host view. fsOverlay is a bare subview of the
    // window with no view controller above it, so showing there is a silent no-op — the gear
    // button did nothing at all in fullscreen (iPad mini 1 / 8.4.1). Hosting in `view` fixes
    // that, but only halfway: a modal presentation is inserted INSIDE the presenting VC's own
    // window hierarchy, which is still underneath fsOverlay, so the sheet opens invisibly and
    // only shows up once fullscreen is exited. In fullscreen it therefore goes into a window
    // of its own, one level above the app window.
    private var sheetHost: UIView {
        if (UIDevice.current.systemVersion as NSString).floatValue >= 8.0 {
            if fsOverlay != nil, let host = sheetWindow?.rootViewController?.view { return host }
            return view
        }
        return fsOverlay ?? view
    }

    // The sheet window needs a root view controller (that is what the iOS 8 shim presents
    // from) and the overlay's exact geometry, so a sheet shown in it lands over the video and
    // reads the right way up in landscape — the app window itself never rotates on iPhone.
    private func ensureSheetWindow() {
        guard (UIDevice.current.systemVersion as NSString).floatValue >= 8.0 else { return }
        if sheetWindow == nil {
            let w = PassthroughWindow()
            w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
            w.backgroundColor = .clear
            let host = UIViewController()
            host.view.backgroundColor = .clear
            w.rootViewController = host
            w.isHidden = false
            sheetWindow = w
        }
        syncSheetWindow()
    }

    // Keep the window glued to the overlay as the device turns between landscape sides.
    private func syncSheetWindow() {
        guard let w = sheetWindow, let overlay = fsOverlay else { return }
        let screen = UIScreen.main.bounds
        w.bounds = overlay.bounds
        w.center = CGPoint(x: screen.midX, y: screen.midY)
        w.transform = overlay.transform
        w.rootViewController?.view.frame = w.bounds
    }

    private func teardownSheetWindow() {
        guard let w = sheetWindow else { return }
        w.rootViewController?.dismiss(animated: false, completion: nil)
        w.isHidden = true
        w.rootViewController = nil
        sheetWindow = nil
    }

    // MARK: - Quality

    // Second-level sheet: the direct muxed 360p (when the response has one) followed by the
    // transmuxable tiers, current pick check-marked.
    private func showQualitySheet() {
        let opts = hlsQualityOptions()
        pendingHLSStreams = opts
        // Row 0 is the direct muxed 360p only when such a format exists; otherwise every row
        // maps straight onto pendingHLSStreams (whose first entry is then the 360p tier).
        qualitySheetMuxedRow = preferredStream() != nil
        guard !opts.isEmpty || qualitySheetMuxedRow else { return }
        let sheet = UIActionSheet()
        sheet.delegate = self
        sheet.title = "Quality"
        if qualitySheetMuxedRow { sheet.addButton(withTitle: mark("360p")) }
        for s in opts { sheet.addButton(withTitle: mark(qualityLabel(s))) }
        let cancelIdx = sheet.addButton(withTitle: "Cancel")
        sheet.cancelButtonIndex = cancelIdx
        sheet.tag = 7
        sheet.show(in: sheetHost)
    }

    // YouTube's own qualityLabel already distinguishes the frame rate — the 60fps tiers come
    // back as "720p60"/"1080p60", the 30fps ones as plain "720p" — so the rows need no extra
    // marker of their own, even for a video whose ladder switches frame rate partway up.
    private func qualityLabel(_ s: VideoStream) -> String {
        return s.quality.isEmpty ? "itag \(s.itag)" : s.quality
    }

    // Check-mark prefix for the row matching the current selection.
    private func mark(_ label: String) -> String {
        return (label == activeQualityLabel ? "\u{2713} " : "") + label
    }

    // MARK: - Playback speed

    // The rate lives on the player singleton, so it survives this VC being popped, keeps
    // applying from the mini bar, and carries over to the next video in a playlist. The
    // sheet only reports it. Labels are fixed strings rather than formatted numbers: the
    // 5.1.5 runtime renders Double->Int conversions inside string interpolation as "?".
    private static let speedOptions: [(label: String, rate: Float)] = [
        ("0.5x", 0.5), ("0.75x", 0.75), ("Normal", 1.0), ("1.25x", 1.25), ("1.5x", 1.5), ("2x", 2.0)
    ]

    private func currentSpeedLabel() -> String {
        let r = sp.playbackRate
        return VideoPlayerVC.speedOptions.first(where: { $0.rate == r })?.label ?? "Normal"
    }

    private func showSpeedAlert(_ message: String) {
        let alert = UIAlertView()
        alert.title = "Speed"
        alert.message = message
        alert.addButton(withTitle: "OK")
        alert.cancelButtonIndex = 0
        alert.show()
    }

    // The singleton already put the speed back to Normal by the time this runs — say so, or
    // the menu silently disagreeing with the pick looks like the tap was simply ignored.
    private func handleRateReverted() {
        showSpeedAlert("This stream could not keep up at that speed \u{2022} back to Normal.")
    }

    // Second-level sheet, same shape as the captions one: current pick check-marked.
    private func showSpeedSheet() {
        let current = sp.playbackRate
        let sheet = UIActionSheet()
        sheet.delegate = self
        sheet.title = "Speed"
        for o in VideoPlayerVC.speedOptions {
            sheet.addButton(withTitle: (o.rate == current ? "\u{2713} " : "") + o.label)
        }
        let cancelIdx = sheet.addButton(withTitle: "Cancel")
        sheet.cancelButtonIndex = cancelIdx
        sheet.tag = 6
        sheet.show(in: sheetHost)
    }

    // MARK: - Captions

    private func currentCaptionLabel() -> String {
        guard activeCaptionIndex >= 0, activeCaptionIndex < captionTracks.count else { return "Off" }
        return captionTracks[activeCaptionIndex].name
    }

    // Second-level sheet listing Off + every available track, current pick check-marked.
    private func showCaptionSheet() {
        guard !captionTracks.isEmpty else { return }
        let sheet = UIActionSheet()
        sheet.delegate = self
        sheet.title = "Captions"
        sheet.addButton(withTitle: (activeCaptionIndex < 0 ? "\u{2713} " : "") + "Off")
        for (i, t) in captionTracks.enumerated() {
            sheet.addButton(withTitle: (i == activeCaptionIndex ? "\u{2713} " : "") + t.name)
        }
        let cancelIdx = sheet.addButton(withTitle: "Cancel")
        sheet.cancelButtonIndex = cancelIdx
        sheet.tag = 5
        sheet.show(in: sheetHost)
    }

    // Re-apply the track held by the singleton. This VC is built from scratch every time the
    // player is reopened (mini bar, history, a second tap on the same video), so without this
    // the captions the viewer turned on come back off. Runs once the refetched track list is
    // in; the cached cues are reused when they are still the right ones.
    private func restoreCaptionSelection() {
        guard activeCaptionIndex < 0, !captionTracks.isEmpty, sp.isActive(video.id),
              let key = sp.activeCaptionKey,
              let index = captionTracks.firstIndex(where: { $0.key == key }) else { return }
        guard !sp.activeCaptionCues.isEmpty else {
            selectCaption(index)   // picked, but the transcript never finished loading
            return
        }
        activeCaptionIndex = index
        captionCues = sp.activeCaptionCues
        captionCueIndex = -1
        ensureCaptionPlate()
        startCaptionTimer()
    }

    // index < 0 turns captions off; otherwise fetch + parse the track, then start ticking.
    private func selectCaption(_ index: Int) {
        captionCueIndex = -1
        captionLabel?.text = ""
        captionPlate?.isHidden = true
        guard index >= 0, index < captionTracks.count else {
            activeCaptionIndex = -1
            captionCues = []
            sp.activeCaptionKey = nil
            sp.activeCaptionCues = []
            stopCaptionTimer()
            return
        }
        activeCaptionIndex = index
        captionCues = []
        let track = captionTracks[index]
        sp.activeCaptionKey = track.key
        sp.activeCaptionCues = []
        Captions.load(track, videoId: video.id) { [weak self] cues in
            guard let self = self else { return }
            // A newer pick (or an auto-advance) may have landed while this was in flight.
            // Compare the KEY, not baseUrl: offline tracks all carry an empty baseUrl, which
            // would make every row look like the selected one.
            guard self.activeCaptionIndex >= 0, self.activeCaptionIndex < self.captionTracks.count,
                  self.captionTracks[self.activeCaptionIndex].key == track.key else { return }
            self.captionCues = cues
            self.sp.activeCaptionCues = cues
            if cues.isEmpty {
                self.activeCaptionIndex = -1
                self.sp.activeCaptionKey = nil
                self.stopCaptionTimer()
                let alert = UIAlertView()
                alert.title = "Captions"
                alert.message = "Could not load \(track.name)."
                alert.addButton(withTitle: "OK")
                alert.cancelButtonIndex = 0
                alert.show()
                return
            }
            self.ensureCaptionPlate()
            self.startCaptionTimer()
        }
    }

    // Translucent plate + label, hosted in whichever view currently shows the video so it
    // rides into fullscreen (same host rule as the seek indicator). Non-interactive so it
    // never steals taps from the tap-catcher underneath.
    private func ensureCaptionPlate() {
        guard let host = fsOverlay ?? videoContainer else { return }
        if captionPlate == nil {
            let plate = UIView()
            plate.backgroundColor = UIColor(white: 0, alpha: 0.6)
            plate.layer.cornerRadius = 4
            plate.isUserInteractionEnabled = false
            plate.isHidden = true
            captionPlate = plate

            let lbl = UILabel()
            lbl.backgroundColor = .clear     // iOS 6 defaults UILabel backgrounds to WHITE
            lbl.textColor = .white
            lbl.font = UIFont.boldSystemFont(ofSize: AppSettings.captionFontSize(hostWidth: host.bounds.width))
            lbl.textAlignment = .center
            lbl.numberOfLines = 3
            plate.addSubview(lbl)
            captionLabel = lbl
        }
        if captionPlate?.superview !== host {
            captionPlate.map { host.addSubview($0) }
        }
        host.bringSubviewToFront(captionPlate!)
        layoutCaptionPlate()
    }

    // Bottom-centered, above the 40pt control bar, sized to the current line.
    private func layoutCaptionPlate() {
        guard let plate = captionPlate, let lbl = captionLabel,
              let host = fsOverlay ?? videoContainer else { return }
        let text = lbl.text ?? ""
        guard !text.isEmpty, castSession == nil else { plate.isHidden = true; return }
        // Re-read the setting here rather than only at creation: the plate outlives a trip to
        // Settings, and under "auto" the size also has to follow the host (entering fullscreen
        // triples the width). Assigning a font forces a label relayout, hence the comparison.
        let fontSize = AppSettings.captionFontSize(hostWidth: host.bounds.width)
        if lbl.font.pointSize != fontSize { lbl.font = UIFont.boldSystemFont(ofSize: fontSize) }
        let maxW = max(host.bounds.width - 24, 40)
        let size = lbl.sizeThatFits(CGSize(width: maxW, height: 200))
        let w = min(maxW, ceil(size.width)) + 12
        let h = ceil(size.height) + 8
        plate.frame = CGRect(x: floor((host.bounds.width - w) / 2),
                             y: max(0, host.bounds.height - 46 - h), width: w, height: h)
        lbl.frame = CGRect(x: 6, y: 4, width: w - 12, height: h - 8)
        plate.isHidden = false
    }

    private func startCaptionTimer() {
        stopCaptionTimer()
        let t = Timer(timeInterval: 0.25, target: BlockTarget { [weak self] in
            self?.captionTick()
        }, selector: #selector(BlockTarget.fire), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        objc_setAssociatedObject(self, &captionTimerKey, t, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func stopCaptionTimer() {
        if let t = objc_getAssociatedObject(self, &captionTimerKey) as? Timer { t.invalidate() }
        objc_setAssociatedObject(self, &captionTimerKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        captionPlate?.isHidden = true
    }

    // Runs on its own timer, NOT the control-bar progress timer — that one is stopped
    // whenever the controls auto-hide, which is exactly when captions matter most.
    private func captionTick() {
        guard !captionCues.isEmpty, sp.isActive(video.id) else { return }
        let i = Captions.cueIndex(at: sp.currentSeconds, in: captionCues, hint: captionCueIndex)
        guard i != captionCueIndex else { return }
        captionCueIndex = i
        captionLabel?.text = (i >= 0) ? captionCues[i].text : ""
        layoutCaptionPlate()
    }

    // Drop all caption state (new video loaded into this VC via playlist auto-advance).
    private func resetCaptions() {
        stopCaptionTimer()
        sp.activeCaptionKey = nil
        sp.activeCaptionCues = []
        captionTracks = []
        captionCues = []
        activeCaptionIndex = -1
        captionCueIndex = -1
        captionLabel?.text = ""
    }

    // Play a >360p quality through the local HLS transmux pipeline. Goes through StreamProxy
    // on ALL iOS versions (the transmux runs locally — a direct googlevideo URL can't help),
    // with the proxy-length readiness window: the first playlist request triggers two ranged
    // head fetches + parse before AVPlayer even sees the segment list. A stream that never
    // becomes ready stops with a retry message, same as the proxied 360p path.
    private func playHLS(_ vStream: VideoStream) {
        guard let aStream = audioStreamForHLS(),
              let local = StreamProxy.shared.hlsURL(videoURL: vStream.url, audioURL: aStream.url,
                                                    videoIndexEnd: vStream.indexEnd,
                                                    audioIndexEnd: aStream.indexEnd) else {
            statusLabel?.text = "Quality unavailable"
            statusLabel?.isHidden = false
            return
        }
        activeQualityLabel = qualityLabel(vStream)
        activeItag = vStream.itag
        playBtn?.isHidden = true
        statusLabel?.text = "Loading stream..."
        statusLabel?.isHidden = false
        showSpinner()
        // 120 ticks = 30s: first-play needs 2 head fetches + 2 ranged GETs + transmux per
        // segment before AVPlayer reports ready — generous headroom on an iPhone 4S.
        tryStream(urlStr: local.absoluteString, maxTicks: 120)
    }

    // MARK: - Playback

    // True from a tap until the start it triggered actually begins — see playTapped.
    private var startPending = false

    // Show that the tap registered BEFORE doing anything expensive. Starting playback holds the
    // main thread for 1-10s on iOS 6 (VideoPlayer.load — audio session + replaceCurrentItem),
    // and UIKit only draws once the run loop turns, so hiding > and starting the spinner in the
    // same pass never reached the screen: the viewer saw nothing and tapped again. So > fades
    // out first and the start runs in the fade's completion, by which time the spinner is on
    // screen — and keeps turning through the stall, since Core Animation renders out of
    // process. The fade also takes > out of play: an animating view ignores touches.
    @objc private func playTapped() {
        guard !startPending else { return }
        startPending = true
        statusLabel?.text = "Loading..."
        statusLabel?.isHidden = false
        showSpinner()
        let btn = playBtn
        UIView.animate(withDuration: 0.15, animations: { btn?.alpha = 0 }, completion: { [weak self] _ in
            btn?.isHidden = true
            btn?.alpha = 1
            guard let self = self else { return }
            self.startPending = false
            self.startPlay()
        })
    }

    private func startPlay() {
        // Offline copy takes priority. A progressive download plays off disk; an HLS bundle
        // is served back through StreamProxy (AVPlayer won't open a file:// playlist) — still
        // local either way, so isLocal: true and no reconnect watchdog.
        if DownloadManager.isDownloaded(video.id) {
            if let offline = DownloadManager.playbackURL(for: video.id) {
                playBtn?.isHidden = true
                startPlayback(url: offline, isLocal: true)
                return
            }
            DebugLog.log("Player", "id=\(video.id) offline copy unplayable — falling back to stream")
        }

        // Retry after a hard failure: fetch a fresh player response first, then come back
        // through here with new URLs. streamsStale is cleared up front so this can't loop.
        if streamsStale {
            streamsStale = false
            playBtn?.isHidden = true
            statusLabel?.text = "Reloading stream..."
            statusLabel?.isHidden = false
            showSpinner()
            loadStreams(updateStatus: false) { [weak self] in self?.startPlay() }
            return
        }

        // A tier already in effect for this video wins over the Settings default: this is also
        // the path a retry takes after the watchdog gave up, and coming back at a different
        // quality than the one being watched is exactly what the viewer notices. The muxed 360p
        // itag falls through to the direct path below — not back into the default.
        if let itag = activeItag {
            if itag != StreamTiers.muxed360,
               let s = hlsQualityOptions().first(where: { $0.itag == itag }) {
                playHLS(s)
                return
            }
        } else if let preset = defaultQualityStream() {
            // Apply the user's default quality preference (Settings), if set and available.
            playHLS(preset)
            return
        }

        guard let preferred = preferredStream() else {
            // No muxed format in the response (the IOS fallback client is adaptive-only), so
            // the default tier is 360p through the transmux pipeline instead of a direct URL.
            if let hls = hlsQualityOptions().first {
                DebugLog.log("Player", "id=\(video.id) no muxed format — defaulting to HLS itag=\(hls.itag)")
                playHLS(hls)
                return
            }
            hideSpinner()
            statusLabel?.text = streams.isEmpty ? "No streams available" : "Still loading streams..."
            statusLabel?.isHidden = false
            playBtn?.isHidden = false
            return
        }

        activeQualityLabel = "360p"
        activeItag = StreamTiers.muxed360
        playBtn?.isHidden = true
        statusLabel?.isHidden = false
        showSpinner()

        // iOS 6 Secure Transport cannot negotiate GCM/CHACHA20 ciphers with googlevideo.com,
        // so AVPlayer cannot connect to it directly. Route AVPlayer through the local
        // HTTP->HTTPS proxy (StreamProxy): AVPlayer talks plain HTTP to 127.0.0.1, the proxy
        // forwards to googlevideo over libcurl+OpenSSL (which speaks the required ciphers).
        // iOS 7+ supports the ciphers natively, so it streams the googlevideo URL directly.
        // A stream that won't start just stops with a status message — the play button comes
        // back and tapping it retries (downloading is left to the explicit Download button).
        // maxTicks are in 0.25s poll units: 40 = 10s (direct), 80 = 20s (proxy).
        let iosVersion = (UIDevice.current.systemVersion as NSString).floatValue
        statusLabel?.text = "Loading stream..."
        DebugLog.log("Player", "playTapped id=\(video.id) itag=\(preferred.itag) mime=\(preferred.mimeType) iOS=\(iosVersion)")
        if iosVersion >= 7.0 {
            tryStream(urlStr: preferred.url, maxTicks: 40)
        } else if let local = StreamProxy.shared.localURL(for: preferred.url) {
            // Give the proxy path more time — the first read primes a TLS handshake to
            // googlevideo through libcurl before AVPlayer sees any bytes.
            DebugLog.log("Player", "id=\(video.id) routing via StreamProxy \(local.absoluteString)")
            tryStream(urlStr: local.absoluteString, maxTicks: 80)
        } else {
            DebugLog.log("Player", "id=\(video.id) StreamProxy.localURL failed — cannot stream")
            hideSpinner()
            statusLabel?.text = "Stream unavailable \u{2022} tap > to retry"
            statusLabel?.isHidden = false
            playBtn?.isHidden = false
        }
    }

    // MARK: - Download

    // One downloadable tier: either the muxed progressive stream (copied byte-for-byte) or a
    // video-only H.264 tier that OfflineDownloader transmuxes against the DASH audio track.
    private struct DownloadChoice {
        let label: String           // "720p", "Audio only"
        let stream: VideoStream
        let isProgressive: Bool
        let isAudioOnly: Bool
        let estimatedBytes: Int64
    }

    // Everything this video can be saved as, ascending. The progressive stream comes first
    // because it is the cheapest and the only one that lands as a plain .mp4; the HLS tiers
    // follow in StreamTiers order. Empty = nothing downloadable (streams not loaded yet, or an
    // adaptive-only response with no audio track to mux against).
    private func downloadChoices() -> [DownloadChoice] {
        var out: [DownloadChoice] = []
        if let p = preferredStream() {
            out.append(DownloadChoice(label: qualityLabel(p), stream: p, isProgressive: true,
                                      isAudioOnly: false, estimatedBytes: p.contentLength))
        }
        if let audio = audioStreamForHLS() {
            for s in hlsQualityOptions() {
                // A transmuxed TS carries the video + audio payload plus MPEG-TS framing
                // (188-byte packets, PES headers, PAT/PMT) — about 5% over the DASH pair.
                let raw = s.contentLength + audio.contentLength
                let est = raw > 0 ? Int64(Double(raw) * 1.05) : 0
                out.append(DownloadChoice(label: qualityLabel(s), stream: s, isProgressive: false,
                                          isAudioOnly: false, estimatedBytes: est))
            }
        }
        return out
    }

    // The audio-only choice, when this video publishes a transmuxable audio track. Listed in
    // its own Format section rather than among the qualities: it is a different KIND of
    // download, and mixing it into a resolution ladder reads as "audio is a quality below 360p".
    private func audioDownloadChoice() -> DownloadChoice? {
        guard let audio = audioStreamForHLS() else { return nil }
        let est = audio.contentLength > 0 ? Int64(Double(audio.contentLength) * 1.05) : 0
        return DownloadChoice(label: "Audio only", stream: audio, isProgressive: false,
                              isAudioOnly: true, estimatedBytes: est)
    }

    // Which row opens selected: whatever was confirmed last time. An exact label match first,
    // so "Audio only" and "720p60" both come back as themselves; otherwise the closest tier at
    // or BELOW that resolution, so a 1080p habit lands on 720p for a video that has no 1080p
    // instead of dropping all the way to 360p. Nothing remembered yet = the first (smallest,
    // muxed) row, which is also the cheapest thing to download by accident.
    private func preselection(_ choices: [DownloadChoice],
                              audio: DownloadChoice?) -> (section: Int, row: Int) {
        let last = AppSettings.lastDownloadChoice
        guard !last.isEmpty else { return (0, 0) }
        if let a = audio, a.label == last { return (1, 0) }
        if let i = choices.firstIndex(where: { $0.label == last }) { return (0, i) }

        let wanted = VideoPlayerVC.resolutionHeight(last)
        guard wanted > 0 else { return (0, 0) }
        var bestRow = 0
        var bestHeight = -1
        for (i, c) in choices.enumerated() {
            let h = VideoPlayerVC.resolutionHeight(c.label)
            if h <= wanted, h > bestHeight { bestHeight = h; bestRow = i }
        }
        return (0, bestRow)
    }

    // Leading digits of a quality label ("720p60" -> 720). 0 when it has none ("Audio only").
    private static func resolutionHeight(_ label: String) -> Int {
        var digits = ""
        for ch in label {
            guard ch >= "0", ch <= "9" else { break }
            digits.append(ch)
        }
        return Int(digits) ?? 0
    }

    @objc private func downloadTapped() {
        guard !DownloadManager.isDownloaded(video.id) else { return }
        let choices = downloadChoices()
        guard !choices.isEmpty else {
            statusLabel?.text = streams.isEmpty ? "Still loading streams..."
                                               : "This video can't be downloaded (no usable stream)"
            statusLabel?.isHidden = false
            return
        }

        let already = DownloadManager.qualityLabel(for: video.id)

        // Two groups, ONE choice: video tiers, then audio-only. Audio is a different kind of
        // download, not a rung below 360p, so it gets its own heading.
        let audioChoice = audioDownloadChoice()
        let alreadyAudio = DownloadManager.isAudioOnly(video.id)

        let pick = preselection(choices, audio: audioChoice)
        var sections = [DownloadOptionSection(
            title: "Video",
            rows: choices.map { downloadRow($0, downloaded: !alreadyAudio && $0.label == already) },
            mode: .exclusive,
            initialSelection: pick.section == 0 ? [pick.row] : [])]
        if let a = audioChoice {
            sections.append(DownloadOptionSection(
                title: "Audio",
                rows: [downloadRow(a, downloaded: alreadyAudio)],
                mode: .exclusive,
                initialSelection: pick.section == 1 ? [0] : []))
        }

        // Captions: independent ticks, not part of the one-of above. Each track is 0.4-5 KB,
        // so the choice is about how long the offline CC menu gets, not about bytes.
        let capSection = captionTracks.count
        if !captionTracks.isEmpty {
            let ticked = captionPreselection()
            sections.append(DownloadOptionSection(
                title: "Captions (tick any)",
                rows: captionTracks.map {
                    DownloadOptionRow(title: $0.name, detail: $0.languageCode,
                                      mark: "", enabled: true, tag: 0)
                },
                mode: .multi,
                initialSelection: ticked))
        }

        DownloadOptionsView.present(in: view, title: "Download", sections: sections,
                                    confirmTitle: "Download") { [weak self] picked in
            guard let self = self else { return }

            // Caption section is last when present; map its ticks back to tracks and remember
            // the languages for next time.
            var tracks: [CaptionTrack] = []
            if capSection > 0, picked.count == sections.count, let rows = picked.last {
                tracks = rows.compactMap { $0 >= 0 && $0 < self.captionTracks.count
                    ? self.captionTracks[$0] : nil }
                AppSettings.lastCaptionLanguages = tracks.map { $0.key }
            }

            // Exclusive: exactly one of the first two sections carries a row.
            if picked.count > 1, let a = audioChoice, !picked[1].isEmpty {
                self.beginDownload(a, captions: tracks)
                return
            }
            guard let videoRows = picked.first, let idx = videoRows.first,
                  idx >= 0, idx < choices.count else { return }
            self.beginDownload(choices[idx], captions: tracks)
        }
    }

    // One picker row (Download and Save to Photos): the tier, its size estimate, and a tick
    // when it is the one already on disk.
    private func downloadRow(_ c: DownloadChoice, downloaded: Bool) -> DownloadOptionRow {
        let detail = c.estimatedBytes > 0
            ? String(format: "~%.0f MB", Double(c.estimatedBytes) / (1024.0 * 1024.0))
            : (c.isProgressive ? "muxed" : "transmuxed")
        return DownloadOptionRow(title: c.label, detail: detail,
                                 mark: downloaded ? "\u{2713}" : "",
                                 enabled: true, tag: 0)
    }

    // Which caption rows open ticked: the languages ticked last time that this video also
    // offers. Nothing remembered yet falls back to the device's own language, then to the
    // first non-auto-generated track — the one a viewer is most likely to want.
    private func captionPreselection() -> [Int] {
        let remembered = AppSettings.lastCaptionLanguages
        if !remembered.isEmpty {
            let hits = captionTracks.enumerated()
                .filter { remembered.contains($0.element.key) }
                .map { $0.offset }
            if !hits.isEmpty { return hits }
        }
        let deviceLang = String((Locale.preferredLanguages.first ?? "en").prefix(2))
        if let i = captionTracks.firstIndex(where: { $0.languageCode.hasPrefix(deviceLang) && !$0.isASR }) {
            return [i]
        }
        if let i = captionTracks.firstIndex(where: { $0.languageCode.hasPrefix(deviceLang) }) {
            return [i]
        }
        if let i = captionTracks.firstIndex(where: { !$0.isASR }) { return [i] }
        return captionTracks.isEmpty ? [] : [0]
    }

    // Start the chosen download, warning first if the estimate doesn't fit on the device.
    private func beginDownload(_ choice: DownloadChoice, captions: [CaptionTrack] = []) {
        // Remembered BEFORE the space check: the user expressed the preference by confirming,
        // whether or not this particular download then fits.
        AppSettings.lastDownloadChoice = choice.label
        let free = DownloadManager.freeDiskBytes()
        // 50MB headroom so a download can't fill the volume to zero. free == 0 means the
        // figure was unavailable — don't block on a number we couldn't read.
        if free > 0, choice.estimatedBytes > 0, choice.estimatedBytes + 50 * 1024 * 1024 > free {
            let alert = UIAlertView()
            alert.title = "Not Enough Space"
            alert.message = String(format: "%@ needs about %.0f MB but only %.0f MB is free.",
                                   choice.label,
                                   Double(choice.estimatedBytes) / (1024.0 * 1024.0),
                                   Double(free) / (1024.0 * 1024.0))
            alert.addButton(withTitle: "OK")
            alert.cancelButtonIndex = 0
            alert.show()
            return
        }

        downloadBtn?.isEnabled = false
        downloadBtn?.setTitle("Downloading...", for: .normal)
        statusLabel?.text = "Downloading \(choice.label)..."
        statusLabel?.isHidden = false

        if choice.isAudioOnly {
            DownloadManager.startAudioDownload(video, audioStream: choice.stream,
                                               quality: choice.label, captions: captions)
        } else if choice.isProgressive {
            DownloadManager.startDownload(video, url: choice.stream.url,
                                          quality: choice.label, captions: captions)
        } else if let audio = audioStreamForHLS() {
            DownloadManager.startHLSDownload(video, videoStream: choice.stream,
                                             audioStream: audio, quality: choice.label,
                                             captions: captions)
        } else {
            statusLabel?.text = "Download failed \u{2022} no audio track"
            updateDownloadButton()
            return
        }
        observeDownload()
    }

    // Load a URL into the singleton, attach the shared layer, and play once ready.
    private func startPlayback(url: URL, isLocal: Bool) {
        let resume = DownloadManager.position(for: video.id)
        sp.load(video: video, url: url, isLocal: isLocal, resume: resume, artwork: thumbView?.image)
        attachLayer()
        DebugLog.log("Player", "startPlayback id=\(video.id) isLocal=\(isLocal) url=\(url.absoluteString)")
        pollUntilReady(maxTicks: 40, interval: 0.25, onReady: { [weak self] in
            guard let self = self else { return }
            DebugLog.log("Player", "startPlayback ready id=\(self.video.id)")
            self.hideSpinner()
            self.hideThumbForPlayback()
            self.statusLabel?.isHidden = true
            self.sp.applyResumeAndPlay()
            self.showControls()
        }, onFail: { [weak self] timedOut in
            guard let self = self else { return }
            let itemError = self.sp.currentItemError?.localizedDescription ?? "none"
            DebugLog.log("Player", "startPlayback FAILED id=\(self.video.id) timedOut=\(timedOut) itemError=\(itemError) \(self.sp.failureDiagnostics)")
            self.hideSpinner()
            self.statusLabel?.text = "Playback failed \u{2022} tap > to retry"
            self.statusLabel?.isHidden = false
            self.playBtn?.isHidden = false
        })
    }

    // Direct/proxied streaming. On failure it stops and re-shows the play button rather than
    // silently downloading the video behind the user's back — tapping > retries.
    private func tryStream(urlStr: String, maxTicks: Int = 40) {
        guard let nsurl = URL(string: urlStr) else {
            statusLabel?.text = "Invalid stream URL"
            statusLabel?.isHidden = false
            playBtn?.isHidden = false
            return
        }
        sp.load(video: video, url: nsurl, isLocal: false, resume: DownloadManager.position(for: video.id), artwork: thumbView?.image)
        // After load(), which clears the field when the video changed — the singleton's
        // reconnect watchdog re-resolves the stream and needs to know the tier it is on.
        sp.activeItag = activeItag
        attachLayer()
        DebugLog.log("Player", "tryStream id=\(video.id) url=\(urlStr) maxTicks=\(maxTicks)")
        pollUntilReady(maxTicks: maxTicks, interval: 0.25, onReady: { [weak self] in
            guard let self = self else { return }
            DebugLog.log("Player", "tryStream ready id=\(self.video.id)")
            self.hideSpinner()
            self.hideThumbForPlayback()
            self.statusLabel?.isHidden = true
            self.sp.applyResumeAndPlay()
            self.showControls()
        }, onFail: { [weak self] timedOut in
            guard let self = self else { return }
            // The AVPlayerItem error, when present, is the single most useful clue for
            // "video won't play" since AVPlayer failures otherwise surface nowhere in the UI.
            let itemError = self.sp.currentItemError?.localizedDescription ?? "none"
            DebugLog.log("Player", "tryStream FAILED id=\(self.video.id) url=\(urlStr) timedOut=\(timedOut) itemError=\(itemError) \(self.sp.failureDiagnostics)")
            // Tear the never-ready item down: a timed-out (not failed) item keeps AVPlayer
            // fetching in the background, and its non-nil item makes isActive() true.
            self.sp.abandonLoad()
            self.detachLayer()
            self.hideSpinner()
            // A timeout may just be a slow connection, so the resolved URLs are kept and a
            // retry reuses them. A hard failure points at the URL itself — force a re-resolve.
            if !timedOut { self.streamsStale = true }
            self.statusLabel?.text = timedOut ? "Stream timed out \u{2022} tap > to retry"
                                              : "Stream failed \u{2022} tap > to retry"
            self.statusLabel?.isHidden = false
            self.playBtn?.isHidden = false
        })
    }

    // Poll the singleton's item status; fire onReady when ready, onFail on failure/timeout.
    // onFail's flag separates the two: true = ran out of ticks while still loading (the item
    // may simply be slow), false = AVPlayerItem reported .failed (the URL itself is bad).
    private func pollUntilReady(maxTicks: Int, interval: TimeInterval,
                                onReady: @escaping () -> Void, onFail: @escaping (Bool) -> Void) {
        if let t = objc_getAssociatedObject(self, &timerKey) as? Timer { t.invalidate() }
        var count = 0
        let timer = Timer(timeInterval: interval, target: BlockTarget { [weak self] in
            guard let self = self else { return }
            count += 1
            if self.sp.isReady {
                if let t = objc_getAssociatedObject(self, &timerKey) as? Timer { t.invalidate() }
                onReady()
            } else if self.sp.isFailed || count > maxTicks {
                let timedOut = !self.sp.isFailed
                if let t = objc_getAssociatedObject(self, &timerKey) as? Timer { t.invalidate() }
                onFail(timedOut)
            }
        }, selector: #selector(BlockTarget.fire), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        objc_setAssociatedObject(self, &timerKey, timer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // VC-owned poll timer that mirrors the manager-owned download's state into the UI.
    // Safe to lose (it's torn down on disappear) — the transfer itself lives in the manager.
    private func observeDownload() {
        if let t = objc_getAssociatedObject(self, &downloadPollKey) as? Timer { t.invalidate() }
        let t = Timer(timeInterval: 0.5, target: BlockTarget { [weak self] in
            guard let self = self else { return }
            if DownloadManager.isDownloading(self.video.id) {
                let pct = Int(DownloadManager.progress(for: self.video.id) * 100)
                self.statusLabel?.text = "Downloading \(pct)%..."
                self.statusLabel?.isHidden = false
                self.downloadBtn?.setTitle("Downloading \(pct)%...", for: .normal)
                return
            }
            // Transfer finished (success or failure) — stop polling and resolve the UI.
            if let t = objc_getAssociatedObject(self, &downloadPollKey) as? Timer { t.invalidate() }
            if DownloadManager.isDownloaded(self.video.id) {
                self.updateDownloadButton()
                self.hideSpinner()
                self.statusLabel?.text = "Saved for offline"
                self.statusLabel?.isHidden = false
                // A "Save When Done" has just started its export (DownloadManager's completion
                // ran before this tick): put its progress on the Share button.
                if PhotoExporter.shared.isBusy(self.video.id) { self.observePhotoExport() }
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

        // Loading / error feedback rides along too — added after the bar so it stays in front
        // of the tap-catcher.
        layoutStatusViews(in: overlay, fullscreen: true)

        // Captions ride into the overlay too (host rule = fsOverlay ?? videoContainer).
        if captionPlate != nil { ensureCaptionPlate() }

        ensureSheetWindow()
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
        if let container = videoContainer { layoutStatusViews(in: container, fullscreen: false) }
        overlay.removeFromSuperview()
        fsOverlay = nil
        teardownSheetWindow()
        // fsOverlay is now nil, so the host resolves back to videoContainer.
        if captionPlate != nil { ensureCaptionPlate() }
    }
}

// MARK: - Timer helper (avoids retain cycles with closures on iOS 6)

private var timerKey = "timerKey"
private var progressTimerKey = "progressTimerKey"
private var downloadPollKey = "downloadPollKey"
private var photoPollKey = "photoPollKey"
private var controlsHideKey = "controlsHideKey"
private var captionTimerKey = "captionTimerKey"

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
// UIMenuController needs a first responder to hang its item on, so the comment row is one.
// The action is deliberately not `copy:` — a custom selector keeps the item from showing up
// on unrelated responders and sidesteps overriding UIResponder's own edit actions.
private class CommentRowView: UIView {
    var copyText = ""

    override var canBecomeFirstResponder: Bool { return true }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        return action == #selector(CommentRowView.copyComment(_:))
    }

    @objc func copyComment(_ sender: Any?) {
        UIPasteboard.general.string = copyText
    }
}

// Label that can host its own "Copy …" menu — used for the video title and the description
// body. Same contract as CommentRowView: a custom selector rather than copy:, so the item
// never shows up on unrelated responders. copyText is the full text, which for the
// description is not what the (collapsed) label is displaying.
private class CopyableLabel: UILabel {
    var copyText = ""
    var copyMenuTitle = "Copy"

    override var canBecomeFirstResponder: Bool { return true }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        return action == #selector(CopyableLabel.copyValue(_:))
    }

    @objc func copyValue(_ sender: Any?) {
        UIPasteboard.general.string = copyText
    }
}

// Covers the whole screen, so without this every tap in fullscreen would be swallowed and
// the controls bar would go dead. A hit on the root view (nothing presented) is declined and
// the touch falls through to the app window; once a sheet is up, the hit lands on the sheet's
// own views instead and is kept.
private class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit === self || hit === rootViewController?.view { return nil }
        return hit
    }
}

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
