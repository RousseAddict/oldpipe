import UIKit

// MARK: - CastController
// The app's Chromecast connection. It lives here rather than in a page so it outlives
// whichever page started it — the same split as VideoPlayer.shared for local playback — and the
// mini bar, every video page and the app delegate all look at the same state.
//
// While it is active the app is in CAST MODE: a play tap on any video page plays on the TV,
// Next and playlist autoplay advance on the TV, and the phone's own player stays stopped. Cast
// mode ends only when the viewer stops casting, or the TV does (stopped from the TV or Google
// Home, or the TV cannot be reached again).
//
// Losing the connection does NOT end it. iOS suspends the app soon after the screen locks
// (background audio only covers the phone playing sound, and it is silent while casting), the
// TV stops hearing the heartbeat and drops the socket, and the video carries on playing on the
// TV. So on the way back the controller opens a new connection and JOINS the media already
// playing instead of loading it again — position, play state and all. The device and video are
// kept on disk for the same reason: a cold launch after iOS killed the app rejoins too.

final class CastController {

    static let shared = CastController()

    // Posted on the main queue whenever anything below changes.
    static let didChange = Notification.Name("oldpipe.castDidChange")

    enum State { case idle, connecting, connected, reconnecting }
    enum Phase { case loading, buffering, playing, paused, finished, failed }

    private(set) var state = State.idle
    private(set) var device: CastDevice?
    // The video on the TV, or being loaded onto it.
    private(set) var video: Video?
    private(set) var phase = Phase.loading
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    // 0...1, or -1 until the TV has said.
    private(set) var volume: Double = -1
    // Why the current video is not playing (phase == .failed).
    private(set) var failure = ""
    // Why cast mode last ended, when that is news to the viewer ("Lost connection to …").
    // Cleared by the next cast.
    private(set) var endMessage = ""

    var isActive: Bool { return state != .idle }
    var isPlaying: Bool { return isActive && (phase == .playing || phase == .buffering) }
    func isCasting(_ videoId: String) -> Bool { return isActive && video?.id == videoId }

    // Set by the frontmost VideoPlayerVC, like VideoPlayer.onAdvance: the TV moved on from
    // `from` to the next queued video (autoplay or Next), so a page showing `from` swaps in place.
    var onAdvance: ((_ from: String, _ to: Video) -> Void)?

    // Devices found on the LAN — browsed while a video page is on screen (see startDiscovery).
    private(set) var devices: [CastDevice] = []

    private var session: CastSession?
    // Bumped by every cast(): a stream answer for a video replaced since is dropped.
    private var loadGen = 0
    // A join is out and its answer decides which video is on the TV.
    private var joinPending = false
    private var reconnectAttempts = 0
    private var reconnectTimer: Timer?
    // The connection dropped while the app was in the background; rejoin when it comes back.
    private var rejoinOnActive = false
    private var reconnectBrowsing = false
    private var bgTask = UIBackgroundTaskIdentifier.invalid
    private var lastSavedPosition: Double = 0

    private let discovery = CastDiscovery()
    private var browsers = 0

    private static let maxReconnectAttempts = 3
    private static let reconnectDelays: [TimeInterval] = [0.5, 2, 5]

    private init() {
        discovery.onUpdate = { [weak self] list in
            guard let self = self else { return }
            self.devices = list
            // The TV in use may have come back on another address (DHCP) — the next join
            // goes there.
            if let d = self.device, let fresh = list.first(where: { $0.name == d.name }), fresh.host != d.host {
                DebugLog.log("Cast", "\(d.name) moved \(d.host) -> \(fresh.host)")
                self.device = fresh
            }
        }
    }

    // One line for the mini bar and the cast panel: "Playing on Living Room TV".
    var statusText: String {
        let name = device?.name ?? "TV"
        switch state {
        case .idle: return ""
        case .connecting: return "Connecting to \(name)\u{2026}"
        case .reconnecting: return "Reconnecting to \(name)\u{2026}"
        case .connected: break
        }
        switch phase {
        case .loading: return "Loading on \(name)\u{2026}"
        case .buffering: return "Buffering on \(name)\u{2026}"
        case .playing: return "Playing on \(name)"
        case .paused: return "Paused on \(name)"
        case .finished: return "Finished on \(name)"
        case .failed: return failure.isEmpty ? "Couldn't play on \(name)" : failure
        }
    }

    // MARK: - Discovery

    // Browsing runs while any video page is visible, so the picker usually opens with the
    // devices already found. Counted, because pages overlap during a push or pop.
    func startDiscovery() {
        browsers += 1
        if browsers == 1 { discovery.start() }
    }

    func stopDiscovery() {
        browsers = max(0, browsers - 1)
        if browsers == 0 && !reconnectBrowsing { discovery.stop() }
    }

    // MARK: - Casting

    // Play `video` on the TV: on `newDevice` when given (the picker), else on the TV already in
    // use. `streams` is the page's own player answer when it has one; without, it is fetched.
    // `fresh` asks YouTube again rather than reusing an answer (a retry after a failure).
    func cast(_ video: Video, on newDevice: CastDevice? = nil, streams: [VideoStream]? = nil,
              fresh: Bool = false) {
        guard let target = newDevice ?? device else { return }
        if let s = session, s.device.name != target.name || s.device.host != target.host {
            // Another TV: the one in use goes back to its own screen.
            s.stop()
            session = nil
            state = .connecting
        }
        device = target
        cancelReconnect()
        if joinPending {
            // A rejoin is still finding out what the TV is playing, and a joining session
            // never loads anything — start over with one that does.
            session?.close()
            session = nil
            joinPending = false
        }
        endMessage = ""
        // The phone stops playing and saves its position, which is where the TV starts.
        // The queue stays: it drives Next and autoplay on the TV.
        VideoPlayer.shared.stop(keepQueue: true)
        self.video = video
        phase = .loading
        failure = ""
        position = 0
        duration = 0
        lastSavedPosition = 0
        if state == .idle { state = .connecting }
        loadGen += 1
        let gen = loadGen
        HistoryManager.record(video)
        DebugLog.log("Cast", "cast id=\(video.id) on \(target.name) state=\(state)")
        post()

        let p = DownloadManager.position(for: video.id)
        let startAt = p > 5 ? p : 0
        // A Chromecast fetches the URL itself, so it needs a self-contained muxed file — it can
        // neither reach the local transmux proxy nor mux two adaptive tracks on its own.
        if !fresh, let list = streams, let pick = StreamResolver.pickPreferred(list) {
            send(video, url: pick.url, startAt: startAt)
            return
        }
        YoutubeAPI.getStreams(videoId: video.id, reuse: !fresh) { [weak self] list, _, _, reason, _ in
            guard let self = self, gen == self.loadGen, self.isActive else { return }
            guard let pick = StreamResolver.pickPreferred(list) else {
                let why = list.isEmpty ? (reason.isEmpty ? "No streams available" : reason)
                                       : "This video can't be cast (no muxed stream)"
                DebugLog.log("Cast", "no castable stream id=\(video.id): \(why)")
                if self.session == nil && self.state == .connecting {
                    // Nothing on the TV yet: there is no cast to stay in.
                    self.end(message: why)
                } else {
                    self.phase = .failed
                    self.failure = why
                    self.post()
                }
                return
            }
            self.send(video, url: pick.url, startAt: startAt)
        }
    }

    private func send(_ video: Video, url: String, startAt: Double) {
        guard let d = device else { return }
        saveRecord(contentId: url)
        if let s = session {
            s.load(url: url, video: video, startAt: startAt)
        } else {
            makeSession(d).start(url: url, video: video, startAt: startAt)
        }
    }

    // MARK: - Controls

    func togglePlayPause() { if isPlaying { pause() } else { play() } }

    func play() {
        guard isActive, let v = video else { return }
        // A finished video replays from the start (it was marked watched); a failed one asks
        // YouTube again, since an expired URL is the usual reason.
        if phase == .finished || phase == .failed {
            cast(v, fresh: phase == .failed)
            return
        }
        session?.play()
        phase = .playing   // optimistic: the next status confirms it within a second
        post()
    }

    func pause() {
        guard isActive else { return }
        session?.pause()
        phase = .paused
        savePositionNow()
        post()
    }

    func seek(to seconds: Double) {
        guard isActive, phase != .finished, phase != .failed else { return }
        var t = max(0, seconds)
        if duration > 0 { t = min(t, duration) }
        session?.seek(to: t)
        position = t
        post()
    }

    func seek(by delta: Double) { seek(to: position + delta) }

    func setVolume(_ level: Double) {
        guard isActive else { return }
        volume = min(1, max(0, level))
        session?.setVolume(volume)
    }

    // Next, from a page showing `videoId`. False when there is nothing queued after it.
    @discardableResult
    func skipToNext(from videoId: String) -> Bool {
        guard isActive else { return false }
        savePositionNow()
        return advance(from: videoId)
    }

    // Stop casting: the TV goes back to its own screen and the phone gets its player back,
    // resuming where the TV was.
    func stop() {
        guard isActive else { return }
        savePositionNow()
        session?.stop()
        session = nil
        end(message: "")
    }

    // MARK: - App lifecycle (from AppDelegate)

    func appDidBecomeActive() {
        endBackgroundHold()
        if state == .idle {
            restore()
        } else if rejoinOnActive || session == nil {
            rejoinOnActive = false
            reconnectAttempts = 0
            cancelReconnect()
            state = .reconnecting
            post()
            join()
        } else {
            // A socket that sat through a suspension can look open long after the TV dropped
            // it; a probe the TV does not answer ends it, and the drop rejoins.
            session?.probe()
        }
    }

    // Keep the connection while iOS lets a backgrounded app finish its work (about ten
    // minutes on iOS 6, three from iOS 7): a short lock then costs nothing, and a playlist
    // can still advance on the TV meanwhile. After that the app is suspended and the next
    // appDidBecomeActive rejoins.
    func appDidEnterBackground() {
        guard isActive, bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(expirationHandler: { [weak self] in
            DebugLog.log("Cast", "background hold expired")
            self?.endBackgroundHold()
        })
    }

    private func endBackgroundHold() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    // MARK: - Session events

    private func makeSession(_ d: CastDevice) -> CastSession {
        let s = CastSession(device: d)
        s.onEvent = { [weak self, weak s] e in
            // A session replaced since (another TV, a reconnect) has nothing more to say.
            guard let self = self, let s = s, s === self.session else { return }
            self.handle(e, from: s)
        }
        session = s
        return s
    }

    private func handle(_ e: CastSession.Event, from s: CastSession) {
        switch e {
        case .media(let st):
            markConnected()
            apply(st)
        case .joined(let st):
            markConnected()
            if joinPending {
                joinPending = false
                guard let v = recognise(st) else {
                    // Something on the TV that oldpipe did not cast: leave it alone.
                    DebugLog.log("Cast", "join: TV is playing something else — not taking it over")
                    s.close()
                    session = nil
                    end(message: "")
                    return
                }
                video = v
                saveRecord(contentId: st.contentId)
            }
            apply(st)
        case .nothingToJoin:
            // The video finished or was stopped while we were away, and the TV has moved on.
            s.close()
            session = nil
            end(message: "")
            return
        case .ended(let reason):
            handleEnded(reason)
        case .loadFailed:
            if state == .connecting {
                // Nothing ever played: the receiver would not start, so there is no cast to stay in.
                s.close()
                session = nil
                end(message: "The TV couldn't play this video")
                return
            }
            phase = .failed
            failure = "The TV couldn't play this video"
        case .appClosed:
            session = nil
            savePositionNow()   // a play on the phone picks up where the TV was
            end(message: "Casting was stopped on the TV")
            return
        case .volume(let level):
            volume = level
        case .closed(let lost):
            session = nil
            guard lost else { end(message: ""); return }
            if state == .connecting {
                end(message: "Couldn't connect to \(s.device.name)")
                return
            }
            scheduleReconnect()
        }
        post()
    }

    private func markConnected() {
        guard state != .connected else { return }
        DebugLog.log("Cast", "connected (was \(state))")
        state = .connected
        reconnectAttempts = 0
        stopReconnectBrowsing()
    }

    private func apply(_ st: CastMediaStatus) {
        // A late status from the video a LOAD has just replaced must not move this one.
        if let v = video, !st.videoId.isEmpty, st.videoId != v.id { return }
        position = st.currentTime
        if st.duration > 0 { duration = st.duration }
        switch st.playerState {
        case "PLAYING": phase = .playing
        case "PAUSED": phase = .paused
        case "BUFFERING": phase = .buffering
        default: break   // IDLE arrives as .ended (or is a LOAD still starting)
        }
        if phase != .failed { failure = "" }
        savePositionThrottled()
    }

    // Which video a joined media session is. customData carries the id from our own LOAD; a TV
    // that does not echo it back is matched on the URL we sent. Anything else was not cast by
    // oldpipe.
    private func recognise(_ st: CastMediaStatus) -> Video? {
        let rec = savedRecord()
        if !st.videoId.isEmpty {
            if let v = video, v.id == st.videoId { return v }
            if let rv = rec?.video, rv.id == st.videoId { return rv }
            // Cast by oldpipe, but not the video this phone last knew (another phone).
            return Video(id: st.videoId, title: st.title, channelName: st.subtitle, channelId: "",
                         thumbnailURL: "https://i.ytimg.com/vi/\(st.videoId)/mqdefault.jpg",
                         durationText: "", viewCountText: "", publishedText: "")
        }
        if let r = rec, !r.contentId.isEmpty, r.contentId == st.contentId { return r.video ?? video }
        return nil
    }

    private func handleEnded(_ reason: String) {
        guard let v = video else { return }
        switch reason {
        case "FINISHED":
            DownloadManager.markWatched(v.id)
            position = duration
            if advance(from: v.id) { return }
            phase = .finished
        case "ERROR":
            phase = .failed
            failure = "The TV couldn't play this video"
        default:
            // CANCELLED: stopped from the TV's remote or another phone. The receiver is still up.
            savePositionNow()
            phase = .finished
        }
    }

    // Autoplay or Next: the queued video after `id` plays on the TV.
    private func advance(from id: String) -> Bool {
        guard let next = VideoPlayer.shared.takeNextInQueue(after: id) else { return false }
        DebugLog.log("Cast", "advance \(id) -> \(next.id)")
        cast(next)
        onAdvance?(id, next)
        return true
    }

    // MARK: - Reconnecting

    private func scheduleReconnect() {
        guard isActive else { return }
        if UIApplication.shared.applicationState == .background {
            // A suspended app cannot hold a connection anyway; try again on the way back.
            DebugLog.log("Cast", "connection lost in the background — rejoin when active")
            rejoinOnActive = true
            state = .reconnecting
            return
        }
        guard reconnectAttempts < CastController.maxReconnectAttempts else {
            end(message: "Lost connection to \(device?.name ?? "the TV")")
            return
        }
        reconnectAttempts += 1
        state = .reconnecting
        startReconnectBrowsing()
        let delays = CastController.reconnectDelays
        let delay = delays[min(reconnectAttempts - 1, delays.count - 1)]
        reconnectTimer?.invalidate()
        let t = Timer(timeInterval: delay, target: CastTimerTarget { [weak self] in self?.join() },
                      selector: #selector(CastTimerTarget.fire), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
        reconnectTimer = t
    }

    private func join() {
        reconnectTimer = nil
        guard isActive, let d = device else { return }
        DebugLog.log("Cast", "rejoin attempt \(reconnectAttempts) on \(d.name) \(d.host)")
        joinPending = true
        makeSession(d).join()
    }

    private func cancelReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        rejoinOnActive = false
        stopReconnectBrowsing()
    }

    // While reconnecting, browse too: a TV that changed address is found under its name.
    private func startReconnectBrowsing() {
        guard !reconnectBrowsing else { return }
        reconnectBrowsing = true
        if browsers == 0 { discovery.start() }
    }

    private func stopReconnectBrowsing() {
        guard reconnectBrowsing else { return }
        reconnectBrowsing = false
        if browsers == 0 { discovery.stop() }
    }

    // A cold launch with a cast on record (iOS killed the app in the background): one quiet
    // attempt to pick it back up.
    private func restore() {
        guard let rec = savedRecord() else { return }
        DebugLog.log("Cast", "restoring cast on \(rec.device.name) id=\(rec.video?.id ?? "-")")
        device = rec.device
        video = rec.video
        phase = .loading
        state = .reconnecting
        reconnectAttempts = CastController.maxReconnectAttempts - 1
        post()
        join()
    }

    private func end(message: String) {
        DebugLog.log("Cast", "cast mode ended \(message)")
        cancelReconnect()
        state = .idle
        endMessage = message
        joinPending = false
        video = nil
        device = nil
        phase = .loading
        position = 0
        duration = 0
        volume = -1
        failure = ""
        loadGen += 1
        clearRecord()
        endBackgroundHold()
        post()
    }

    private func post() {
        NotificationCenter.default.post(name: CastController.didChange, object: self)
    }

    // MARK: - Resume positions (shared with the phone's player)

    private func savePositionThrottled() {
        guard let v = video, phase == .playing || phase == .paused else { return }
        guard abs(position - lastSavedPosition) >= 5 else { return }
        lastSavedPosition = position
        if position > 5 && (duration <= 0 || position < duration - 5) {
            DownloadManager.savePosition(position, for: v.id)
        }
    }

    private func savePositionNow() {
        guard let v = video, phase != .loading, phase != .failed else { return }
        if duration > 0 && position >= duration - 5 {
            DownloadManager.markWatched(v.id)
        } else if position > 5 {
            DownloadManager.savePosition(position, for: v.id)
        }
    }

    // MARK: - Saved session (UserDefaults)

    private static let recordKey = "cast_session"

    private struct Record {
        let device: CastDevice
        let video: Video?
        let contentId: String
    }

    private func saveRecord(contentId: String) {
        guard let d = device else { return }
        var r: [String: Any] = ["name": d.name, "host": d.host, "port": d.port,
                                "serviceName": d.serviceName, "contentId": contentId]
        if let v = video { r["video"] = v.toDict() }
        UserDefaults.standard.set(r, forKey: CastController.recordKey)
    }

    private func savedRecord() -> Record? {
        guard let r = UserDefaults.standard.dictionary(forKey: CastController.recordKey),
              let name = r["name"] as? String, let host = r["host"] as? String else { return nil }
        // NSNumber path: numeric `as? Int` silently fails on the 5.1.5 runtime.
        let port = (r["port"] as? NSNumber)?.intValue ?? 8009
        let d = CastDevice(name: name, host: host, port: port,
                           serviceName: (r["serviceName"] as? String) ?? "")
        let v = (r["video"] as? [String: Any]).flatMap { Video.from(dict: $0) }
        return Record(device: d, video: v, contentId: (r["contentId"] as? String) ?? "")
    }

    private func clearRecord() {
        UserDefaults.standard.removeObject(forKey: CastController.recordKey)
    }
}

// Timer target wrapper so the Timer doesn't retain the controller via a selector.
private class CastTimerTarget: NSObject {
    let block: () -> Void
    init(_ b: @escaping () -> Void) { block = b }
    @objc func fire() { block() }
}
