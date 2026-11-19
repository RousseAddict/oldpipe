import Foundation
import Darwin

// MARK: - StreamProxy
//
// Local HTTP -> HTTPS reverse proxy so AVPlayer can STREAM googlevideo.com on iOS 6.
//
// Why this exists: iOS 6's Secure Transport only negotiates CBC cipher suites, but
// googlevideo.com requires AEAD ciphers (GCM / CHACHA20-POLY1305, iOS 7+) and rejects
// the iOS 6 handshake outright. AVPlayer uses Secure Transport internally and cannot be
// pointed at libcurl, so it can never connect to googlevideo directly on iOS 6.
//
// The fix: AVPlayer connects to http://127.0.0.1:<port>/... over PLAIN HTTP (no TLS at
// all, so no cipher problem). This proxy accepts that connection and forwards each request
// — Range header included — to the real googlevideo HTTPS URL through the curl bridge
// (libcurl + OpenSSL), which speaks GCM/CHACHA20 fine. Response bytes are streamed straight
// back to AVPlayer. This is the same pattern as KTVHTTPCache / VIMediaCache, minus caching.
//
// Uses only raw POSIX sockets + the already-vetted curl bridge (no new third-party code).
// iOS 6/7 have no App Transport Security, so http://127.0.0.1 loads without exception.

private final class ProxyConn {
    let clientFd: Int32
    // The route generation this connection was created for. When StreamProxy.currentGen moves
    // past this (a newer video was requested), the progress callback aborts this transfer so a
    // superseded/stuck stream can't hold the feed turnstile past AVPlayer's readiness window.
    let gen: UInt64
    // googlevideo response head, accumulated line-by-line from libcurl's header callback.
    // Reset whenever a new "HTTP/" status line arrives so only the FINAL response (after any
    // redirects curl followed) is forwarded.
    var responseHead = ""
    var headersSent = false
    var aborted = false
    // Set once the feed lane (paused during this stream's handshake) has been reopened, so we
    // never signal the turnstile more than once per connection (which would break its balance).
    var feedResumed = false
    // Body bytes already handed to AVPlayer. A dropped upstream transfer resumes from this
    // offset (see StreamProxy.proxy) so the client never sees a truncated response.
    var bytesRelayed: Int64 = 0
    // How many body bytes the head we forwarded promised (its Content-Length). -1 = unknown,
    // in which case a resume is not attempted: without it there is no way to tell a completed
    // transfer from a truncated one.
    var expectedBody: Int64 = -1
    // Set while a resume leg is in flight. Its head must be a 206 continuation — a fresh
    // 200/403/416 body would be spliced into the middle of the stream and corrupt it.
    var isResumeLeg = false
    var resumeAccepted = false
    init(_ fd: Int32, gen: UInt64) { clientFd = fd; self.gen = gen }
}

// MARK: - C-compatible libcurl callbacks (file scope)

// Header callback: libcurl hands us one response header line at a time (CRLF-terminated),
// including the status line and the trailing blank line. We rebuild the head verbatim,
// dropping hop-by-hop headers that would corrupt our own framing.
private let proxyHeaderCallback: @convention(c) (UnsafeRawPointer?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, userdata in
    let bytes = size * nmemb
    guard let ptr = ptr, let userdata = userdata else { return bytes }
    let conn = Unmanaged<ProxyConn>.fromOpaque(userdata).takeUnretainedValue()
    let line = String(bytes: Data(bytes: ptr, count: bytes), encoding: .isoLatin1) ?? ""
    let lower = line.lowercased()
    if lower.hasPrefix("http/") {
        conn.responseHead = line            // new response block — discard any redirect head
        if conn.isResumeLeg { conn.resumeAccepted = line.contains(" 206") }
        if !conn.headersSent { conn.expectedBody = -1 }
    } else if line == "\r\n" || line == "\n" || line.isEmpty {
        // blank line = end of head; keep buffered lines, don't append the terminator
    } else if lower.hasPrefix("transfer-encoding:") || lower.hasPrefix("connection:") {
        // hop-by-hop — libcurl already de-framed the body; forwarding these would break it
    } else {
        conn.responseHead += line
        if !conn.headersSent, lower.hasPrefix("content-length:") {
            conn.expectedBody = Int64(line.dropFirst(15)
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        }
    }
    return bytes
}

// Body callback: on the first byte, flush the rebuilt response head to AVPlayer, then relay
// body bytes. A blocking send() gives natural backpressure — libcurl only reads more from
// googlevideo as fast as AVPlayer drains, so nothing is buffered to disk or RAM.
private let proxyBodyCallback: @convention(c) (UnsafeRawPointer?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, userdata in
    let bytes = size * nmemb
    guard let ptr = ptr, let userdata = userdata else { return 0 }
    let conn = Unmanaged<ProxyConn>.fromOpaque(userdata).takeUnretainedValue()
    if conn.aborted { return 0 }
    // A resume leg that didn't come back as a 206 isn't a continuation of what we already sent:
    // swallow its body rather than splicing it into the stream (the leg is retried/abandoned by
    // the loop in StreamProxy.proxy, which sees bytesRelayed stand still).
    if conn.isResumeLeg && !conn.resumeAccepted { return bytes }
    if !conn.headersSent {
        // First body byte = handshake done and bytes flowing → reopen the feed lane we paused.
        if !conn.feedResumed { conn.feedResumed = true; CurlFetcher.resumeFeed() }
        let head = (conn.responseHead.isEmpty ? "HTTP/1.1 200 OK\r\n" : conn.responseHead) + "Connection: close\r\n\r\n"
        if !StreamProxy.sendAll(conn.clientFd, Array(head.utf8)) { conn.aborted = true; return 0 }
        conn.headersSent = true
    }
    let ok = StreamProxy.sendAll(conn.clientFd, ptr.assumingMemoryBound(to: UInt8.self), bytes)
    if !ok { conn.aborted = true; return 0 }   // returning < bytes tells libcurl to abort
    conn.bytesRelayed += Int64(bytes)
    return bytes
}

// Progress callback: libcurl invokes this periodically (at least ~once/second) throughout the
// transfer — crucially INCLUDING the connect/TLS-handshake phase. Returning non-zero aborts the
// transfer. We abort as soon as this connection's generation is stale (a newer video has been
// requested), so a stuck handshake on the OLD stream can't keep the feed turnstile closed and
// starve the NEW stream past AVPlayer's readiness window (the download-fallback trigger).
private let proxyProgressCallback: @convention(c) (UnsafeMutableRawPointer?, Int64, Int64, Int64, Int64) -> Int32 = { clientp, _, _, _, _ in
    guard let clientp = clientp else { return 0 }
    let conn = Unmanaged<ProxyConn>.fromOpaque(clientp).takeUnretainedValue()
    if conn.aborted { return 1 }
    if StreamProxy.shared.isSuperseded(conn.gen) { conn.aborted = true; return 1 }
    return 0
}

// MARK: - HLS session (HLS transmux)

// One >360p playback: a video-only + audio-only DASH fMP4 pair served to AVPlayer as a local
// HLS VOD stream (/hls/<id>/index.m3u8 + segN.ts, transmuxed on demand by HLSTransmuxer).
// `info`/`playlistText` are parsed lazily on the FIRST playlist request (one ranged GET of each
// stream's init+sidx head) and cached; parseLock serializes that against AVPlayer's habit of
// opening parallel connections. `gen` follows the same generation-abort rules as mp4 routes.
private final class HLSSession {
    let videoURL: String
    let audioURL: String
    let videoIndexEnd: Int64
    let audioIndexEnd: Int64
    var gen: UInt64
    var info: HLSStreamInfo?
    var playlistText: String?
    let parseLock = NSLock()
    // Non-nil = an OFFLINE bundle (a completed download): index.m3u8 and every seg<i>.ts
    // already exist in this directory, so serving is a plain file read — no head parse, no
    // ranged GET, no mux. The transmuxed bytes were written once, at download time, by
    // OfflineDownloader running this very same pipeline.
    let localDir: String?
    // Names the two encoded files behind the urls (see StreamProxy.headKey), so a later session
    // for the same files can reuse the parsed heads. nil when the urls don't say.
    let headKey: String?
    // The segment after the one AVPlayer last asked for, being fetched before it asks (see
    // StreamProxy.makeSegment). Guarded by StreamProxy.lock.
    var ahead: PrefetchSlot?
    // The segment AVPlayer asked for most recently, -1 before the first. Only that request
    // may start a read-ahead (see startReadAhead). Guarded by StreamProxy.lock.
    var lastAsked = -1
    // Experiment: serve the pair as ONE progressive MP4 (mp4URL) instead of a playlist. Same
    // heads, same segment fetches and read-ahead; only what goes out on the socket differs.
    let progressive: Bool
    // The file's layout, taken from layoutCache on the first request (ensureLayout). Guarded
    // by parseLock.
    var layout: MP4StreamLayout?
    // The file's last few segments as cut, least recently used first. AVPlayer reads a file
    // from more than one spot at once: after a seek it walks the sought segment in small
    // requests while another connection buffers ahead. Keeping one segment made the two evict
    // each other: on the 4S the sought segment was fetched 8 times in 20 s and the seek never
    // finished. Guarded by segLock, which is never held across a fetch.
    var cut: [(seg: Int, bytes: Data)] = []
    // Segments being fetched and cut right now, so another request for one waits for that
    // fetch rather than starting its own. Guarded by segLock.
    var cutting: [Int: CutSlot] = [:]
    let segLock = NSLock()
    // Retired on its own by closeSession, the generation unmoved: its fetches abort and no
    // read-ahead starts. Guarded by StreamProxy.lock.
    var closed = false
    init(videoURL: String, audioURL: String, videoIndexEnd: Int64, audioIndexEnd: Int64,
         gen: UInt64, localDir: String? = nil, headKey: String? = nil, progressive: Bool = false) {
        self.videoURL = videoURL
        self.audioURL = audioURL
        self.videoIndexEnd = videoIndexEnd
        self.audioIndexEnd = audioIndexEnd
        self.gen = gen
        self.localDir = localDir
        self.headKey = headKey
        self.progressive = progressive
    }
}

// One segment of a progressive file on its way, for the requests that want it meanwhile
// (see StreamProxy.mp4Segment). `bytes` is set and `waiters` read under the session's segLock,
// before one signal per waiter.
private final class CutSlot {
    let sem = AppSemaphore(value: 0)
    var bytes: Data?
    var waiters = 0
}

// The parsed heads of one stream pair, kept after its session for the next one (see
// StreamProxy.ensureParsed).
private struct CachedHeads {
    let key: String
    let info: HLSStreamInfo
    let playlist: String
}

// MARK: - StreamProxy

final class StreamProxy: NSObject {

    static let shared = StreamProxy()

    private var listenFd: Int32 = -1
    private var port: UInt16 = 0
    private var started = false
    // Bumped by every start(), so an accept loop that ends can tell whether the listener it
    // served is still the current one — fd numbers are handed out again as soon as one closes.
    private var listenerGen: UInt64 = 0

    // Maps the opaque local path token -> (real googlevideo URL, generation). Avoids encoding
    // the URL into the path (addingPercentEncoding / base64 options are iOS 7+). NSLock-guarded
    // because localURL(for:) is called on the main thread while connection threads read it.
    private var routes: [String: (url: String, gen: UInt64)] = [:]
    // HLS transmux sessions, keyed by the <id> in /hls/<id>/... paths. Same lock as routes.
    private var hlsSessions: [String: HLSSession] = [:]
    private var routeSeq: UInt64 = 0
    // Monotonic generation, bumped each time a new stream is requested. In-flight connections
    // from an older generation are aborted by proxyProgressCallback (see isSuperseded).
    private var currentGen: UInt64 = 0
    private let lock = NSLock()

    // Fetches live HLS segments ahead of AVPlayer (see makeSegment). Serial and static like every
    // queue in the app: one thread for the life of the process, and only one read-ahead is ever
    // outstanding, since every change of stream drops the old ones (dropReadAheadLocked).
    private static let readAheadQueue = AppQueue(label: "com.oldpipe.proxy.readahead")

    // Parsed heads of the last few stream pairs played, newest last. Same lock as routes.
    private var headCache: [CachedHeads] = []
    private static let headCacheSize = 4
    // Layouts of the last progressive files prepareMP4 built, by the same key: what decides that
    // the MP4 route can take over (mp4Readiness), and what reopening the video or a recovery
    // reload finds again. Same lock as routes. Two, since a long video's moov runs to megabytes.
    private var layoutCache: [(key: String, layout: MP4StreamLayout)] = []
    private static let layoutCacheSize = 2
    // Segments a progressive file keeps cut (HLSSession.cut): room for the sought one, a
    // neighbour it reaches into, and the one being buffered past them. ~1-1.5 MB each at 1080p.
    private static let mp4SegmentsKept = 3
    // Numbers the progressive requests in the debug log. Same lock as routes.
    private var mp4RequestSeq = 0

    // Return a local http:// URL that proxies to `remote`. Starts the listener on first use.
    // nil only if the socket could not be opened.
    func localURL(for remote: String) -> URL? {
        guard start() else {
            DebugLog.log("StreamProxy", "localURL FAILED — listener could not start")
            return nil
        }
        lock.lock()
        routeSeq += 1
        currentGen += 1
        dropReadAheadLocked()
        let gen = currentGen
        let token = "\(routeSeq).mp4"
        routes[token] = (remote, gen)
        lock.unlock()
        DebugLog.log("StreamProxy", "localURL token=\(token) gen=\(gen) port=\(port)")
        return URL(string: "http://127.0.0.1:\(port)/\(token)")
    }

    // Register a >360p HLS transmux session for a DASH video+audio fMP4 pair and return the
    // local playlist URL for AVPlayer. indexEnd values come from the innertube indexRange —
    // bytes 0...indexEnd is each stream's init+sidx head. Bumps the generation exactly like
    // localURL(for:) so any previously playing stream is aborted at the switch moment.
    func hlsURL(videoURL: String, audioURL: String, videoIndexEnd: Int64, audioIndexEnd: Int64) -> URL? {
        guard videoIndexEnd > 0, audioIndexEnd > 0, start() else { return nil }
        var key: String?
        if let v = StreamProxy.headKey(videoURL, indexEnd: videoIndexEnd),
           let a = StreamProxy.headKey(audioURL, indexEnd: audioIndexEnd) { key = v + "+" + a }
        lock.lock()
        routeSeq += 1
        currentGen += 1
        dropReadAheadLocked()
        let id = "\(routeSeq)"
        hlsSessions[id] = HLSSession(videoURL: videoURL, audioURL: audioURL,
                                     videoIndexEnd: videoIndexEnd, audioIndexEnd: audioIndexEnd,
                                     gen: currentGen, headKey: key)
        lock.unlock()
        return URL(string: "http://127.0.0.1:\(port)/hls/\(id)/index.m3u8")
    }

    // Experiment: the same pair as hlsURL, served as ONE progressive MP4 (see MP4StreamLayout),
    // which iOS 5/6 will play at other speeds than 1.0. Only once mp4Readiness says .ready: the
    // file's layout has to exist before AVPlayer's first request. Generation rules as hlsURL,
    // unless `supersede` is false: a handover (VideoPlayer.handOver) loads the file while the
    // HLS stream plays on, so nothing of that one may be aborted. Whichever of the two loses is
    // retired by closeSession instead.
    func mp4URL(videoURL: String, audioURL: String, videoIndexEnd: Int64, audioIndexEnd: Int64,
                supersede: Bool = true) -> URL? {
        guard videoIndexEnd > 0, audioIndexEnd > 0, start() else { return nil }
        let key = StreamProxy.pairKey(videoURL, videoIndexEnd, audioURL, audioIndexEnd)
        lock.lock()
        routeSeq += 1
        if supersede {
            currentGen += 1
            dropReadAheadLocked()
        }
        // Only the newest progressive session is read again. An older one would hold its layout
        // and last segment for the life of the process; a connection still serving it keeps its
        // own reference until it ends.
        hlsSessions = hlsSessions.filter { !$0.value.progressive }
        let id = "\(routeSeq)"
        hlsSessions[id] = HLSSession(videoURL: videoURL, audioURL: audioURL,
                                     videoIndexEnd: videoIndexEnd, audioIndexEnd: audioIndexEnd,
                                     gen: currentGen, headKey: key, progressive: true)
        let gen = currentGen
        lock.unlock()
        DebugLog.log("StreamProxy", "mp4URL id=\(id) gen=\(gen)" + (supersede ? "" : " (alongside the playing stream)"))
        return URL(string: "http://127.0.0.1:\(port)/mp4/\(id)/video.mp4")
    }

    // Experiment: retire ONE session, the generation unmoved — moving it would abort the
    // stream that plays on. The HLS stream a handover replaced, or the file of a handover that
    // was given up. Its read-ahead goes, none starts again, and its fetches in flight abort.
    func closeSession(_ url: URL) {
        let comps = url.path.components(separatedBy: "/")   // "", "hls" or "mp4", id, file
        guard comps.count == 4 else { return }
        lock.lock()
        let s = hlsSessions.removeValue(forKey: comps[2])
        s?.closed = true
        s?.ahead?.abandon()
        s?.ahead = nil
        lock.unlock()
        s?.segLock.lock()
        s?.cut = []
        s?.segLock.unlock()
        DebugLog.log("StreamProxy", "closeSession \(comps[1])/\(comps[2])" + (s == nil ? " (gone already)" : ""))
    }

    // isSuperseded, or this one session was retired by itself (closeSession).
    private func isStale(_ session: HLSSession, _ gen: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen < currentGen || session.closed
    }

    // Serve a DOWNLOADED HLS bundle (downloads/<id>/) back to AVPlayer. Offline playback still
    // goes through the proxy rather than a file:// URL because AVPlayer on iOS 6/7 will not open
    // a playlist off the filesystem — the segments are local, the transport is not.
    // Bumps the generation like the other two so switching to a download aborts a live stream.
    func offlineHLSURL(dir: String) -> URL? {
        guard FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("index.m3u8")),
              start() else {
            DebugLog.log("StreamProxy", "offlineHLSURL FAILED dir=\(dir)")
            return nil
        }
        lock.lock()
        routeSeq += 1
        currentGen += 1
        dropReadAheadLocked()
        let id = "\(routeSeq)"
        hlsSessions[id] = HLSSession(videoURL: "", audioURL: "", videoIndexEnd: 0, audioIndexEnd: 0,
                                     gen: currentGen, localDir: dir)
        lock.unlock()
        DebugLog.log("StreamProxy", "offlineHLSURL id=\(id) dir=\(dir)")
        return URL(string: "http://127.0.0.1:\(port)/hls/\(id)/index.m3u8")
    }

    // True once a newer stream has been requested than the given generation. Read from the
    // libcurl progress callback (off the main thread) to abort a superseded transfer.
    func isSuperseded(_ gen: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen < currentGen
    }

    // Abort any in-flight proxy transfer — called when the current video ENDS or the player is
    // torn down, so a finished/idle stream can't keep a worker thread (or the feed turnstile)
    // parked in a blocking send()/handshake. Bumping currentGen supersedes every live ProxyConn
    // (the progress callback then aborts them), while re-blessing the existing routes to the new
    // generation keeps a legitimate reconnect valid — e.g. scrubbing back after the video ended
    // re-opens the SAME token and must NOT be treated as superseded.
    func closeCurrentStream() {
        lock.lock()
        currentGen += 1
        let bumped = currentGen
        for k in routes.keys { routes[k]?.gen = bumped }
        for s in hlsSessions.values { s.gen = bumped }
        dropReadAheadLocked()
        lock.unlock()
        DebugLog.log("StreamProxy", "closeCurrentStream gen=\(bumped)")
    }

    // Throw every live read-ahead away. Called, under `lock`, wherever the generation moves:
    // an in-flight one is about to abort as superseded anyway, and a finished one that nobody
    // will ask for would otherwise hold a segment's bytes (1.4MB at 720p) for as long as its
    // session lives, which is the life of the process.
    private func dropReadAheadLocked() {
        for s in hlsSessions.values where s.ahead != nil {
            s.ahead?.abandon()
            s.ahead = nil
        }
    }

    // What identifies the encoded FILE behind a googlevideo url: its itag, byte length and
    // last-modified stamp, plus the head length we fetch. Every resolve signs a fresh url for
    // the same bytes, so the url itself can't be the key. nil if any field is missing, which
    // just means no reuse.
    private static func headKey(_ url: String, indexEnd: Int64) -> String? {
        guard let q = url.firstIndex(of: "?") else { return nil }
        var fields: [String: String] = [:]
        for pair in String(url[url.index(after: q)...]).components(separatedBy: "&") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            fields[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
        }
        guard let itag = fields["itag"], let clen = fields["clen"], let lmt = fields["lmt"] else { return nil }
        return "\(itag)/\(clen)/\(lmt)/\(indexEnd)"
    }

    // Called by AppDelegate each time the app becomes active. iOS reclaims loopback listening
    // sockets while an app is SUSPENDED in the background; on resume the old socket/port is dead,
    // so localURL would hand AVPlayer a URL to a closed port → no bytes → the stream stalls past
    // AVPlayer's readiness window → download fallback. But an app that kept playing in the
    // background was never suspended, and becoming active also follows a Notification Center
    // pull or a declined call: tearing the listener down unconditionally, as this used to, sent
    // the playing video's next segment (every HLS segment is a new connection) to a closed port.
    // So it is only rebuilt when it no longer answers: the probe sends a request (handled as an
    // unknown path → 404), which a socket left with no accept loop cannot answer even though it
    // still completes the connect. Loopback replies in a few ms; 500 ms per step only bounds a
    // dead one. With no socket to probe from (-1) there is no verdict, and the listener stays.
    func resetIfDead() {
        lock.lock()
        let live = started, p = port
        lock.unlock()
        guard live, curl_bridge_loopback_answers(p, 500) == 0 else { return }
        DebugLog.log("StreamProxy", "listener on port \(p) does not answer — rebinding on next use")
        reset()
    }

    // Tear down the listen socket so the NEXT localURL(for:) opens a fresh one. Closing
    // listenFd unblocks acceptLoop's accept() so that thread exits cleanly; flipping `started`
    // back to false makes start() rebind on next use. No-op if the listener was never started.
    func reset() {
        lock.lock()
        guard started else { lock.unlock(); return }
        started = false
        let fd = listenFd
        listenFd = -1
        lock.unlock()
        DebugLog.log("StreamProxy", "reset — closing listen socket, will rebind on next use")
        if fd >= 0 { close(fd) }
    }

    // MARK: - Listener

    @discardableResult
    private func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if started { return true }

        CurlFetcher.ensureGlobalInit()
        signal(SIGPIPE, SIG_IGN)   // belt-and-suspenders; per-socket SO_NOSIGPIPE is also set

        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")   // loopback only — never exposed off-device
        addr.sin_port = 0                                 // ephemeral port assigned by the kernel

        let bindOk = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOk == 0, listen(fd, 8) == 0 else { close(fd); return false }

        // Read back the port the kernel chose.
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameOk = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard nameOk == 0 else { close(fd); return false }
        port = UInt16(bigEndian: bound.sin_port)

        listenFd = fd
        started = true
        listenerGen += 1
        // Raw Thread (not GCD): the accept loop blocks forever, and per-connection threads
        // block in a synchronous curl_easy_perform for the whole stream — parking those on a
        // GCD concurrent queue would exhaust its width. NSThread each owns a real OS thread.
        let args: NSArray = [NSNumber(value: fd), NSNumber(value: listenerGen)]
        let t = Thread(target: self, selector: #selector(acceptLoop(_:)), object: args)
        t.stackSize = 512 * 1024
        t.start()
        return true
    }

    @objc private func acceptLoop(_ obj: Any) {
        guard let args = obj as? NSArray, args.count == 2,
              let fdNum = args[0] as? NSNumber, let genNum = args[1] as? NSNumber else { return }
        let fd = fdNum.int32Value, gen = genNum.uint64Value
        var acceptErr: Int32 = 0
        var transientErrors = 0
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                let e = errno
                if e == EINTR { continue }
                // A client that reset while it waited in the backlog, or a passing shortage of
                // descriptors or buffers (every connection costs a thread and curl's sockets):
                // the listener itself is fine, so try again shortly. Only so many times in a
                // row, though — a socket reclaimed during a suspension can keep failing the
                // same way, and this loop must end for it to be replaced.
                if [ECONNABORTED, EMFILE, ENFILE, ENOBUFS, ENOMEM].contains(e), transientErrors < 20 {
                    transientErrors += 1
                    usleep(50_000)
                    continue
                }
                acceptErr = e
                break
            }
            transientErrors = 0
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            let t = Thread(target: self, selector: #selector(handleConnection(_:)), object: NSNumber(value: client))
            t.stackSize = 512 * 1024
            t.start()
        }
        // Nobody accepts on this socket any more. If it is still the current listener (it was
        // not closed by reset() but failed — e.g. reclaimed while the app was suspended), drop
        // it so the next stream binds a fresh one at once, rather than handing out a port whose
        // connections are never answered until resetIfDead next runs.
        lock.lock()
        let current = started && listenerGen == gen
        if current { started = false; listenFd = -1 }
        lock.unlock()
        if current {
            close(fd)
            DebugLog.log("StreamProxy", "accept loop ended (errno \(acceptErr)) — rebinding on next use")
        }
    }

    // MARK: - Per-connection handling

    @objc private func handleConnection(_ obj: Any) {
        guard let num = obj as? NSNumber else { return }
        let clientFd = num.int32Value
        defer { close(clientFd) }

        guard let request = readRequestHead(clientFd) else { return }
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }

        // "GET /<token> HTTP/1.1"
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { StreamProxy.sendAll(clientFd, Array("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n".utf8)); return }
        var token = parts[1]
        if token.hasPrefix("/") { token.removeFirst() }
        if let q = token.firstIndex(of: "?") { token = String(token[..<q]) }

        // HLS transmux: "hls/<id>/index.m3u8" or "hls/<id>/segN.ts"
        if token.hasPrefix("hls/") {
            let comps = token.components(separatedBy: "/")
            lock.lock()
            let session = comps.count == 3 ? hlsSessions[comps[1]] : nil
            lock.unlock()
            guard let session = session else {
                StreamProxy.sendAll(clientFd, Array("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n".utf8))
                return
            }
            serveHLS(session, file: comps[2], clientFd: clientFd)
            return
        }

        // Progressive MP4 of a DASH pair: "mp4/<id>/video.mp4", read by byte range.
        if token.hasPrefix("mp4/") {
            let comps = token.components(separatedBy: "/")
            lock.lock()
            let session = comps.count == 3 ? hlsSessions[comps[1]] : nil
            lock.unlock()
            guard let session = session, session.progressive else {
                StreamProxy.sendAll(clientFd, Array("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n".utf8))
                return
            }
            var rangeHeader: String?
            for line in lines.dropFirst() where line.lowercased().hasPrefix("range:") {
                rangeHeader = line
            }
            serveMP4(session, rangeHeader: rangeHeader, headOnly: parts[0] == "HEAD", clientFd: clientFd)
            return
        }

        lock.lock(); let route = routes[token]; lock.unlock()
        guard let route = route else {
            StreamProxy.sendAll(clientFd, Array("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n".utf8))
            return
        }

        // Forward the client's Range header verbatim so AVPlayer's byte-range requests work.
        var rangeHeader: String?
        for line in lines.dropFirst() where line.lowercased().hasPrefix("range:") {
            rangeHeader = line
        }

        proxy(remoteURL: route.url, gen: route.gen, rangeHeader: rangeHeader, clientFd: clientFd)
    }

    // MARK: - HLS transmux serving

    // Serve one HLS request for a session: the VOD playlist (parsing the stream heads lazily on
    // first hit) or one transmuxed TS segment (two bounded ranged GETs + mux, ~1.4MB for 720p).
    // Runs on the per-connection thread — blocking here is fine, AVPlayer just waits.
    private func serveHLS(_ session: HLSSession, file: String, clientFd: Int32) {
        // Offline bundle — every byte is already on disk, nothing to fetch or mux.
        if let dir = session.localDir {
            serveOfflineHLS(dir: dir, file: file, clientFd: clientFd)
            return
        }

        lock.lock(); let gen = session.gen; lock.unlock()

        guard let info = ensureParsed(session, gen: gen) else {
            StreamProxy.sendAll(clientFd, Array("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8))
            return
        }

        if file == "index.m3u8" {
            session.parseLock.lock(); let text = session.playlistText ?? ""; session.parseLock.unlock()
            sendResponse(clientFd, contentType: "application/vnd.apple.mpegurl", body: Data(text.utf8))
            return
        }

        guard file.hasPrefix("seg"), file.hasSuffix(".ts"),
              let seg = Int(String(file.dropFirst(3).dropLast(3))),
              seg >= 0, seg < info.segmentCount else {
            StreamProxy.sendAll(clientFd, Array("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        guard let ts = makeSegment(session, info: info, seg: seg, gen: gen) else {
            StreamProxy.sendAll(clientFd, Array("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        sendResponse(clientFd, contentType: "video/MP2T", body: ts)
    }

    // One TS segment: its two DASH fragments, transmuxed. AVPlayer asks for segments one at a
    // time, and each used to wait out two ranged GETs and the mux, so above 360p on a slow link
    // the network sat idle in every gap between segments. Now the NEXT segment starts fetching
    // as soon as this one's bytes are in hand, during the mux, the send and whatever AVPlayer
    // does before asking again, and is usually there already when it does.
    //
    // One segment ahead, no more, and never two fetches at once (as in OfflineDownloader's
    // PrefetchSlot): a second parallel transfer would split the same link and could cost a fresh
    // TLS handshake, 1-3 s on an iPhone 4S. A request for any other segment (a seek) drops the
    // read-ahead without waiting for it.
    private func makeSegment(_ session: HLSSession, info: HLSStreamInfo, seg: Int, gen: UInt64) -> Data? {
        guard let got = fetchSegment(session, info: info, seg: seg, gen: gen, label: "hls") else { return nil }
        let mux0 = Date()
        let ts = HLSTransmuxer.muxSegment(info, seg: seg, videoBlob: got.v, audioBlob: got.a)
        let muxMs = Int(Date().timeIntervalSince(mux0) * 1000)
        // wait = how long AVPlayer waited for the bytes, ~0 when the read-ahead was in time.
        DebugLog.log("StreamProxy", "hls seg \(seg)/\(info.segmentCount) \(got.wasAhead ? "ahead" : "inline") "
            + "wait=\(got.waitMs)ms \(got.timings) mux=\(muxMs)ms \((ts?.count ?? 0) / 1024)KB")
        return ts
    }

    // Segment `seg`'s two fetches, taken from the read-ahead when it has them, and the read-ahead
    // of the next one started. Shared by the HLS and progressive routes; `label` names the route
    // in the log. `timings` reads "(v <ms>, a <ms>)", with any fresh TLS handshake called out.
    private func fetchSegment(_ session: HLSSession, info: HLSStreamInfo, seg: Int, gen: UInt64,
                              label: String) -> (v: Data, a: Data, wasAhead: Bool, waitMs: Int, timings: String)? {
        guard let vr = HLSTransmuxer.videoRange(info, seg: seg),
              let ar = HLSTransmuxer.audioRange(info, seg: seg) else { return nil }
        let wait0 = Date()
        lock.lock()
        let ahead = session.ahead
        session.ahead = nil
        session.lastAsked = seg
        lock.unlock()

        var slot: PrefetchSlot?
        if let a = ahead {
            if a.seg == seg {
                slot = a
            } else {
                a.abandon()
                DebugLog.log("StreamProxy", "\(label) seg \(seg) asked, read-ahead had seg \(a.seg) — dropped")
            }
        }
        var got: (v: Data?, a: Data?) = (nil, nil)
        if let s = slot { got = s.waitResult() }
        // Nothing read ahead, or the read-ahead failed (aborted when the stream was closed, then
        // asked for again by a scrub back): fetch it here, on AVPlayer's time.
        let wasAhead = got.v != nil && got.a != nil
        if !wasAhead && !isStale(session, gen) {
            let s = PrefetchSlot(seg: seg)
            s.fill(vURL: session.videoURL, vr: vr, aURL: session.audioURL, ar: ar,
                   abort: { StreamProxy.shared.isStale(session, gen) })
            got = s.waitResult()
            slot = s
        }
        let waitMs = Int(Date().timeIntervalSince(wait0) * 1000)
        guard let v = got.v, let a = got.a, let done = slot else {
            DebugLog.log("StreamProxy", "\(label) seg \(seg)/\(info.segmentCount) FETCH FAILED after \(waitMs)ms"
                + (isStale(session, gen) ? " (superseded)" : ""))
            return nil
        }

        startReadAhead(session, info: info, after: seg, gen: gen)

        let vt = done.vTiming, at = done.aTiming
        let timings = "(v \(vt.ms)ms\(vt.reusedConnection ? "" : " FRESH tls \(vt.tlsMs)ms"), "
            + "a \(at.ms)ms\(at.reusedConnection ? "" : " FRESH tls \(at.tlsMs)ms"))"
        return (v, a, wasAhead, waitMs, timings)
    }

    // MARK: - Progressive MP4 serving (experiment)

    // Answer one byte-range request on a progressive session's file. The layout was built in the
    // background (prepareMP4) before the player was pointed here; the head is served from
    // memory, everything after it segment by segment, each the HLS route's two fetches cut into
    // the layout's order. Blocking sends pace the fetching to AVPlayer, which closes the socket
    // when it has read enough or seeks.
    private func serveMP4(_ session: HLSSession, rangeHeader: String?, headOnly: Bool, clientFd: Int32) {
        lock.lock(); let gen = session.gen; mp4RequestSeq += 1; let req = mp4RequestSeq; lock.unlock()
        guard let info = ensureParsed(session, gen: gen),
              let layout = ensureLayout(session) else {
            StreamProxy.sendAll(clientFd, Array("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        let total = layout.totalSize
        guard let asked = StreamProxy.parseByteRange(rangeHeader), asked.start < total else {
            StreamProxy.sendAll(clientFd, Array(("HTTP/1.1 416 Range Not Satisfiable\r\n"
                + "Content-Range: bytes */\(total)\r\nConnection: close\r\n\r\n").utf8))
            return
        }
        let end = min(asked.end ?? total - 1, total - 1)
        let headLen = Int64(layout.head.count)
        // A line as each request starts and one as it ends: which bytes AVPlayer reads, from how
        // many places at once, and how much of each before it lets go.
        DebugLog.log("StreamProxy", "mp4 req #\(req) \(headOnly ? "HEAD " : "")bytes \(asked.start)-"
            + (asked.end.map { "\($0)" } ?? "") + " from "
            + (asked.start < headLen ? "head" : "seg \(layout.segment(at: asked.start) ?? -1)"))
        let t0 = Date()
        var pos = asked.start
        var fromMemory = 0
        var stop = "done"
        defer {
            DebugLog.log("StreamProxy", "mp4 req #\(req) \(stop): \((pos - asked.start) / 1024)KB of "
                + "\((end - asked.start + 1) / 1024)KB in \(Int(Date().timeIntervalSince(t0) * 1000))ms"
                + (fromMemory > 0 ? ", \(fromMemory) seg(s) from memory" : ""))
        }
        var head = rangeHeader == nil ? "HTTP/1.1 200 OK\r\n" : "HTTP/1.1 206 Partial Content\r\n"
        head += "Content-Type: video/mp4\r\nAccept-Ranges: bytes\r\n"
        if rangeHeader != nil { head += "Content-Range: bytes \(asked.start)-\(end)/\(total)\r\n" }
        head += "Content-Length: \(end - asked.start + 1)\r\nConnection: close\r\n\r\n"
        guard StreamProxy.sendAll(clientFd, Array(head.utf8)) else { stop = "client gone"; return }
        if headOnly { return }

        if pos < headLen {
            let upto = min(headLen, end + 1)
            guard StreamProxy.sendSlice(clientFd, layout.head, from: Int(pos), to: Int(upto)) else { stop = "client closed"; return }
            pos = upto
        }
        while pos <= end {
            guard let seg = layout.segment(at: pos),
                  let got = mp4Segment(session, info: info, layout: layout, seg: seg, gen: gen) else { stop = "fetch failed"; return }
            if !got.fetched { fromMemory += 1 }
            let r = layout.range(of: seg)
            let upto = min(r.end, end) + 1
            guard StreamProxy.sendSlice(clientFd, got.bytes, from: Int(pos - r.start), to: Int(upto - r.start)) else { stop = "client closed"; return }
            pos = upto
        }
    }

    // One segment of the file: fetched like an HLS segment, then cut instead of muxed. The last
    // few cut are kept (HLSSession.cut), and one already on its way for another request is
    // waited for rather than fetched twice; different segments fetch side by side. `fetched` is
    // false when this request did not have to wait on the network for it.
    private func mp4Segment(_ session: HLSSession, info: HLSStreamInfo, layout: MP4StreamLayout,
                            seg: Int, gen: UInt64) -> (bytes: Data, fetched: Bool)? {
        session.segLock.lock()
        if let i = session.cut.firstIndex(where: { $0.seg == seg }) {
            let hit = session.cut.remove(at: i)
            session.cut.append(hit)
            session.segLock.unlock()
            return (hit.bytes, false)
        }
        if let slot = session.cutting[seg] {
            slot.waiters += 1
            session.segLock.unlock()
            slot.sem.wait()
            return slot.bytes.map { ($0, false) }
        }
        let slot = CutSlot()
        session.cutting[seg] = slot
        session.segLock.unlock()

        var bytes: Data?
        if let vr = HLSTransmuxer.videoRange(info, seg: seg),
           let ar = HLSTransmuxer.audioRange(info, seg: seg),
           let got = fetchSegment(session, info: info, seg: seg, gen: gen, label: "mp4") {
            bytes = layout.bytes(of: seg, video: got.v, videoStart: vr.start, audio: got.a, audioStart: ar.start)
            DebugLog.log("StreamProxy", "mp4 seg \(seg)/\(info.segmentCount) \(got.wasAhead ? "ahead" : "inline") "
                + "wait=\(got.waitMs)ms \(got.timings) \((bytes?.count ?? 0) / 1024)KB"
                + (bytes == nil ? " CUT FAILED" : ""))
        }

        session.segLock.lock()
        session.cutting[seg] = nil
        if let b = bytes {
            session.cut.append((seg: seg, bytes: b))
            if session.cut.count > StreamProxy.mp4SegmentsKept { session.cut.removeFirst() }
        }
        slot.bytes = bytes
        let waiters = slot.waiters
        session.segLock.unlock()
        for _ in 0..<waiters { slot.sem.signal() }
        return bytes.map { ($0, true) }
    }

    // The file's layout, which must already exist: built in the background by prepareMP4, the
    // only way to get one. Nothing is read here — AVPlayer allows its first request ~10 s and
    // blocks the main thread meanwhile, and reading a cold hour of moofs takes a minute. The
    // first device try built it right here and AVPlayer gave up 128 moofs in.
    private func ensureLayout(_ session: HLSSession) -> MP4StreamLayout? {
        session.parseLock.lock()
        defer { session.parseLock.unlock() }
        if let layout = session.layout { return layout }
        guard let key = session.headKey else { return nil }
        lock.lock()
        let hit = layoutCache.first(where: { $0.key == key })?.layout
        lock.unlock()
        session.layout = hit
        DebugLog.log("StreamProxy", hit.map { "mp4 layout ready (\($0.totalSize / 1_048_576)MB)" }
                                        ?? "mp4 layout NOT READY — refusing the request")
        return hit
    }

    // MARK: - Reading the moofs in the background (experiment)

    // One pair's moofs, read while it plays as HLS, so the MP4 route can take over at once when a
    // speed is picked (mp4Readiness). A cold googlevideo range costs 75-140 ms (measured
    // 2026-11-19: the edge pulls it from deeper storage first; read again it costs 1-4 ms), so a
    // 1-hour video takes about a minute even read three requests at a time.
    //
    // Resumable: whatever was read survives an interruption (a stream change aborts the reads,
    // like any other transfer of the old generation), and the next prepareMP4 for the same pair
    // reads only what is missing.
    private final class MP4Prep {
        let key: String
        let videoURL: String, audioURL: String
        let videoIndexEnd: Int64, audioIndexEnd: Int64
        var gen: UInt64
        var info: HLSStreamInfo?
        var video: [[DASHSample]?] = []
        var audio: [[DASHSample]?] = []
        // Batches not read yet: which fragments of which track, and how much of each.
        var pending: [(video: Bool, items: [(frag: Int, count: Int)])] = []
        var workers = 0
        var failed: String?
        var requests = 0, bytes = 0
        var started = Date()
        init(key: String, videoURL: String, audioURL: String, videoIndexEnd: Int64, audioIndexEnd: Int64, gen: UInt64) {
            self.key = key
            self.videoURL = videoURL
            self.audioURL = audioURL
            self.videoIndexEnd = videoIndexEnd
            self.audioIndexEnd = audioIndexEnd
            self.gen = gen
        }
        var total: Int { return video.count + audio.count }
        var done: Int { return video.filter { $0 != nil }.count + audio.filter { $0 != nil }.count }
    }
    private var prep: MP4Prep?   // the latest pair asked for; guarded by lock

    // Three requests in flight: a cold read waits on Google's storage, not on the link, so
    // parallel ones overlap their waits (3 connections ~1.9x faster than 1, measured).
    private static let prepQueues = [AppQueue(label: "com.oldpipe.proxy.mp4prep.0"),
                                     AppQueue(label: "com.oldpipe.proxy.mp4prep.1"),
                                     AppQueue(label: "com.oldpipe.proxy.mp4prep.2")]
    // googlevideo answers up to 48 ranges in one request and refuses 64 (2026-11-19). Cold,
    // 32 per request cost about half what 8 did per moof.
    private static let rangesPerRequest = 32
    // What is first read of each fragment. A 1080p30 moof measured 0.5-2.6 KB and an audio one
    // up to 1.8 KB; a longer one is read again whole.
    private static let moofProbeBytes = 4096

    enum MP4Readiness {
        case ready
        case preparing(Int)   // percent of the moofs read
        case unavailable      // the urls name no file to key a layout by, or it cannot be built

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    func mp4Readiness(videoURL: String, audioURL: String, videoIndexEnd: Int64, audioIndexEnd: Int64) -> MP4Readiness {
        guard let key = StreamProxy.pairKey(videoURL, videoIndexEnd, audioURL, audioIndexEnd) else { return .unavailable }
        lock.lock()
        defer { lock.unlock() }
        if layoutCache.contains(where: { $0.key == key }) { return .ready }
        guard let p = prep, p.key == key else { return .preparing(0) }
        if p.failed != nil { return .unavailable }
        return .preparing(p.total > 0 ? p.done * 100 / p.total : 0)
    }

    // Start (or resume) reading this pair's moofs in the background. Call once its HLS stream
    // plays, so its heads are in headCache already; again whenever mp4Readiness is not ready
    // and nothing may be reading (a stream change stopped it). A no-op when ready or running.
    func prepareMP4(videoURL: String, audioURL: String, videoIndexEnd: Int64, audioIndexEnd: Int64) {
        guard let key = StreamProxy.pairKey(videoURL, videoIndexEnd, audioURL, audioIndexEnd) else { return }
        lock.lock()
        if layoutCache.contains(where: { $0.key == key }) { lock.unlock(); return }
        let p: MP4Prep
        if let cur = prep, cur.key == key, cur.failed == nil {
            p = cur
        } else {
            p = MP4Prep(key: key, videoURL: videoURL, audioURL: audioURL,
                        videoIndexEnd: videoIndexEnd, audioIndexEnd: audioIndexEnd, gen: currentGen)
            prep = p
        }
        p.gen = currentGen
        guard p.workers == 0 else { lock.unlock(); return }
        p.workers = StreamProxy.prepQueues.count
        p.started = Date()
        lock.unlock()
        DebugLog.log("StreamProxy", "mp4 prep \(p.total == 0 ? "start" : "resume at \(p.done)/\(p.total)")")
        StreamProxy.prepQueues[0].async { StreamProxy.shared.prepFirst(p) }
    }

    // On the first queue: the heads (from headCache when the HLS stream already read them) and
    // the batch list, then the other readers are let go.
    private func prepFirst(_ p: MP4Prep) {
        if p.info == nil {
            lock.lock(); let gen = p.gen; lock.unlock()
            let s = HLSSession(videoURL: p.videoURL, audioURL: p.audioURL, videoIndexEnd: p.videoIndexEnd,
                               audioIndexEnd: p.audioIndexEnd, gen: gen, headKey: p.key)
            guard let info = ensureParsed(s, gen: gen) else {
                lock.lock(); p.workers = 0; lock.unlock()
                DebugLog.log("StreamProxy", "mp4 prep stopped: heads unavailable" + (isSuperseded(gen) ? " (superseded)" : ""))
                return
            }
            var batches: [(video: Bool, items: [(frag: Int, count: Int)])] = []
            for video in [true, false] {
                let frags = HLSTransmuxer.fragments(info, video: video)
                var k = 0
                while k < frags.count {
                    let upto = min(k + StreamProxy.rangesPerRequest, frags.count)
                    batches.append((video, (k..<upto).map { (frag: $0, count: min(StreamProxy.moofProbeBytes, frags[$0].size)) }))
                    k = upto
                }
            }
            lock.lock()
            p.info = info
            p.video = [[DASHSample]?](repeating: nil, count: HLSTransmuxer.fragments(info, video: true).count)
            p.audio = [[DASHSample]?](repeating: nil, count: HLSTransmuxer.fragments(info, video: false).count)
            // Video and audio batches alternated, so the readers never all queue on one file.
            var v = batches.filter { $0.video }, a = batches.filter { !$0.video }
            while !v.isEmpty || !a.isEmpty {
                if !v.isEmpty { p.pending.append(v.removeFirst()) }
                if !a.isEmpty { p.pending.append(a.removeFirst()) }
            }
            lock.unlock()
        }
        for q in StreamProxy.prepQueues.dropFirst() { q.async { StreamProxy.shared.prepRead(p) } }
        prepRead(p)
    }

    // One reader: batches off the shared list until it is empty or the stream moves on. The
    // last reader to finish lays the file out.
    private func prepRead(_ p: MP4Prep) {
        while true {
            lock.lock()
            let gen = p.gen
            guard let info = p.info, p.failed == nil, gen >= currentGen, !p.pending.isEmpty else { break }
            let batch = p.pending.removeFirst()
            lock.unlock()

            let frags = HLSTransmuxer.fragments(info, video: batch.video)
            let ranges = batch.items.map { (start: frags[$0.frag].offset, end: frags[$0.frag].offset + Int64($0.count) - 1) }
            let parts = CurlFetcher.multiRangeFetch(url: batch.video ? p.videoURL : p.audioURL, ranges: ranges,
                                                    pausesFeed: false,
                                                    shouldAbort: { StreamProxy.shared.isSuperseded(gen) })
            var read: [(frag: Int, samples: [DASHSample])] = []
            var again: [(frag: Int, count: Int)] = []
            var failure: String?
            if let parts = parts {
                for (part, item) in zip(parts, batch.items) {
                    let f = frags[item.frag]
                    switch HLSTransmuxer.fragmentSamples(head: part, offset: f.offset, size: f.size,
                                                         video: batch.video, info: info) {
                    case .samples(let s): read.append((item.frag, s))
                    case .needs(let n) where n > item.count: again.append((item.frag, n))
                    case .needs: failure = "moof still short at fragment \(item.frag)"
                    case .invalid(let why): failure = why
                    }
                }
            }
            lock.lock()
            if parts == nil {
                // Put back for the resume: superseded, or a network error a later prepareMP4 retries.
                p.pending.insert(batch, at: 0)
                lock.unlock()
                DebugLog.log("StreamProxy", "mp4 prep \(batch.video ? "video" : "audio") batch FETCH FAILED"
                    + (isSuperseded(gen) ? " (superseded)" : ""))
                lock.lock()
                break
            }
            p.requests += 1
            for part in parts ?? [] { p.bytes += part.count }
            for r in read {
                if batch.video { p.video[r.frag] = r.samples } else { p.audio[r.frag] = r.samples }
            }
            if !again.isEmpty { p.pending.append((batch.video, again)) }
            if let f = failure { p.failed = f }
            lock.unlock()
            if let f = failure { DebugLog.log("StreamProxy", "mp4 prep FAILED: \(f)") }
        }
        // Still holding lock here.
        p.workers -= 1
        let last = p.workers == 0
        let complete = p.info != nil && p.failed == nil && p.pending.isEmpty && p.done == p.total
        lock.unlock()
        guard last, complete, let info = p.info else {
            if last { DebugLog.log("StreamProxy", "mp4 prep paused at \(p.done)/\(p.total) moofs") }
            return
        }
        let readMs = Int(Date().timeIntervalSince(p.started) * 1000)
        let t0 = Date()
        let (built, why) = MP4StreamLayout.build(info: info, video: p.video.map { $0 ?? [] },
                                                 audio: p.audio.map { $0 ?? [] })
        let buildMs = Int(Date().timeIntervalSince(t0) * 1000)
        lock.lock()
        if let layout = built {
            layoutCache.removeAll { $0.key == p.key }
            layoutCache.append((key: p.key, layout: layout))
            if layoutCache.count > StreamProxy.layoutCacheSize { layoutCache.removeFirst() }
            if prep === p { prep = nil }   // done: the moof tables are not needed any more
        } else {
            p.failed = why
        }
        lock.unlock()
        if let layout = built {
            DebugLog.log("StreamProxy", "mp4 prep READY: \(p.video.count) video + \(p.audio.count) audio moofs in "
                + "\(p.requests) requests, \(p.bytes / 1024)KB, read \(readMs)ms (this run), laid out in \(buildMs)ms; "
                + "moov+head \(layout.head.count / 1024)KB, file \(layout.totalSize / 1_048_576)MB")
        } else {
            DebugLog.log("StreamProxy", "mp4 prep layout FAILED: \(why)")
        }
    }

    // What names a pair's files across fresh urls (see headKey); nil if either url doesn't say.
    private static func pairKey(_ videoURL: String, _ videoIndexEnd: Int64,
                                _ audioURL: String, _ audioIndexEnd: Int64) -> String? {
        guard let v = headKey(videoURL, indexEnd: videoIndexEnd),
              let a = headKey(audioURL, indexEnd: audioIndexEnd) else { return nil }
        return v + "+" + a
    }

    // Start fetching the segment after `asked`, for when AVPlayer asks for it. Not if the stream
    // has been superseded meanwhile: dropReadAheadLocked has already run for that change, and a
    // slot installed after it would never be dropped.
    //
    // Nor if AVPlayer has asked for another segment since `asked`. Starting a video at a saved
    // position, it asks for seg 0 and seg 1, then jumps while seg 1 is still being made; seg 1's
    // read-ahead of seg 2 then ran alongside the fetch AVPlayer was actually waiting on, forcing
    // a second connection: the jump target took 2.0 s instead of ~1 s. The newest request starts
    // its own read-ahead.
    private func startReadAhead(_ session: HLSSession, info: HLSStreamInfo, after asked: Int, gen: UInt64) {
        let seg = asked + 1
        guard seg < info.segmentCount,
              let vr = HLSTransmuxer.videoRange(info, seg: seg),
              let ar = HLSTransmuxer.audioRange(info, seg: seg) else { return }
        let slot = PrefetchSlot(seg: seg)
        lock.lock()
        let latest = session.lastAsked
        if latest != asked {
            lock.unlock()
            DebugLog.log("StreamProxy", "hls seg \(asked) superseded by seg \(latest) — no read-ahead")
            return
        }
        // A second request for the same segment (AVPlayer retrying) finds it already under way.
        if gen < currentGen || session.closed || session.ahead?.seg == seg { lock.unlock(); return }
        session.ahead?.abandon()
        session.ahead = slot
        lock.unlock()
        let vURL = session.videoURL, aURL = session.audioURL
        StreamProxy.readAheadQueue.async {
            slot.fill(vURL: vURL, vr: vr, aURL: aURL, ar: ar,
                      abort: { StreamProxy.shared.isStale(session, gen) })
        }
    }

    // Serve one file out of a downloaded HLS bundle. The requested name is VALIDATED against
    // the two shapes the playlist can reference rather than joined blindly, so a crafted path
    // ("../../Library/...") can't read its way out of the bundle directory — the listener is
    // bound to the loopback interface, but any app on the device can still reach it.
    private func serveOfflineHLS(dir: String, file: String, clientFd: Int32) {
        let isPlaylist = (file == "index.m3u8")
        let isSegment = file.hasPrefix("seg") && file.hasSuffix(".ts")
            && Int(String(file.dropFirst(3).dropLast(3))) != nil
        guard isPlaylist || isSegment else {
            StreamProxy.sendAll(clientFd, Array("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        let path = (dir as NSString).appendingPathComponent(file)
        guard let body = FileManager.default.contents(atPath: path) else {
            DebugLog.log("StreamProxy", "offline HLS MISS \(file) in \(dir)")
            StreamProxy.sendAll(clientFd, Array("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        sendResponse(clientFd,
                     contentType: isPlaylist ? "application/vnd.apple.mpegurl" : "video/MP2T",
                     body: body)
    }

    // Fetch + parse both streams' init+sidx heads once per session; cache info + playlist.
    // parseLock (NOT the routes lock — network I/O happens inside) serializes AVPlayer's
    // parallel connections so the heads are fetched exactly once.
    //
    // A session for files played recently — a recovery reload, reopening the video, switching
    // back to a quality — takes their heads from headCache instead: the same two ranged GETs,
    // in turn, before AVPlayer has even seen the segment list.
    private func ensureParsed(_ session: HLSSession, gen: UInt64) -> HLSStreamInfo? {
        session.parseLock.lock()
        defer { session.parseLock.unlock() }
        if let info = session.info { return info }
        if let key = session.headKey {
            lock.lock()
            let hit = headCache.first(where: { $0.key == key })
            lock.unlock()
            if let hit = hit {
                session.info = hit.info
                session.playlistText = hit.playlist
                DebugLog.log("StreamProxy", "hls heads reused (\(hit.info.segmentCount) segments)")
                return hit.info
            }
        }
        let t0 = Date()
        guard let vHead = fetchRange(url: session.videoURL, start: 0, end: session.videoIndexEnd, gen: gen),
              let aHead = fetchRange(url: session.audioURL, start: 0, end: session.audioIndexEnd, gen: gen) else { return nil }
        guard let info = HLSTransmuxer.parse(videoHead: vHead, audioHead: aHead) else {
            return nil
        }
        let playlist = HLSTransmuxer.playlist(info)
        session.info = info
        session.playlistText = playlist
        if let key = session.headKey {
            lock.lock()
            headCache.removeAll { $0.key == key }
            headCache.append(CachedHeads(key: key, info: info, playlist: playlist))
            if headCache.count > StreamProxy.headCacheSize { headCache.removeFirst() }
            lock.unlock()
        }
        DebugLog.log("StreamProxy", "hls heads fetched in \(Int(Date().timeIntervalSince(t0) * 1000))ms "
            + "(\(info.segmentCount) segments\(session.headKey == nil ? ", no key — not cached" : ""))")
        return info
    }

    // Bounded ranged GET, with the superseded-generation abort layered on: if a newer video is
    // requested while a head fetch is mid-flight, the progress callback kills it within ~1s
    // so it can't hold the feed turnstile. The transfer itself lives in CurlFetcher.rangeFetch,
    // shared with OfflineDownloader (which passes its own cancellation check instead).
    // Segments are fetched through PrefetchSlot, with the same check (see makeSegment).
    private func fetchRange(url: String, start: Int64, end: Int64, gen: UInt64) -> Data? {
        return CurlFetcher.rangeFetch(url: url, start: start, end: end) {
            StreamProxy.shared.isSuperseded(gen)
        }
    }

    private func sendResponse(_ clientFd: Int32, contentType: String, body: Data) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        guard StreamProxy.sendAll(clientFd, Array(head.utf8)) else { return }
        body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            if let base = raw.baseAddress {
                _ = StreamProxy.sendAll(clientFd, base.assumingMemoryBound(to: UInt8.self), body.count)
            }
        }
    }

    // Read the request head (up to the blank line). Requests from AVPlayer are small.
    private func readRequestHead(_ fd: Int32) -> String? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 2048)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { return data.isEmpty ? nil : String(data: data, encoding: .isoLatin1) }
            data.append(buf, count: n)
            if data.count > 16 * 1024 { break }   // guard against a runaway/malformed head
        }
        return String(data: data, encoding: .isoLatin1)
    }

    // How many times a dropped transfer is reconnected before giving up.
    private static let maxProxyResumes = 3

    private func proxy(remoteURL: String, gen: UInt64, rangeHeader: String?, clientFd: Int32) {
        let conn = ProxyConn(clientFd, gen: gen)
        let connPtr = Unmanaged.passUnretained(conn).toOpaque()

        // Where AVPlayer's request starts and ends, so a resume can ask for the remainder.
        // nil = the header exists but isn't a form we can offset into (e.g. a suffix range),
        // which disables resuming rather than reconnecting at a guessed position.
        let range = StreamProxy.parseByteRange(rangeHeader)

        // Pause the feed lane while this stream's TLS handshake to googlevideo runs, then reopen
        // it as soon as bytes flow (in the body callback). Guarantees the handshake isn't stalled
        // by concurrent feed TLS on OpenSSL's global locks — the cause of the download fallback
        // when tapping play during feed load. Balanced by the defer below for zero-body/error paths.
        CurlFetcher.pauseFeed()
        defer { if !conn.feedResumed { conn.feedResumed = true; CurlFetcher.resumeFeed() } }

        // googlevideo drops a long-lived progressive transfer mid-file often enough to matter
        // (CURLE_RECV_ERROR, seen ~2min into a 2m41s video). Left alone, the client socket just
        // closes and AVPlayer reads the short body as end-of-stream — the video stops before the
        // end. So reconnect from the byte we last relayed and keep writing into the SAME socket:
        // the head, Content-Length included, went out on the first leg, so the continuation is
        // invisible to AVPlayer and the promised byte count is still delivered exactly.
        var legRange = rangeHeader
        var resumes = 0
        while true {
            let result = performLeg(remoteURL: remoteURL, rangeHeader: legRange, connPtr: connPtr)
            let complete = result == 0 && (conn.expectedBody < 0 || conn.bytesRelayed >= conn.expectedBody)
            if complete || conn.aborted { break }
            DebugLog.log("StreamProxy", "proxy connection gen=\(gen) curlResult=\(result) aborted=\(conn.aborted) superseded=\(isSuperseded(gen)) relayed=\(conn.bytesRelayed)/\(conn.expectedBody) url=\(remoteURL.prefix(80))")
            // Only resumable once a head has been committed to AVPlayer AND its Content-Length
            // told us how much is still owed. Anything else keeps the old behaviour (give up, let
            // the caller close the socket) rather than guessing at the stream position.
            guard let range = range, conn.headersSent, conn.expectedBody > 0,
                  !isSuperseded(gen), resumes < StreamProxy.maxProxyResumes else { break }
            resumes += 1
            conn.isResumeLeg = true
            conn.resumeAccepted = false
            let from = range.start + conn.bytesRelayed
            legRange = "Range: bytes=\(from)-" + (range.end.map { String($0) } ?? "")
            DebugLog.log("StreamProxy", "proxy resume gen=\(gen) attempt=\(resumes) from=\(from)")
        }

        // Zero-body responses (e.g. 304/416) never reach the body callback — flush the head now.
        if !conn.headersSent && !conn.aborted {
            let head = (conn.responseHead.isEmpty ? "HTTP/1.1 502 Bad Gateway\r\n" : conn.responseHead) + "Connection: close\r\n\r\n"
            StreamProxy.sendAll(clientFd, Array(head.utf8))
        }
    }

    // One upstream GET attempt. A fresh handle per leg — libcurl handles are not reusable once a
    // transfer has been aborted, and a resume needs a different Range header anyway.
    private func performLeg(remoteURL: String, rangeHeader: String?,
                            connPtr: UnsafeMutableRawPointer) -> Int32 {
        let h = curl_bridge_init()
        defer { curl_bridge_cleanup(h) }
        remoteURL.withCString { curl_bridge_set_url(h, $0) }
        curl_bridge_set_ssl_noverify(h)
        curl_bridge_set_follow_redirects(h)
        curl_bridge_set_timeout(h, 0)   // 0 = no overall timeout; a stream can run for a while
        "com.google.android.youtube/19.09.37 (Linux; U; Android 11) gzip".withCString {
            curl_bridge_set_useragent(h, $0)
        }
        if let r = rangeHeader { r.withCString { curl_bridge_add_header(h, $0) } }
        curl_bridge_set_header_fn(h, proxyHeaderCallback, connPtr)
        curl_bridge_set_write_fn(h, proxyBodyCallback, connPtr)
        // Abort this transfer promptly if a newer video is requested (see proxyProgressCallback).
        curl_bridge_set_progress_fn(h, proxyProgressCallback, connPtr)
        return curl_bridge_perform(h)
    }

    // "Range: bytes=START-END" -> (START, END). No header at all means a plain GET, i.e. start 0
    // with no end. nil is returned for anything else (suffix range "bytes=-500", multi-range,
    // garbage) so the caller knows it cannot compute a resume offset.
    private static func parseByteRange(_ header: String?) -> (start: Int64, end: Int64?)? {
        guard let header = header else { return (0, nil) }
        guard let eq = header.range(of: "bytes=") else { return nil }
        let spec = header[eq.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let bounds = spec.components(separatedBy: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]) else { return nil }
        if bounds[1].isEmpty { return (start, nil) }
        guard let end = Int64(bounds[1]) else { return nil }
        return (start, end)
    }

    // MARK: - Socket write helpers (called from the C callbacks too)

    @discardableResult
    static func sendAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        return bytes.withUnsafeBufferPointer { sendAll(fd, $0.baseAddress!, $0.count) }
    }

    // Bytes from..<to of `d`.
    static func sendSlice(_ fd: Int32, _ d: Data, from: Int, to: Int) -> Bool {
        guard from >= 0, to <= d.count, from < to else { return from == to }
        return d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            return sendAll(fd, base.assumingMemoryBound(to: UInt8.self) + from, to - from)
        }
    }

    @discardableResult
    static func sendAll(_ fd: Int32, _ ptr: UnsafePointer<UInt8>, _ count: Int) -> Bool {
        var sent = 0
        while sent < count {
            let n = send(fd, ptr + sent, count - sent, 0)
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                return false
            }
            sent += n
        }
        return true
    }
}
