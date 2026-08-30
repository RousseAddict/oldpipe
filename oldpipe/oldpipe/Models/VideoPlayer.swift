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

    // MARK: - Playback watchdog
    // A streamed video can die mid-playback: googlevideo drops the transfer, or the network
    // goes away for a moment. StreamProxy already reconnects the upstream leg a few times,
    // but once those are spent the client socket closes and AVPlayer — which has no notion
    // of reconnecting — either stalls on a frozen frame or reads the short body as
    // end-of-stream. Nothing used to be watching after the initial load, so the only way out
    // was to quit the app and reopen the video. The 1 Hz ticker below now notices and
    // re-resolves the stream from the last position played.
    //
    // `wantsPlayback` is the user's intent, so a deliberate pause is never mistaken for a
    // drop. It is the singleton's own state rather than `player.rate` because AVPlayer drops
    // the rate to 0 on a stall too — the whole thing we are trying to detect.
    private var wantsPlayback = false
    private var lastTickSeconds: Double = -1
    private var stalledTicks = 0
    private var recoveryAttempts = 0
    private var recovering = false
    private var recoveryTimer: Timer?

    // Seconds of no progress before the stream is presumed dead. Generous enough to ride out
    // ordinary rebuffering on a slow connection, short enough not to feel like a hang.
    private static let stallTicks = 8
    private static let maxRecoveryAttempts = 3
    // Backoff between attempts. A drop is usually a blip, so try quickly first, then give a
    // genuinely-down network time to come back before spending the last attempt.
    private static let recoveryDelays: [TimeInterval] = [2, 5, 10]

    enum RecoveryState {
        case reconnecting(attempt: Int)
        case recovered
        case failed
    }
    // Set by the frontmost player VC (last-writer-wins, like onAdvance) so it can say
    // "Reconnecting…" instead of showing a dead frame. Recovery runs with or without it.
    var onRecovery: ((RecoveryState) -> Void)?

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
        DebugLog.log("VideoPlayer", "load id=\(video.id) isLocal=\(isLocal) resume=\(resume) url=\(url.absoluteString)")
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
        // Watchdog state is per-load, except the attempt counter during a recovery — that one
        // has to survive the reload it is driving, or every attempt would look like the first.
        // Loading a *different* video supersedes a recovery outright.
        if recovering, currentVideo?.id != video.id { cancelRecovery() }
        wantsPlayback = false
        lastTickSeconds = -1
        stalledTicks = 0
        if !recovering { recoveryAttempts = 0 }
        updateNowPlayingInfo()
        startTicker()
    }

    var isReady: Bool { return item?.status == .readyToPlay }
    var isFailed: Bool { return item?.status == .failed }
    // The AVPlayerItem's error, when status == .failed. AVPlayerItem failures otherwise surface
    // nowhere in the UI (silent on iOS 6) — this is what DebugLog call sites report.
    var currentItemError: Error? { return item?.error }

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
        wantsPlayback = true
        p.play()
        updateNowPlayingInfo()
    }

    func play() { wantsPlayback = true; player?.play(); updateNowPlayingInfo() }
    func pause() { wantsPlayback = false; player?.pause(); saveResume(); updateNowPlayingInfo() }
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
        cancelRecovery()
        wantsPlayback = false
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
        cancelRecovery()
        wantsPlayback = false
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
        // A stream that died mid-file leaves AVPlayer reading a short body, which it reports
        // as a clean end-of-stream — indistinguishable from a finished video except by the
        // clock. Anything ending materially early is a drop, not an ending, so recover instead
        // of marking it watched and advancing the playlist past it.
        if !isLocal, wantsPlayback, durationSeconds > 0, currentSeconds < durationSeconds - 5 {
            beginRecovery(reason: "premature end")
            return
        }
        wantsPlayback = false
        if !isLocal { StreamProxy.shared.closeCurrentStream() }
        updateNowPlayingInfo()
        advanceQueueIfPossible()
    }

    // MARK: - Recovery

    // Called once per tick while a stream is supposed to be playing. Returns true when a
    // recovery was started, so the caller skips its normal bookkeeping for this tick.
    private func checkPlaybackAlive() -> Bool {
        // A recovery in flight must not retrigger itself, and the detached item it left behind
        // must not be mined for a resume position — report "handled" so the tick stops there.
        if recovering { return true }
        // Only streams can drop: a local file cannot, and a paused video is not expected to advance.
        guard wantsPlayback, !isLocal, item != nil, currentVideo != nil else {
            lastTickSeconds = -1
            stalledTicks = 0
            return false
        }
        if isFailed {
            beginRecovery(reason: "item failed")
            return true
        }
        let cur = currentSeconds, dur = durationSeconds
        // Sitting on the last few seconds is the video ending, not a stall.
        if dur > 0, cur >= dur - 2 { stalledTicks = 0; return false }
        // Compare on absolute movement so a backwards seek counts as progress too —
        // otherwise rewinding would look like a stall until playback caught up again.
        let moved = lastTickSeconds < 0 || abs(cur - lastTickSeconds) > 0.25
        lastTickSeconds = cur
        if moved {
            stalledTicks = 0
            recoveryAttempts = 0   // playback is healthy again — a later drop starts fresh
            return false
        }
        stalledTicks += 1
        guard stalledTicks >= VideoPlayer.stallTicks else { return false }
        beginRecovery(reason: "stalled \(stalledTicks)s at \(Int(cur))s")
        return true
    }

    // Tear down the dead stream and schedule a re-resolve from the position we got to.
    private func beginRecovery(reason: String) {
        guard let video = currentVideo, !isLocal else { return }
        guard recoveryAttempts < VideoPlayer.maxRecoveryAttempts else {
            DebugLog.log("VideoPlayer", "recovery GIVING UP id=\(video.id) after \(recoveryAttempts) attempts")
            // Unlike a load that never started, this video did play — keep the position so
            // reopening it later resumes at the drop rather than from the beginning.
            saveResume()
            // Then tear down as abandonLoad does: a dead item left in place keeps AVPlayer
            // fetching against it and makes isActive() lie to the mini bar and the player VC.
            abandonLoad()
            onRecovery?(.failed)
            return
        }
        recovering = true
        recoveryAttempts += 1
        stalledTicks = 0
        let attempt = recoveryAttempts
        let at = currentSeconds
        DebugLog.log("VideoPlayer", "recovery id=\(video.id) attempt=\(attempt) reason=\(reason) at=\(Int(at))s")
        onRecovery?(.reconnecting(attempt: attempt))
        // Detach the dead item so AVPlayer stops fetching against it in the background — on
        // iOS 6 those fetches otherwise compete with the replacement stream through the proxy.
        // `item` itself is deliberately left set: isActive() keys off it, and nilling it here
        // would make the mini bar and the player VC think playback had been closed.
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        StreamProxy.shared.closeCurrentStream()
        let delay = VideoPlayer.recoveryDelays[min(attempt - 1, VideoPlayer.recoveryDelays.count - 1)]
        recoveryTimer?.invalidate()
        let t = Timer(timeInterval: delay, target: TickProxy { [weak self] in
            self?.performRecovery(video: video, at: at)
        }, selector: #selector(TickProxy.fire), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
        recoveryTimer = t
    }

    // Re-resolve and reload. Resolving again rather than reusing the old URL is what makes
    // this work for the two common causes at once: it mints a fresh proxy route (the old
    // one's connection is gone) and picks up a new googlevideo URL if the previous one expired.
    private func performRecovery(video: Video, at: Double) {
        recoveryTimer = nil
        // The user may have closed, paused, or switched video during the backoff.
        guard recovering, currentVideo?.id == video.id else { recovering = false; return }
        StreamResolver.resolve(video) { [weak self] resolved in
            guard let self = self else { return }
            guard self.recovering, self.currentVideo?.id == video.id else {
                self.recovering = false
                return
            }
            guard let r = resolved else {
                DebugLog.log("VideoPlayer", "recovery resolve FAILED id=\(video.id)")
                self.recovering = false
                self.beginRecovery(reason: "resolve failed")
                return
            }
            self.load(video: video, url: r.url, isLocal: r.isLocal, resume: at, artwork: self.artwork)
            self.wantsPlayback = true
            self.waitForReadyThenPlay(onReady: { [weak self] in
                guard let self = self else { return }
                self.recovering = false
                self.lastTickSeconds = -1
                self.stalledTicks = 0
                DebugLog.log("VideoPlayer", "recovery OK id=\(video.id) resumed at \(Int(at))s")
                self.onRecovery?(.recovered)
            }, onFail: { [weak self] in
                guard let self = self else { return }
                self.recovering = false
                self.beginRecovery(reason: "reload never became ready")
            })
        }
    }

    private func cancelRecovery() {
        recoveryTimer?.invalidate(); recoveryTimer = nil
        recovering = false
        recoveryAttempts = 0
        stalledTicks = 0
        lastTickSeconds = -1
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
            guard let r = resolved else {
                DebugLog.log("VideoPlayer", "autoplay-advance FAILED to resolve id=\(next.id) — stopping queue")
                return   // couldn't resolve — stop the chain
            }
            let resume = DownloadManager.position(for: next.id)
            self.load(video: next, url: r.url, isLocal: r.isLocal, resume: resume, artwork: nil)
            self.onAdvance?(next)   // let the frontmost VideoPlayerVC swap its content
            self.waitForReadyThenPlay()
        }
    }

    // Poll the new item's status and begin playback once ready. UI-independent counterpart
    // of VideoPlayerVC.pollUntilReady — used when the queue auto-advances with no VC driving
    // the load. maxTicks in 0.25s units (80 = 20s, matching the iOS 6 proxy path).
    private func waitForReadyThenPlay(maxTicks: Int = 80,
                                      onReady: (() -> Void)? = nil,
                                      onFail: (() -> Void)? = nil) {
        advanceWaitTimer?.invalidate()
        var count = 0
        let t = Timer(timeInterval: 0.25, target: TickProxy { [weak self] in
            guard let self = self else { return }
            count += 1
            if self.isReady {
                self.advanceWaitTimer?.invalidate(); self.advanceWaitTimer = nil
                self.applyResumeAndPlay()
                onReady?()
            } else if self.isFailed || count > maxTicks {
                self.advanceWaitTimer?.invalidate(); self.advanceWaitTimer = nil
                onFail?()
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
        if checkPlaybackAlive() { return }
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
