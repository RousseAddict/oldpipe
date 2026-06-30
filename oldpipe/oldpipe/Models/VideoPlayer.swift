import UIKit
import AVFoundation
import MediaPlayer

// MARK: - VideoPlayer
// App-wide singleton that owns the AVPlayer so playback (especially audio) survives
// navigating away from VideoPlayerVC. It also drives the lock-screen Now Playing info,
// handles remote-control transport, and persists resume positions for downloaded videos.
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

    // MARK: - Load / state

    // Load a new item. Does not seek/play until applyResumeAndPlay() is called (the VC
    // waits for readiness first — iOS 6 won't reliably auto-start before tracks load).
    func load(video: Video, url: URL, isLocal: Bool, resume: Double, artwork: UIImage?) {
        configureAudioSession()
        if player == nil {
            let p = AVPlayer()
            player = p
            layer.player = p
            layer.videoGravity = AVLayerVideoGravity.resizeAspect
        }
        let newItem = AVPlayerItem(url: url)
        item = newItem
        player?.replaceCurrentItem(with: newItem)
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
        ticker?.invalidate(); ticker = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        layer.removeFromSuperlayer()
        item = nil
        currentVideo = nil
        artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false)
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

    // MARK: - Resume persistence (downloaded videos only)

    private func saveResumeThrottled() {
        guard let v = currentVideo, DownloadManager.isDownloaded(v.id) else { return }
        let cur = currentSeconds, dur = durationSeconds
        if dur > 0, cur >= dur - 2 {
            DownloadManager.markWatched(v.id); lastSavedPos = 0
        } else if abs(cur - lastSavedPos) >= 5 {
            lastSavedPos = cur; DownloadManager.savePosition(cur, for: v.id)
        }
    }

    private func saveResume() {
        guard let v = currentVideo, DownloadManager.isDownloaded(v.id) else { return }
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
