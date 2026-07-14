import UIKit
import AVFoundation
import MediaPlayer

// MARK: - VideoPlayer
// App-wide singleton that owns the AVPlayer so playback (especially audio) survives
// navigating away from VideoPlayerVC. It also drives the lock-screen Now Playing info,
// handles remote-control transport, and persists resume positions for all videos.
// MiniPlayerBar and VideoPlayerVC are thin views onto this shared state.

class VideoPlayer {

    static let shared = VideoPlayer()
    private init() {}

    // Persistent layer — each VideoPlayerVC reattaches it into its own video container
    // (and the fullscreen overlay). Removing it from a superlayer does NOT stop audio.
    let layer = AVPlayerLayer()

    private(set) var player: AVPlayer?
    private(set) var item: AVPlayerItem?
    private(set) var currentVideo: Video?
    private(set) var isLocal = false

    private var pendingResume: Double = 0
    private var didApplyResume = false
    private var lastSavedPos: Double = 0
    private var artwork: UIImage?
    private var ticker: Timer?
    private var endObserver: NSObjectProtocol?   // AVPlayerItemDidPlayToEndTime for the current item
    private var lastLoadWasHLS = false           // content type of the last load() — see type-switch note in load()

    // MARK: - Autoplay queue (playlists)
    // Set by PlaylistDetailVC before pushing the player. When the current item plays to the
    // end, the singleton auto-advances to the next queued video (stopping at the end — no
    // loop). Because the queue lives here, autoplay continues even after VideoPlayerVC is
    // popped and only the mini bar remains. onAdvance lets the frontmost VideoPlayerVC (if
    // any) swap its content to the new video.
    private(set) var queue: [Video] = []
    private(set) var queueIndex = 0
    var onAdvance: ((Video) -> Void)?
    private var advanceWaitTimer: Timer?

    func setQueue(_ videos: [Video], startIndex: Int) {
        queue = videos
        queueIndex = startIndex
    }

    func clearQueue() {
        queue = []
        queueIndex = 0
        advanceWaitTimer?.invalidate(); advanceWaitTimer = nil
    }

    // MARK: - Load / state

    // Load a new item. Does not seek/play until applyResumeAndPlay() is called (the VC
    // waits for readiness first — iOS 6 won't reliably auto-start before tracks load).
    func load(video: Video, url: URL, isLocal: Bool, resume: Double, artwork: UIImage?) {
        configureAudioSession()
        // iOS 6 AVPlayer cannot replaceCurrentItem across content types (progressive MP4
        // <-> HLS): the new HLS item probes the playlist then fails with bare -11800
        // without ever requesting a segment. Recreate the player on a type switch.
        let isHLS = url.absoluteString.hasSuffix(".m3u8")
        if player != nil && isHLS != lastLoadWasHLS {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }
        lastLoadWasHLS = isHLS
        if player == nil {
            let p = AVPlayer()
            player = p
            layer.player = p
            layer.videoGravity = AVLayerVideoGravity.resizeAspect
        }
        let newItem = AVPlayerItem(url: url)
        item = newItem
        player?.replaceCurrentItem(with: newItem)
        // Close the proxy stream when this item plays to the end (see handlePlaybackEnded).
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: newItem, queue: OperationQueue.main) { [weak self] _ in
            self?.handlePlaybackEnded()
        }
        currentVideo = video
        self.isLocal = isLocal
        self.artwork = artwork
        pendingResume = resume
        didApplyResume = false
        lastSavedPos = resume
        updateNowPlayingInfo()
        startTicker()
    }

    var isReady: Bool { return item?.status == .readyToPlay }
    var isFailed: Bool { return item?.status == .failed }

    // TEMPORARY (HLS debug): AVFoundation error domain/code of the current item, if any.
    var itemErrorText: String {
        guard let e = item?.error as NSError? else { return "none" }
        var s = "\(e.domain) \(e.code)"
        if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError {
            s += " / \(u.domain) \(u.code)"
        }
        return s
    }

    // True when the current video's display size is taller than wide (e.g. a Short).
    // Uses the asset track's naturalSize + preferredTransform — iOS 4+ safe, unlike
    // AVPlayerItem.presentationSize / AVPlayerLayer.videoRect (both iOS 7+).
    var isPortraitVideo: Bool {
        guard let track = item?.asset.tracks(withMediaType: AVMediaType.video).first else { return false }
        let size = track.naturalSize.applying(track.preferredTransform)
        return abs(size.height) > abs(size.width)
    }
    func isActive(_ videoId: String) -> Bool { return currentVideo?.id == videoId && item != nil }
    var isPlaying: Bool { return (player?.rate ?? 0) > 0 }

    // Seek to the saved resume point (once) and begin playback. Call when isReady.
    func applyResumeAndPlay() {
        guard let p = player, let it = item else { return }
        if !didApplyResume {
            didApplyResume = true
            let dur = CMTimeGetSeconds(it.duration)
            if pendingResume > 5, !(dur.isFinite && dur > 0 && pendingResume >= dur - 5) {
                p.seek(to: CMTimeMakeWithSeconds(pendingResume, preferredTimescale: 600))
            }
            if let v = currentVideo { HistoryManager.record(v) }
        }
        p.play()
        updateNowPlayingInfo()
    }

    func play() { player?.play(); updateNowPlayingInfo() }
    func pause() { player?.pause(); saveResume(); updateNowPlayingInfo() }
    func togglePlayPause() { if isPlaying { pause() } else { play() } }

    func seek(toFraction f: Double) {
        guard let it = item else { return }
        let dur = CMTimeGetSeconds(it.duration)
        guard dur.isFinite, dur > 0 else { return }
        player?.seek(to: CMTimeMakeWithSeconds(f * dur, preferredTimescale: 600))
        updateNowPlayingInfo()
    }

    // Relative skip (double-tap seek). Clamps to [0, duration]; seeking a streamed video
    // just issues a new Range request through the proxy — same cost as the scrubber.
    func seek(bySeconds delta: Double) {
        guard isReady else { return }
        let dur = durationSeconds
        var target = currentSeconds + delta
        if target < 0 { target = 0 }
        if dur > 0, target > dur { target = dur }
        player?.seek(to: CMTimeMakeWithSeconds(target, preferredTimescale: 600))
        updateNowPlayingInfo()
    }

    var currentSeconds: Double {
        guard let it = item else { return 0 }
        let c = CMTimeGetSeconds(it.currentTime())
        return c.isFinite ? c : 0
    }
    var durationSeconds: Double {
        guard let it = item else { return 0 }
        let d = CMTimeGetSeconds(it.duration)
        return d.isFinite ? d : 0
    }

    // Full teardown — used by the mini bar's close button.
    func stop() {
        saveResume()
        clearQueue()
        ticker?.invalidate(); ticker = nil
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs); endObserver = nil }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        layer.removeFromSuperlayer()
        StreamProxy.shared.closeCurrentStream()   // abort the libcurl transfer promptly
        item = nil
        currentVideo = nil
        artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    // Abandon a load that never became ready (stream fallback path). Unlike stop() there is
    // no position to save (nothing ever played) and the queue is left alone. Removing the item
    // matters twice over: (1) a timed-out-but-not-failed item keeps AVPlayer fetching in the
    // background — for HLS that means segment transmux fetches holding the feed turnstile and
    // competing with the fallback download; (2) isActive() checks `item != nil`, so a lingering
    // item makes the download-completion handler skip auto-play and freeze at "Downloading 100%".
    func abandonLoad() {
        ticker?.invalidate(); ticker = nil
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs); endObserver = nil }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        StreamProxy.shared.closeCurrentStream()   // abort in-flight proxy/HLS transfers promptly
        item = nil
        currentVideo = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // The current item reached its end. Tear down the underlying proxy stream so a finished
    // stream's libcurl transfer doesn't linger blocked in a socket send() holding a worker
    // thread. Routes stay valid (see closeCurrentStream), so a scrub-back reconnect still works.
    private func handlePlaybackEnded() {
        if !isLocal { StreamProxy.shared.closeCurrentStream() }
        updateNowPlayingInfo()
        advanceQueueIfPossible()
    }

    // MARK: - Autoplay advance

    // Advance to the next queued video, if the video that just ended is still the current
    // queue item (guards against having navigated to a non-queue video) and a next item
    // exists (stop at the end — no loop).
    private func advanceQueueIfPossible() {
        guard !queue.isEmpty,
              queueIndex >= 0, queueIndex < queue.count,
              currentVideo?.id == queue[queueIndex].id,
              queueIndex + 1 < queue.count else { return }
        queueIndex += 1
        let next = queue[queueIndex]
        StreamResolver.resolve(next) { [weak self] resolved in
            guard let self = self else { return }
            // Bail if the queue changed or was cleared while resolving.
            guard !self.queue.isEmpty, self.queueIndex < self.queue.count,
                  self.queue[self.queueIndex].id == next.id else { return }
            guard let r = resolved else { return }   // couldn't resolve — stop the chain
            let resume = DownloadManager.position(for: next.id)
            self.load(video: next, url: r.url, isLocal: r.isLocal, resume: resume, artwork: nil)
            self.onAdvance?(next)   // let the frontmost VideoPlayerVC swap its content
            self.waitForReadyThenPlay()
        }
    }

    // Poll the new item's status and begin playback once ready. UI-independent counterpart
    // of VideoPlayerVC.pollUntilReady — used when the queue auto-advances with no VC driving
    // the load. maxTicks in 0.25s units (80 = 20s, matching the iOS 6 proxy path).
    private func waitForReadyThenPlay(maxTicks: Int = 80) {
        advanceWaitTimer?.invalidate()
        var count = 0
        let t = Timer(timeInterval: 0.25, target: TickProxy { [weak self] in
            guard let self = self else { return }
            count += 1
            if self.isReady {
                self.advanceWaitTimer?.invalidate(); self.advanceWaitTimer = nil
                self.applyResumeAndPlay()
            } else if self.isFailed || count > maxTicks {
                self.advanceWaitTimer?.invalidate(); self.advanceWaitTimer = nil
            }
        }, selector: #selector(TickProxy.fire), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        advanceWaitTimer = t
    }

    func setArtwork(_ img: UIImage?) {
        guard let img = img else { return }
        artwork = img
        updateNowPlayingInfo()
    }

    func reactivateSession() { try? AVAudioSession.sharedInstance().setActive(true) }

    // MARK: - Audio session

    // Playback category keeps audio going when the screen is locked / app backgrounded
    // (paired with the UIBackgroundModes "audio" Info.plist key patched in build.sh).
    private func configureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback)
        try? s.setActive(true)
    }

    // MARK: - Ticker (now-playing + resume persistence, independent of any VC)

    private func startTicker() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 1.0, target: TickProxy { [weak self] in self?.tick() },
                      selector: #selector(TickProxy.fire), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        guard item?.status == .readyToPlay else { return }
        refreshNowPlayingElapsed()
        saveResumeThrottled()
    }

    // MARK: - Resume persistence (all videos — streamed and downloaded)

    private func saveResumeThrottled() {
        guard let v = currentVideo else { return }
        let cur = currentSeconds, dur = durationSeconds
        if dur > 0, cur >= dur - 2 {
            DownloadManager.markWatched(v.id); lastSavedPos = 0
        } else if abs(cur - lastSavedPos) >= 5 {
            lastSavedPos = cur; DownloadManager.savePosition(cur, for: v.id)
        }
    }

    private func saveResume() {
        guard let v = currentVideo else { return }
        let cur = currentSeconds, dur = durationSeconds
        guard cur > 5 else { return }
        if dur > 0, cur >= dur - 5 { DownloadManager.markWatched(v.id) }
        else { DownloadManager.savePosition(cur, for: v.id) }
    }

    // MARK: - Now Playing (lock screen)

    func updateNowPlayingInfo() {
        guard let v = currentVideo else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = v.title
        info[MPMediaItemPropertyArtist] = v.channelName
        if durationSeconds > 0 { info[MPMediaItemPropertyPlaybackDuration] = durationSeconds }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentSeconds
        info[MPNowPlayingInfoPropertyPlaybackRate] = (player?.rate ?? 0)
        if let img = artwork { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(image: img) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func refreshNowPlayingElapsed() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentSeconds
        info[MPNowPlayingInfoPropertyPlaybackRate] = (player?.rate ?? 0)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Remote control (forwarded from PlayerWindow / AppDelegate)

    func handleRemoteControl(_ subtype: UIEvent.EventSubtype) {
        switch subtype {
        case .remoteControlPlay:            play()
        case .remoteControlPause:           pause()
        case .remoteControlTogglePlayPause: togglePlayPause()
        default: break
        }
    }
}

// Tiny target wrapper so the repeating Timer doesn't retain the singleton via a selector.
private class TickProxy: NSObject {
    let block: () -> Void
    init(_ b: @escaping () -> Void) { block = b }
    @objc func fire() { block() }
}
