import UIKit
import AVFoundation
import MediaPlayer

class VideoPlayerVC: UIViewController {

    private let video: Video
    private var streams: [VideoStream] = []
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var playerItem: AVPlayerItem?

    // UI
    private var scrollView: UIScrollView?
    private var thumbView: AsyncImageView?
    private var playBtn: UIButton?
    private var statusLabel: UILabel?
    private var titleLabel: UILabel?
    private var channelLabel: UILabel?
    private var metaLabel: UILabel?
    private var videoContainer: UIView?
    private var downloadBtn: UIButton?
    private var fsOverlay: UIView?

    // Playback controls (play/pause + scrubber)
    private var controlsView: UIView?
    private var playPauseBtn: UIButton?
    private var scrubber: UISlider?
    private var currentTimeLabel: UILabel?
    private var durationLabel: UILabel?
    private var fsButton: UIButton?
    private var fsCloseBtn: UIButton?
    private var isScrubbing = false
    private var fsAngle: CGFloat = CGFloat(Double.pi / 2)
    private var fsActive = false
    private var lastSavedPos: Double = 0   // throttle for resume-position writes

    // iOS 7+ view-controller-based status bar control (ignored on iOS 6).
    override var prefersStatusBarHidden: Bool { return fsActive }

    // Required so we receive lock-screen / headset remote-control events.
    override var canBecomeFirstResponder: Bool { return true }

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
        // Lock-screen / headset transport controls (legacy path — iOS 6+).
        UIApplication.shared.beginReceivingRemoteControlEvents()
        becomeFirstResponder()
        guard scrollView == nil else { return }
        setupUI()
        loadStreams()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        NotificationCenter.default.removeObserver(self)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        UIApplication.shared.endReceivingRemoteControlEvents()
        resignFirstResponder()
        stopPlayback()
    }

    // Lock-screen / headset transport buttons (the legacy responder-chain API; the
    // modern MPRemoteCommandCenter is iOS 7.1+ and crashes on iOS 6).
    override func remoteControlReceived(with event: UIEvent?) {
        guard let event = event, event.type == .remoteControl else { return }
        switch event.subtype {
        case .remoteControlPlay:
            player?.play()
            playPauseBtn?.setTitle("||", for: .normal)
            updateNowPlayingInfo()
        case .remoteControlPause:
            player?.pause()
            playPauseBtn?.setTitle(">", for: .normal)
            updateNowPlayingInfo()
        case .remoteControlTogglePlayPause:
            togglePlayPause()
            updateNowPlayingInfo()
        default:
            break
        }
    }

    @objc private func appDidBecomeActive() {
        // The audio session can be deactivated by the system in the background; re-arm it
        // and resync the scrubber/now-playing to the player's real position.
        try? AVAudioSession.sharedInstance().setActive(true)
        updateProgress()
        updateNowPlayingInfo()
    }

    // Route audio to the Playback category so it keeps playing when the screen is locked
    // or the app is backgrounded (paired with the UIBackgroundModes "audio" Info.plist key).
    private func configureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback)
        try? s.setActive(true)
    }

    // MARK: - Now Playing (lock screen) metadata

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = video.title
        info[MPMediaItemPropertyArtist] = video.channelName
        if let item = playerItem {
            let dur = CMTimeGetSeconds(item.duration)
            if dur.isFinite, dur > 0 { info[MPMediaItemPropertyPlaybackDuration] = dur }
            let cur = CMTimeGetSeconds(item.currentTime())
            if cur.isFinite { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = cur }
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = (player?.rate ?? 0)
        if let img = thumbView?.image {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(image: img)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // Lightweight per-tick update of just the elapsed time + rate (no artwork rebuild).
    private func refreshNowPlayingElapsed() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        if let item = playerItem {
            let cur = CMTimeGetSeconds(item.currentTime())
            if cur.isFinite { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = cur }
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = (player?.rate ?? 0)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Orientation → fullscreen

    // The app window stays portrait (iOS 6-safe); rotating the device drives the
    // fullscreen overlay's rotation so the video fills the screen in landscape.
    @objc private func orientationChanged() {
        guard playerLayer != nil else { return }   // only while a video is loaded
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
                positionCloseButton()
            }
        } else if fsOverlay != nil {
            exitFullscreen()
        }
    }

    // MARK: - UI Setup

    private func setupUI() {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height

        let sv = UIScrollView(frame: CGRect(x: 0, y: 0, width: w, height: h - 64))
        sv.backgroundColor = UIColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
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

        // Play button overlay
        let btn = UIButton(type: .custom)
        btn.frame = CGRect(x: (w - 64) / 2, y: (videoH - 64) / 2, width: 64, height: 64)
        btn.backgroundColor = UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 0.9)
        btn.layer.cornerRadius = 32
        btn.setTitle(">", for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 28)
        btn.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        container.addSubview(btn)
        playBtn = btn

        // Status label (loading/error messages)
        let sl = UILabel()
        sl.backgroundColor = .clear
        sl.textColor = UIColor(white: 0.7, alpha: 1)
        sl.textAlignment = .center
        sl.font = UIFont.systemFont(ofSize: 13)
        sl.numberOfLines = 2
        sl.isHidden = true
        sl.frame = CGRect(x: 0, y: videoH - 28, width: w, height: 28)
        container.addSubview(sl)
        statusLabel = sl

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
        if !video.channelId.isEmpty {
            let chanBtn = UIButton(type: .custom)
            chanBtn.frame = channelL.frame
            chanBtn.backgroundColor = .clear
            chanBtn.addTarget(self, action: #selector(channelTapped), for: .touchUpInside)
            sv.addSubview(chanBtn)
        }
        y += 24

        // Meta (duration + published + views)
        let meta = [video.durationText, video.publishedText, video.viewCountText].filter { !$0.isEmpty }.joined(separator: " • ")
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

        // Download-for-offline button
        let dl = UIButton(type: .custom)
        dl.frame = CGRect(x: padding, y: y, width: w - padding * 2, height: 44)
        dl.layer.cornerRadius = 6
        dl.setTitleColor(.white, for: .normal)
        dl.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
        dl.addTarget(self, action: #selector(downloadTapped), for: .touchUpInside)
        sv.addSubview(dl)
        downloadBtn = dl
        y += 44 + 12
        updateDownloadButton()

        sv.contentSize = CGSize(width: w, height: y + 20)
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
        pp.setTitle("||", for: .normal)
        pp.setTitleColor(.white, for: .normal)
        pp.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
        pp.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)
        bar.addSubview(pp)
        playPauseBtn = pp

        let cur = UILabel()
        cur.backgroundColor = .clear
        cur.textColor = .white
        cur.font = UIFont.systemFont(ofSize: 11)
        cur.textAlignment = .center
        cur.text = "0:00"
        bar.addSubview(cur)
        currentTimeLabel = cur

        let dur = UILabel()
        dur.backgroundColor = .clear
        dur.textColor = .white
        dur.font = UIFont.systemFont(ofSize: 11)
        dur.textAlignment = .center
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

        let fs = UIButton(type: .custom)
        fs.setImage(fullscreenIcon(), for: .normal)
        fs.addTarget(self, action: #selector(fullscreenTapped), for: .touchUpInside)
        bar.addSubview(fs)
        fsButton = fs

        layoutControls(width: w)
    }

    // Position the control bar's children for a given bar width (bar frame set by caller).
    // Layout: [play 40][cur 44] ===slider=== [dur 40][fullscreen 36]
    private func layoutControls(width w: CGFloat) {
        let barH: CGFloat = 40
        playPauseBtn?.frame = CGRect(x: 0, y: 0, width: 40, height: barH)
        currentTimeLabel?.frame = CGRect(x: 40, y: 0, width: 44, height: barH)
        fsButton?.frame = CGRect(x: w - 36, y: 0, width: 36, height: barH)
        durationLabel?.frame = CGRect(x: w - 36 - 40, y: 0, width: 40, height: barH)
        scrubber?.frame = CGRect(x: 88, y: 0, width: w - 88 - 36 - 40, height: barH)
    }

    // A simple two-corner-bracket "expand" glyph drawn in code (reliable on iOS 6 fonts).
    private func fullscreenIcon() -> UIImage? {
        let s = CGSize(width: 20, height: 20)
        UIGraphicsBeginImageContextWithOptions(s, false, UIScreen.main.scale)
        guard let ctx = UIGraphicsGetCurrentContext() else { UIGraphicsEndImageContext(); return nil }
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(2)
        let len: CGFloat = 6
        // top-left
        ctx.move(to: CGPoint(x: 2, y: 7)); ctx.addLine(to: CGPoint(x: 2, y: 2)); ctx.addLine(to: CGPoint(x: 7, y: 2))
        // top-right
        ctx.move(to: CGPoint(x: 18 - len, y: 2)); ctx.addLine(to: CGPoint(x: 18, y: 2)); ctx.addLine(to: CGPoint(x: 18, y: 7))
        // bottom-left
        ctx.move(to: CGPoint(x: 2, y: 18 - len)); ctx.addLine(to: CGPoint(x: 2, y: 18)); ctx.addLine(to: CGPoint(x: 7, y: 18))
        // bottom-right
        ctx.move(to: CGPoint(x: 18, y: 18 - len)); ctx.addLine(to: CGPoint(x: 18, y: 18)); ctx.addLine(to: CGPoint(x: 18 - len, y: 18))
        ctx.strokePath()
        let img = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return img
    }

    private func showControls() {
        controlsView?.isHidden = false
        playPauseBtn?.setTitle("||", for: .normal)
        startProgressTimer()
        updateNowPlayingInfo()
    }

    private func startProgressTimer() {
        if let t = objc_getAssociatedObject(self, &progressTimerKey) as? Timer { t.invalidate() }
        let t = Timer(timeInterval: 0.5, target: BlockTarget { [weak self] in
            self?.updateProgress()
        }, selector: #selector(BlockTarget.fire), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        objc_setAssociatedObject(self, &progressTimerKey, t, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func updateProgress() {
        guard let item = playerItem, item.status == .readyToPlay else { return }
        let dur = CMTimeGetSeconds(item.duration)
        let cur = CMTimeGetSeconds(item.currentTime())
        guard dur.isFinite, dur > 0, cur.isFinite else { return }
        durationLabel?.text = timeString(dur)
        if !isScrubbing {
            scrubber?.value = Float(cur / dur)
            currentTimeLabel?.text = timeString(cur)
        }
        // Keep button glyph in sync with actual rate
        playPauseBtn?.setTitle((player?.rate ?? 0) > 0 ? "||" : ">", for: .normal)
        refreshNowPlayingElapsed()

        // Persist resume position for downloaded videos (throttled to ~5s).
        if DownloadManager.isDownloaded(video.id) {
            if cur >= dur - 2 {
                DownloadManager.clearPosition(for: video.id)   // finished → restart next time
                lastSavedPos = 0
            } else if abs(cur - lastSavedPos) >= 5 {
                lastSavedPos = cur
                DownloadManager.savePosition(cur, for: video.id)
            }
        }
    }

    private func timeString(_ seconds: Double) -> String {
        let s = Int(seconds)
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    @objc private func togglePlayPause() {
        guard let p = player else { return }
        if p.rate > 0 {
            p.pause()
            playPauseBtn?.setTitle(">", for: .normal)
        } else {
            p.play()
            playPauseBtn?.setTitle("||", for: .normal)
        }
        updateNowPlayingInfo()
    }

    @objc private func scrubTouchDown() { isScrubbing = true }

    @objc private func scrubChanged() {
        guard let item = playerItem else { return }
        let dur = CMTimeGetSeconds(item.duration)
        guard dur.isFinite, dur > 0, let v = scrubber?.value else { return }
        currentTimeLabel?.text = timeString(Double(v) * dur)
    }

    @objc private func scrubTouchUp() {
        guard let p = player, let item = playerItem, let v = scrubber?.value else { isScrubbing = false; return }
        let dur = CMTimeGetSeconds(item.duration)
        if dur.isFinite, dur > 0 {
            let target = CMTimeMakeWithSeconds(Double(v) * dur, preferredTimescale: 600)
            p.seek(to: target)
        }
        isScrubbing = false
        updateNowPlayingInfo()
    }

    // MARK: - Stream loading

    private func loadStreams() {
        // Already downloaded — no network needed, play offline.
        if DownloadManager.isDownloaded(video.id) {
            statusLabel?.text = "Downloaded \u{2022} tap > to play"
            statusLabel?.isHidden = false
            return
        }

        statusLabel?.text = "Loading..."
        statusLabel?.isHidden = false

        YoutubeAPI.getStreams(videoId: video.id) { [weak self] streams, _ in
            guard let self = self else { return }
            self.streams = streams
            self.statusLabel?.text = streams.isEmpty ? "No streams available" : "Tap > to play"
        }
    }

    // MARK: - Stream selection

    private func preferredStream() -> VideoStream? {
        return streams.first { $0.itag == 18 }
            ?? streams.first { $0.mimeType.contains("mp4") && !$0.mimeType.contains("av01") }
            ?? streams.first { $0.mimeType.contains("video") }
            ?? streams.first
    }

    // MARK: - Playback

    @objc private func playTapped() {
        // Offline copy takes priority.
        if DownloadManager.isDownloaded(video.id) {
            playBtn?.isHidden = true
            statusLabel?.isHidden = true
            playLocalFile(path: DownloadManager.filePath(for: video.id))
            return
        }

        guard let preferred = preferredStream() else {
            statusLabel?.text = "Still loading streams..."
            statusLabel?.isHidden = false
            return
        }

        playBtn?.isHidden = true
        statusLabel?.isHidden = false

        // iOS 6 Secure Transport cannot negotiate GCM ciphers with googlevideo.com, so
        // AVPlayer cannot stream directly — download-then-play via CurlFetcher (OpenSSL).
        // iOS 7+ supports GCM, so try direct streaming with a quick download fallback.
        let iosVersion = (UIDevice.current.systemVersion as NSString).floatValue
        if iosVersion >= 7.0 {
            statusLabel?.text = "Loading stream..."
            tryAVPlayer(url: preferred.url, fallbackDownload: preferred.url)
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

    private func tryAVPlayer(url: String, fallbackDownload: String) {
        guard let nsurl = URL(string: url) else {
            statusLabel?.text = "Invalid stream URL"
            statusLabel?.isHidden = false
            playBtn?.isHidden = false
            return
        }

        stopPlayback()
        configureAudioSession()

        let item = AVPlayerItem(url: nsurl)
        playerItem = item
        let p = AVPlayer(playerItem: item)
        player = p

        let container = videoContainer!
        let pLayer = AVPlayerLayer(player: p)
        pLayer.frame = container.bounds
        pLayer.videoGravity = AVLayerVideoGravity.resizeAspect
        container.layer.insertSublayer(pLayer, below: thumbView?.layer)
        playerLayer = pLayer

        // Poll for status — if not ready in ~4s, fall back to download-then-play.
        var checkCount = 0
        let checkTimer = Timer(timeInterval: 0.5, target: BlockTarget {
            [weak self, weak item, weak p] in
            guard let self = self, let item = item else { return }
            checkCount += 1
            if item.status == .readyToPlay {
                self.thumbView?.isHidden = true
                self.statusLabel?.isHidden = true
                p?.play()
                self.showControls()
                return
            }
            if item.status == .failed || checkCount > 8 {
                if let t = objc_getAssociatedObject(self, &timerKey) as? Timer { t.invalidate() }
                self.statusLabel?.text = "Downloading..."
                self.statusLabel?.isHidden = false
                pLayer.removeFromSuperlayer()
                self.playerLayer = nil
                self.download(url: fallbackDownload, autoPlay: true)
            }
        }, selector: #selector(BlockTarget.fire), userInfo: nil, repeats: true)
        RunLoop.main.add(checkTimer, forMode: .common)
        objc_setAssociatedObject(self, &timerKey, checkTimer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // Download to persistent storage, register for offline, optionally play when done.
    private func download(url: String, autoPlay: Bool) {
        let path = DownloadManager.filePath(for: video.id)
        try? FileManager.default.removeItem(atPath: path)
        DownloadManager.registerPartial(video)   // visible in Downloads while in progress / if it fails

        CurlFetcher.downloadToFile(url: url, outputPath: path, progress: { [weak self] p in
            self?.statusLabel?.text = "Downloading \(Int(p * 100))%..."
            if !autoPlay { self?.downloadBtn?.setTitle("Downloading \(Int(p * 100))%...", for: .normal) }
        }) { [weak self] success in
            guard let self = self else { return }
            if success {
                DownloadManager.register(self.video)
                self.updateDownloadButton()
                if autoPlay {
                    self.statusLabel?.isHidden = true
                    self.thumbView?.isHidden = true
                    self.playLocalFile(path: path)
                } else {
                    self.statusLabel?.text = "Saved for offline"
                    self.statusLabel?.isHidden = false
                }
            } else {
                self.statusLabel?.text = "Download failed"
                self.statusLabel?.isHidden = false
                self.playBtn?.isHidden = false
                self.updateDownloadButton()
            }
        }
    }

    private func playLocalFile(path: String) {
        let url = URL(fileURLWithPath: path)
        stopPlayback()
        configureAudioSession()
        let item = AVPlayerItem(url: url)
        playerItem = item
        let p = AVPlayer(playerItem: item)
        player = p
        let container = videoContainer!
        let pLayer = AVPlayerLayer(player: p)
        pLayer.frame = container.bounds
        pLayer.videoGravity = AVLayerVideoGravity.resizeAspect
        container.layer.insertSublayer(pLayer, below: thumbView?.layer)
        playerLayer = pLayer

        // Wait for the local item to be ready before playing (iOS 6 won't reliably
        // auto-start if play() is called before the asset's tracks are loaded).
        var readyCount = 0
        let readyTimer = Timer(timeInterval: 0.25, target: BlockTarget {
            [weak self, weak item, weak p] in
            guard let self = self, let item = item else { return }
            readyCount += 1
            if item.status == .readyToPlay {
                if let t = objc_getAssociatedObject(self, &timerKey) as? Timer { t.invalidate() }
                self.thumbView?.isHidden = true
                // Resume where we left off (skip if at the very start or near the end).
                let resume = DownloadManager.position(for: self.video.id)
                let dur = CMTimeGetSeconds(item.duration)
                if resume > 5, !(dur.isFinite && dur > 0 && resume >= dur - 5) {
                    self.lastSavedPos = resume
                    p?.seek(to: CMTimeMakeWithSeconds(resume, preferredTimescale: 600))
                }
                p?.play()
                self.showControls()
            } else if item.status == .failed || readyCount > 40 {
                if let t = objc_getAssociatedObject(self, &timerKey) as? Timer { t.invalidate() }
                self.statusLabel?.text = "Playback failed"
                self.statusLabel?.isHidden = false
                self.playBtn?.isHidden = false
            }
        }, selector: #selector(BlockTarget.fire), userInfo: nil, repeats: true)
        RunLoop.main.add(readyTimer, forMode: .common)
        objc_setAssociatedObject(self, &timerKey, readyTimer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func stopPlayback() {
        if let t = objc_getAssociatedObject(self, &timerKey) as? Timer { t.invalidate() }
        if let t = objc_getAssociatedObject(self, &progressTimerKey) as? Timer { t.invalidate() }
        if fsOverlay != nil { exitFullscreen() }
        // Save the resume position on exit for downloaded videos.
        if let item = playerItem, DownloadManager.isDownloaded(video.id) {
            let dur = CMTimeGetSeconds(item.duration)
            let cur = CMTimeGetSeconds(item.currentTime())
            if cur.isFinite, cur > 5 {
                if dur.isFinite, dur > 0, cur >= dur - 5 {
                    DownloadManager.clearPosition(for: video.id)
                } else {
                    DownloadManager.savePosition(cur, for: video.id)
                }
            }
        }
        player?.pause()
        player = nil
        playerItem = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        controlsView?.isHidden = true
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    // MARK: - Fullscreen

    @objc private func fullscreenTapped() {
        guard playerLayer != nil else {
            statusLabel?.text = "Start playback first"
            statusLabel?.isHidden = false
            return
        }
        if fsOverlay == nil {
            // Match the current device orientation if it's already landscape.
            let o = UIDevice.current.orientation
            let angle: CGFloat = (o == .landscapeRight) ? CGFloat(-Double.pi / 2) : CGFloat(Double.pi / 2)
            setFullscreen(true, angle: angle)
        } else {
            setFullscreen(false, angle: 0)
        }
    }

    private func enterFullscreen() {
        guard let pLayer = playerLayer, let window = view.window else { return }

        // The app is portrait-locked, so UIScreen.main.bounds is always the portrait
        // (320x568) frame. The overlay is sized to landscape (dims swapped) and rotated
        // to fill the screen — this is what makes the controls span the full width.
        let screen = UIScreen.main.bounds
        let overlay = UIView()
        overlay.backgroundColor = .black
        overlay.bounds = CGRect(x: 0, y: 0, width: screen.height, height: screen.width)
        overlay.center = CGPoint(x: screen.midX, y: screen.midY)
        overlay.transform = CGAffineTransform(rotationAngle: fsAngle)
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

        let close = UIButton(type: .custom)
        close.bounds = CGRect(x: 0, y: 0, width: 58, height: 36)
        close.backgroundColor = UIColor(white: 0, alpha: 0.5)
        close.layer.cornerRadius = 6
        close.setTitle("Close", for: .normal)
        close.setTitleColor(.white, for: .normal)
        close.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
        close.addTarget(self, action: #selector(fullscreenTapped), for: .touchUpInside)
        overlay.addSubview(close)
        fsCloseBtn = close
        positionCloseButton()

        // Move the controls bar into the (rotated) overlay so it's usable in fullscreen.
        if let bar = controlsView, !bar.isHidden {
            let barH: CGFloat = 40
            bar.frame = CGRect(x: 0, y: overlay.bounds.height - barH, width: overlay.bounds.width, height: barH)
            overlay.addSubview(bar)
            layoutControls(width: overlay.bounds.width)
        }
    }

    // Keep the Close button at the viewer's top-right for either landscape side.
    private func positionCloseButton() {
        guard let overlay = fsOverlay, let close = fsCloseBtn else { return }
        if fsAngle < 0 {
            // landscapeRight — viewer top-right maps to overlay-local bottom-left
            close.center = CGPoint(x: 16 + close.bounds.width / 2,
                                   y: overlay.bounds.height - 16 - close.bounds.height / 2)
        } else {
            close.center = CGPoint(x: overlay.bounds.width - 16 - close.bounds.width / 2,
                                   y: 16 + close.bounds.height / 2)
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
        if let pLayer = playerLayer, let container = videoContainer {
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
        fsCloseBtn = nil
    }
}

// MARK: - Timer helper (avoids retain cycles with closures on iOS 6)

private var timerKey = "timerKey"
private var progressTimerKey = "progressTimerKey"

private class BlockTarget: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}
