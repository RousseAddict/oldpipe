import Foundation

// MARK: - CastSession
//
// One TLS connection to a Chromecast (port 8009, via the curl bridge's CONNECT_ONLY socket —
// OpenSSL speaks the modern ciphers iOS 6 can't) and the CASTV2 conversation over it. It plays
// media on the Default Media Receiver in one of two ways:
//   - start(): get the receiver app running (launching it when it isn't), then LOAD.
//   - join():  attach to a receiver app that is ALREADY playing. The phone lost its connection
//              (it slept, or iOS suspended the app on the lock screen) while the TV carried on;
//              nothing is launched or loaded, the media session is adopted as it stands.
// The TV does not care which socket its commands arrive on, so a lost connection is replaced
// by a new session that joins — CastController owns that decision.
//
// THREADING: everything TLS runs on ONE background thread (`ioLoop`). OpenSSL SSL_read /
// SSL_write on the same SSL object are not thread-safe, so the socket is never touched from
// two threads — and neither is the protocol state (transport id, media session id), which only
// the ioLoop reads and writes. Public methods queue a Command under `lock`; the ioLoop runs
// them between 500ms recv polls. Events go back on the main queue.

// The receiver's media as of its latest MEDIA_STATUS.
struct CastMediaStatus {
    var playerState = ""          // PLAYING, BUFFERING, PAUSED, IDLE
    var currentTime: Double = 0
    var duration: Double = 0
    // What the TV says it is playing, read back from the LOAD's customData and metadata. A
    // join learns the video from these rather than trusting what the phone last remembered.
    var videoId = ""
    var contentId = ""
    var title = ""
    var subtitle = ""

    var isPlaying: Bool { return playerState == "PLAYING" || playerState == "BUFFERING" }
}

final class CastSession: NSObject {

    enum Event {
        // A media session is on the TV — reported on every MEDIA_STATUS.
        case media(CastMediaStatus)
        // join() attached to the media already on the TV (in whatever state it is).
        case joined(CastMediaStatus)
        // join() found nothing to attach to: no receiver app running, or one with no media.
        case nothingToJoin
        // The loaded media stopped for good: "FINISHED", "ERROR", or "CANCELLED" (stopped from
        // the TV or another phone). A LOAD replacing it ("INTERRUPTED") is not an ending.
        case ended(String)
        // The TV refused to launch the receiver or to LOAD the URL.
        case loadFailed
        // The receiver app went away — stopped from the TV or Google Home, or another app took
        // the screen. The session closes itself after this.
        case appClosed
        case volume(Double)
        // The connection is gone. `lost` is false only when stop()/close() asked for it.
        case closed(lost: Bool)
    }

    let device: CastDevice
    var onEvent: ((Event) -> Void)?

    private enum Command {
        case load(url: String, contentType: String, video: Video, startAt: Double)
        case media([String: Any])   // PLAY / PAUSE / SEEK — the media session id is added on send
        case volume(Double)
        case probe
        case stopApp
        case close
    }

    // Shared with the caller's thread — everything else below is the ioLoop's alone.
    private let lock = NSLock()
    private var commands = [Command]()
    private var started = false

    private var handle: CurlHandle?
    private var joining = false
    private var launched = false
    private var requestId = 0
    // The receiver app's channel, learned from RECEIVER_STATUS.
    private var transportId: String?
    private var appSessionId: String?
    private var mediaSessionId: Int?
    // The media session a LOAD replaced. Statuses for it can still be in flight, and must not
    // be taken for the new one.
    private var replacedSessionId: Int?
    // join() asked for the media status and is waiting for the first answer.
    private var awaitingJoin = false
    // A LOAD waiting for the receiver app to come up.
    private var pendingLoad: Command?
    private var status = CastMediaStatus()
    private var lastVolume: Double = -1

    private var lastHeartbeat = Date()
    private var lastStatusPoll = Date()
    private var lastInbound = Date()
    // Set by probe(): the connection is presumed dead unless the TV answers by then.
    private var probeDeadline: Date?
    // Why the loop is ending, once it is. nil = keep going.
    private var exitLost: Bool?

    private static let senderId = "sender-0"
    private static let platformReceiver = "receiver-0"
    // The Default Media Receiver — plays a plain media URL, no custom receiver app needed.
    static let mediaReceiverApp = "CC1AD845"
    // The TV answers our 5s heartbeat, so this long without a byte from it means the
    // connection is gone even when the socket has not said so (a suspended app's socket can
    // look open for a while after the TV dropped it).
    private static let silenceLimit: TimeInterval = 30
    private static let probeTimeout: TimeInterval = 6

    init(device: CastDevice) {
        self.device = device
        super.init()
    }

    // MARK: - Public API (any thread — just queues a command for the ioLoop)

    // Connect, get the media receiver running, and LOAD `video` from `url`.
    func start(url: String, contentType: String = "video/mp4", video: Video, startAt: Double) {
        pendingLoad = .load(url: url, contentType: contentType, video: video, startAt: startAt)
        run(joining: false)
    }

    // Connect and attach to whatever the media receiver is already playing.
    func join() {
        run(joining: true)
    }

    // Play another video on the same connection.
    func load(url: String, contentType: String = "video/mp4", video: Video, startAt: Double) {
        enqueue(.load(url: url, contentType: contentType, video: video, startAt: startAt))
    }

    func play()  { enqueue(.media(["type": "PLAY"])) }
    func pause() { enqueue(.media(["type": "PAUSE"])) }
    func seek(to seconds: Double) { enqueue(.media(["type": "SEEK", "currentTime": seconds])) }
    func setVolume(_ level: Double) { enqueue(.volume(min(1, max(0, level)))) }

    // Ask the TV for its status now and give up on the connection if it does not answer
    // within a few seconds — called when the app comes back to the foreground, since a
    // socket that sat through a suspension can look open long after the TV dropped it.
    func probe() { enqueue(.probe) }

    // Stop the receiver app on the TV (back to its ambient screen), then close.
    func stop() { enqueue(.stopApp) }

    // Close the connection and leave the TV as it is.
    func close() { enqueue(.close) }

    private func run(joining: Bool) {
        lock.lock()
        let first = !started
        started = true
        lock.unlock()
        guard first else { return }
        self.joining = joining
        let t = Thread(target: self, selector: #selector(ioLoop), object: nil)
        t.stackSize = 512 * 1024
        t.start()
    }

    private func enqueue(_ c: Command) {
        lock.lock()
        commands.append(c)
        lock.unlock()
    }

    // MARK: - I/O loop (single thread; owns the socket and all protocol state)

    @objc private func ioLoop() {
        CurlFetcher.ensureGlobalInit()
        guard let h = curl_bridge_init() else { emit(.closed(lost: true)); return }
        handle = h
        defer { curl_bridge_cleanup(h); handle = nil }

        let rc = device.host.withCString { curl_bridge_connect_only(h, $0, device.port) }
        guard rc == 0 else {
            DebugLog.log("Cast", "connect \(device.name) \(device.host) failed rc=\(rc)")
            emit(.closed(lost: true))
            return
        }
        DebugLog.log("Cast", "connected \(device.name) \(device.host) mode=\(joining ? "join" : "start")")
        lastInbound = Date()

        send(CastNS.connection, to: CastSession.platformReceiver, ["type": "CONNECT"])
        requestReceiverStatus()

        var inbound = [UInt8]()
        var recvBuf = [UInt8](repeating: 0, count: 16 * 1024)

        while exitLost == nil {
            runCommands()
            if exitLost != nil { break }
            heartbeatIfDue()
            statusPollIfDue()

            let n = curl_bridge_recv(h, &recvBuf, recvBuf.count, 500)   // 500ms poll window
            if n < 0 {
                DebugLog.log("Cast", "socket closed by \(device.name)")
                exitLost = true
                break
            }
            if n > 0 {
                lastInbound = Date()
                probeDeadline = nil
                inbound.append(contentsOf: recvBuf[0..<Int(n)])
                drainFrames(&inbound)
            }
            if let d = probeDeadline, Date() > d {
                DebugLog.log("Cast", "probe unanswered — connection presumed dead")
                exitLost = true
            } else if Date().timeIntervalSince(lastInbound) > CastSession.silenceLimit {
                DebugLog.log("Cast", "no word from \(device.name) for \(Int(CastSession.silenceLimit))s")
                exitLost = true
            }
        }

        let lost = exitLost ?? true
        if !lost {
            // Best effort: leave the receiver's channel and the platform's politely.
            if let tid = transportId { send(CastNS.connection, to: tid, ["type": "CLOSE"]) }
            send(CastNS.connection, to: CastSession.platformReceiver, ["type": "CLOSE"])
        }
        emit(.closed(lost: lost))
    }

    private func runCommands() {
        lock.lock()
        let batch = commands
        commands.removeAll()
        lock.unlock()
        for c in batch {
            switch c {
            case .load:
                if let tid = transportId { sendLoad(c, transport: tid) } else { pendingLoad = c }
            case .media(let base):
                guard let tid = transportId, let msid = mediaSessionId else { continue }
                var json = base
                json["mediaSessionId"] = msid
                json["requestId"] = nextRequestId()
                send(CastNS.media, to: tid, json)
            case .volume(let level):
                send(CastNS.receiver, to: CastSession.platformReceiver,
                     ["type": "SET_VOLUME", "volume": ["level": level], "requestId": nextRequestId()])
            case .probe:
                probeDeadline = Date().addingTimeInterval(CastSession.probeTimeout)
                requestReceiverStatus()
            case .stopApp:
                if let sid = appSessionId {
                    send(CastNS.receiver, to: CastSession.platformReceiver,
                         ["type": "STOP", "sessionId": sid, "requestId": nextRequestId()])
                }
                exitLost = false
            case .close:
                exitLost = false
            }
            if exitLost != nil { return }
        }
    }

    // Pull every complete UInt32-length-prefixed frame out of the inbound buffer and handle it.
    private func drainFrames(_ inbound: inout [UInt8]) {
        while inbound.count >= 4 {
            let len = (UInt32(inbound[0]) << 24) | (UInt32(inbound[1]) << 16)
                    | (UInt32(inbound[2]) << 8) | UInt32(inbound[3])
            let total = 4 + Int(len)
            if inbound.count < total { break }         // wait for the rest of the frame
            let body = Array(inbound[4..<total])
            inbound.removeFirst(total)
            if let msg = CastMessage.parse(body) { handle(msg) }
        }
    }

    private func heartbeatIfDue() {
        if Date().timeIntervalSince(lastHeartbeat) >= 5 {
            lastHeartbeat = Date()
            send(CastNS.heartbeat, to: CastSession.platformReceiver, ["type": "PING"])
        }
    }

    // Poll the receiver for a fresh MEDIA_STATUS ~once/sec so the scrubber tracks playback
    // (Chromecast only pushes status on state changes, not continuously).
    private func statusPollIfDue() {
        guard let tid = transportId, let msid = mediaSessionId else { return }
        if Date().timeIntervalSince(lastStatusPoll) >= 1 {
            lastStatusPoll = Date()
            send(CastNS.media, to: tid,
                 ["type": "GET_STATUS", "mediaSessionId": msid, "requestId": nextRequestId()])
        }
    }

    // MARK: - Incoming message handling

    private func handle(_ msg: CastMessage) {
        guard let obj = jsonObject(msg.payloadUtf8) else { return }
        let type = (obj["type"] as? String) ?? ""

        switch msg.namespace {
        case CastNS.heartbeat:
            if type == "PING" { send(CastNS.heartbeat, to: msg.sourceId, ["type": "PONG"]) }
        case CastNS.connection:
            // The receiver app closing its channel to us is the app going away.
            if type == "CLOSE", msg.sourceId == transportId { receiverAppGone() }
        case CastNS.receiver:
            if type == "RECEIVER_STATUS" {
                handleReceiverStatus(obj)
            } else if type == "LAUNCH_ERROR" {
                DebugLog.log("Cast", "LAUNCH_ERROR \(msg.payloadUtf8)")
                emit(.loadFailed)
            }
        case CastNS.media:
            switch type {
            case "MEDIA_STATUS":
                handleMediaStatus(obj)
            case "LOAD_FAILED":
                DebugLog.log("Cast", "LOAD_FAILED \(msg.payloadUtf8)")
                emit(.loadFailed)
            case "INVALID_PLAYER_STATE", "INVALID_REQUEST":
                // Usually a command aimed at a media session that just ended. Ask again so the
                // next one goes to whatever is there now.
                DebugLog.log("Cast", "\(type) \(msg.payloadUtf8)")
                if let tid = transportId {
                    send(CastNS.media, to: tid, ["type": "GET_STATUS", "requestId": nextRequestId()])
                }
            default:
                break
            }
        default:
            break
        }
    }

    // Find the media receiver among the running apps: connect to it, then LOAD (start) or
    // read back what it is playing (join). Its absence is also news — the app closed.
    private func handleReceiverStatus(_ obj: [String: Any]) {
        guard let st = obj["status"] as? [String: Any] else { return }
        // NSNumber bridging: `as? Double`/`as? Int` silently fail on the 5.1.5 runtime.
        if let vol = st["volume"] as? [String: Any],
           let level = (vol["level"] as? NSNumber)?.doubleValue, abs(level - lastVolume) > 0.001 {
            lastVolume = level
            emit(.volume(level))
        }
        let apps = (st["applications"] as? [[String: Any]]) ?? []
        guard let app = apps.first(where: { ($0["appId"] as? String) == CastSession.mediaReceiverApp }),
              let tid = app["transportId"] as? String else {
            if transportId != nil {
                receiverAppGone()
            } else if joining {
                DebugLog.log("Cast", "join: media receiver not running")
                emit(.nothingToJoin)
            } else if !launched {
                launched = true
                send(CastNS.receiver, to: CastSession.platformReceiver,
                     ["type": "LAUNCH", "appId": CastSession.mediaReceiverApp, "requestId": nextRequestId()])
            }
            return
        }
        appSessionId = (app["sessionId"] as? String) ?? tid
        if transportId == tid { return }   // already connected to this app
        transportId = tid
        send(CastNS.connection, to: tid, ["type": "CONNECT"])
        if joining {
            awaitingJoin = true
            send(CastNS.media, to: tid, ["type": "GET_STATUS", "requestId": nextRequestId()])
        }
        if let load = pendingLoad {
            pendingLoad = nil
            sendLoad(load, transport: tid)
        }
    }

    private func receiverAppGone() {
        DebugLog.log("Cast", "media receiver closed on \(device.name)")
        transportId = nil
        mediaSessionId = nil
        emit(.appClosed)
        exitLost = false
    }

    private func handleMediaStatus(_ obj: [String: Any]) {
        let arr = (obj["status"] as? [[String: Any]]) ?? []
        guard let first = arr.first,
              let msid = (first["mediaSessionId"] as? NSNumber)?.intValue else {
            // No media session on the receiver at all.
            if awaitingJoin {
                awaitingJoin = false
                DebugLog.log("Cast", "join: receiver has no media")
                emit(.nothingToJoin)
            }
            return
        }
        let state = (first["playerState"] as? String) ?? ""
        let idleReason = (first["idleReason"] as? String) ?? ""
        // A status for another session: the one a LOAD just replaced (or anything IDLE) is not
        // ours any more; anything else is the newer session — ours, or one started elsewhere.
        if msid != mediaSessionId {
            if !awaitingJoin && (msid == replacedSessionId || state == "IDLE") { return }
            mediaSessionId = msid
        }
        if let cur = (first["currentTime"] as? NSNumber)?.doubleValue { status.currentTime = cur }
        if let media = first["media"] as? [String: Any] { readMedia(media) }
        if !state.isEmpty { status.playerState = state }

        if awaitingJoin {
            awaitingJoin = false
            DebugLog.log("Cast", "join: \(state) \(idleReason) id=\(status.videoId) at=\(Int(status.currentTime))s")
            emit(.joined(status))
        }
        if state == "IDLE" {
            // IDLE without a reason is a LOAD still getting going.
            guard !idleReason.isEmpty, idleReason != "INTERRUPTED" else { return }
            DebugLog.log("Cast", "media ended: \(idleReason)")
            mediaSessionId = nil   // nothing left to poll
            emit(.ended(idleReason))
            return
        }
        emit(.media(status))
    }

    // The media object rides only on some statuses (always on the first after a LOAD or a
    // GET_STATUS), so each field is kept until a status brings a new one.
    private func readMedia(_ media: [String: Any]) {
        if let d = (media["duration"] as? NSNumber)?.doubleValue, d > 0 { status.duration = d }
        if let c = media["contentId"] as? String { status.contentId = c }
        if let cd = media["customData"] as? [String: Any], let id = cd["videoId"] as? String {
            status.videoId = id
        }
        if let md = media["metadata"] as? [String: Any] {
            if let t = md["title"] as? String { status.title = t }
            if let s = md["subtitle"] as? String { status.subtitle = s }
        }
    }

    // MARK: - Outbound

    private func sendLoad(_ c: Command, transport: String) {
        guard case let .load(url, contentType, video, startAt) = c else { return }
        // A new media session is coming; the old one's id must not receive its commands.
        if let old = mediaSessionId { replacedSessionId = old }
        mediaSessionId = nil
        status = CastMediaStatus()
        // Title, channel and artwork are what the TV shows; customData is how a later join
        // (or another phone) recognises the video. hqdefault exists for every video.
        let metadata: [String: Any] = [
            "metadataType": 0,
            "title": video.title,
            "subtitle": video.channelName,
            "images": [["url": "https://i.ytimg.com/vi/\(video.id)/hqdefault.jpg"]]
        ]
        let media: [String: Any] = [
            "contentId": url,
            "contentType": contentType,
            "streamType": "BUFFERED",
            "metadata": metadata,
            "customData": ["videoId": video.id]
        ]
        let payload: [String: Any] = [
            "type": "LOAD",
            "requestId": nextRequestId(),
            "autoplay": true,
            "currentTime": startAt,
            "media": media
        ]
        DebugLog.log("Cast", "LOAD id=\(video.id) at=\(Int(startAt))s")
        send(CastNS.media, to: transport, payload)
    }

    private func requestReceiverStatus() {
        send(CastNS.receiver, to: CastSession.platformReceiver,
             ["type": "GET_STATUS", "requestId": nextRequestId()])
    }

    private func nextRequestId() -> Int {
        requestId += 1
        return requestId
    }

    // Write one CastMessage frame. ioLoop thread only. A write that fails means the socket is
    // gone, which ends the loop.
    private func send(_ namespace: String, to destination: String, _ json: [String: Any]) {
        guard let h = handle, exitLost != true else { return }
        let msg = CastMessage(sourceId: CastSession.senderId, destinationId: destination,
                              namespace: namespace, payloadUtf8: jsonString(json))
        let data = msg.framed()
        let sent = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return Int(curl_bridge_send(h, base, data.count))
        }
        if sent < 0 {
            DebugLog.log("Cast", "send failed — connection lost")
            exitLost = true
        }
    }

    private func emit(_ e: Event) {
        AppQueue.main.async { [weak self] in self?.onEvent?(e) }
    }

    // MARK: - JSON helpers

    private func jsonString(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private func jsonObject(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else { return nil }
        return obj
    }
}
