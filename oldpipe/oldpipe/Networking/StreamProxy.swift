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
    } else if line == "\r\n" || line == "\n" || line.isEmpty {
        // blank line = end of head; keep buffered lines, don't append the terminator
    } else if lower.hasPrefix("transfer-encoding:") || lower.hasPrefix("connection:") {
        // hop-by-hop — libcurl already de-framed the body; forwarding these would break it
    } else {
        conn.responseHead += line
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
    if !conn.headersSent {
        // First body byte = handshake done and bytes flowing → reopen the feed lane we paused.
        if !conn.feedResumed { conn.feedResumed = true; CurlFetcher.resumeFeed() }
        let head = (conn.responseHead.isEmpty ? "HTTP/1.1 200 OK\r\n" : conn.responseHead) + "Connection: close\r\n\r\n"
        if !StreamProxy.sendAll(conn.clientFd, Array(head.utf8)) { conn.aborted = true; return 0 }
        conn.headersSent = true
    }
    let ok = StreamProxy.sendAll(conn.clientFd, ptr.assumingMemoryBound(to: UInt8.self), bytes)
    if !ok { conn.aborted = true; return 0 }   // returning < bytes tells libcurl to abort
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

// MARK: - Internal ranged fetch (HLS transmux)

// Accumulates one bounded ranged GET (init+sidx head, or one DASH fragment) into memory.
// Unlike ProxyConn there's no client socket — the bytes feed HLSTransmuxer, not AVPlayer.
private final class RangeFetchCtx {
    var data = Data()
    let gen: UInt64
    var aborted = false
    init(gen: UInt64) { self.gen = gen }
}

private let rangeFetchWriteCallback: @convention(c) (UnsafeRawPointer?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, userdata in
    let bytes = size * nmemb
    guard let ptr = ptr, let userdata = userdata else { return 0 }
    let ctx = Unmanaged<RangeFetchCtx>.fromOpaque(userdata).takeUnretainedValue()
    if ctx.aborted { return 0 }
    ctx.data.append(Data(bytes: ptr, count: bytes))
    return bytes
}

// Same superseded-generation abort as proxyProgressCallback: if a newer video is requested
// while a segment fetch is mid-flight, kill it within ~1s so it can't hold the feed turnstile.
private let rangeFetchProgressCallback: @convention(c) (UnsafeMutableRawPointer?, Int64, Int64, Int64, Int64) -> Int32 = { clientp, _, _, _, _ in
    guard let clientp = clientp else { return 0 }
    let ctx = Unmanaged<RangeFetchCtx>.fromOpaque(clientp).takeUnretainedValue()
    if ctx.aborted { return 1 }
    if StreamProxy.shared.isSuperseded(ctx.gen) { ctx.aborted = true; return 1 }
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
    init(videoURL: String, audioURL: String, videoIndexEnd: Int64, audioIndexEnd: Int64, gen: UInt64) {
        self.videoURL = videoURL
        self.audioURL = audioURL
        self.videoIndexEnd = videoIndexEnd
        self.audioIndexEnd = audioIndexEnd
        self.gen = gen
    }
}

// MARK: - StreamProxy

final class StreamProxy: NSObject {

    static let shared = StreamProxy()

    private var listenFd: Int32 = -1
    private var port: UInt16 = 0
    private var started = false

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
        lock.lock()
        routeSeq += 1
        currentGen += 1
        let id = "\(routeSeq)"
        hlsSessions[id] = HLSSession(videoURL: videoURL, audioURL: audioURL,
                                     videoIndexEnd: videoIndexEnd, audioIndexEnd: audioIndexEnd,
                                     gen: currentGen)
        lock.unlock()
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
        lock.unlock()
        DebugLog.log("StreamProxy", "closeCurrentStream gen=\(bumped)")
    }

    // Tear down the listen socket so the NEXT localURL(for:) opens a fresh one. iOS reclaims
    // loopback listening sockets while an app is SUSPENDED in the background; on resume the old
    // socket/port is dead, so localURL would hand AVPlayer a URL to a closed port → no bytes →
    // the stream stalls past AVPlayer's readiness window → download fallback. Called from
    // AppDelegate on foreground. Closing listenFd unblocks acceptLoop's accept() so that thread
    // exits cleanly; flipping `started` back to false makes start() rebind on next use. No-op if
    // the listener was never started (iOS 7+ never uses the proxy, so this stays a no-op there).
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
        // Raw Thread (not GCD): the accept loop blocks forever, and per-connection threads
        // block in a synchronous curl_easy_perform for the whole stream — parking those on a
        // GCD concurrent queue would exhaust its width. NSThread each owns a real OS thread.
        let t = Thread(target: self, selector: #selector(acceptLoop), object: nil)
        t.stackSize = 512 * 1024
        t.start()
        return true
    }

    @objc private func acceptLoop() {
        while true {
            let client = accept(listenFd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            let t = Thread(target: self, selector: #selector(handleConnection(_:)), object: NSNumber(value: client))
            t.stackSize = 512 * 1024
            t.start()
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
              let vr = HLSTransmuxer.videoRange(info, seg: seg),
              let ar = HLSTransmuxer.audioRange(info, seg: seg) else {
            StreamProxy.sendAll(clientFd, Array("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        guard let vBlob = fetchRange(url: session.videoURL, start: vr.start, end: vr.end, gen: gen),
              let aBlob = fetchRange(url: session.audioURL, start: ar.start, end: ar.end, gen: gen) else {
            StreamProxy.sendAll(clientFd, Array("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        guard let ts = HLSTransmuxer.muxSegment(info, seg: seg, videoBlob: vBlob, audioBlob: aBlob) else {
            StreamProxy.sendAll(clientFd, Array("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        sendResponse(clientFd, contentType: "video/MP2T", body: ts)
    }

    // Fetch + parse both streams' init+sidx heads once per session; cache info + playlist.
    // parseLock (NOT the routes lock — network I/O happens inside) serializes AVPlayer's
    // parallel connections so the heads are fetched exactly once.
    private func ensureParsed(_ session: HLSSession, gen: UInt64) -> HLSStreamInfo? {
        session.parseLock.lock()
        defer { session.parseLock.unlock() }
        if let info = session.info { return info }
        guard let vHead = fetchRange(url: session.videoURL, start: 0, end: session.videoIndexEnd, gen: gen),
              let aHead = fetchRange(url: session.audioURL, start: 0, end: session.audioIndexEnd, gen: gen) else { return nil }
        guard let info = HLSTransmuxer.parse(videoHead: vHead, audioHead: aHead) else {
            return nil
        }
        session.info = info
        session.playlistText = HLSTransmuxer.playlist(info)
        return info
    }

    // Bounded ranged GET through the curl bridge (googlevideo needs GCM TLS + android UA).
    // Pauses the feed lane for the duration — same anti-concurrent-TLS rule as proxy() — but
    // unlike proxy() these transfers are short and bounded, so pause/resume brackets the whole
    // call. Returns nil on network error, non-2xx, abort, or short/over-long body.
    private func fetchRange(url: String, start: Int64, end: Int64, gen: UInt64) -> Data? {
        guard end >= start else { return nil }
        let ctx = RangeFetchCtx(gen: gen)
        let ctxPtr = Unmanaged.passUnretained(ctx).toOpaque()

        guard let h = curl_bridge_init() else { return nil }
        defer { curl_bridge_cleanup(h) }
        url.withCString { curl_bridge_set_url(h, $0) }
        curl_bridge_set_ssl_noverify(h)
        curl_bridge_set_follow_redirects(h)
        curl_bridge_set_timeout(h, 60)
        "com.google.android.youtube/19.09.37 (Linux; U; Android 11) gzip".withCString {
            curl_bridge_set_useragent(h, $0)
        }
        "Range: bytes=\(start)-\(end)".withCString { curl_bridge_add_header(h, $0) }
        curl_bridge_set_write_fn(h, rangeFetchWriteCallback, ctxPtr)
        curl_bridge_set_progress_fn(h, rangeFetchProgressCallback, ctxPtr)

        CurlFetcher.pauseFeed()
        defer { CurlFetcher.resumeFeed() }

        let rc = curl_bridge_perform(h)
        let code = curl_bridge_response_code(h)
        // Require the exact ranged byte count — a 200 (range ignored) or truncated body would
        // silently corrupt fragment offsets downstream.
        let want = end - start + 1
        guard rc == 0, code == 206, !ctx.aborted, Int64(ctx.data.count) == want else {
            return nil
        }
        return ctx.data
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

    private func proxy(remoteURL: String, gen: UInt64, rangeHeader: String?, clientFd: Int32) {
        let conn = ProxyConn(clientFd, gen: gen)
        let connPtr = Unmanaged.passUnretained(conn).toOpaque()

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

        // Pause the feed lane while this stream's TLS handshake to googlevideo runs, then reopen
        // it as soon as bytes flow (in the body callback). Guarantees the handshake isn't stalled
        // by concurrent feed TLS on OpenSSL's global locks — the cause of the download fallback
        // when tapping play during feed load. Balanced by the defer below for zero-body/error paths.
        CurlFetcher.pauseFeed()
        defer { if !conn.feedResumed { conn.feedResumed = true; CurlFetcher.resumeFeed() } }

        let result = curl_bridge_perform(h)
        if result != 0 || conn.aborted {
            DebugLog.log("StreamProxy", "proxy connection gen=\(gen) curlResult=\(result) aborted=\(conn.aborted) superseded=\(isSuperseded(gen)) url=\(remoteURL.prefix(80))")
        }

        // Zero-body responses (e.g. 304/416) never reach the body callback — flush the head now.
        if !conn.headersSent && !conn.aborted {
            let head = (conn.responseHead.isEmpty ? "HTTP/1.1 502 Bad Gateway\r\n" : conn.responseHead) + "Connection: close\r\n\r\n"
            StreamProxy.sendAll(clientFd, Array(head.utf8))
        }
    }

    // MARK: - Socket write helpers (called from the C callbacks too)

    @discardableResult
    static func sendAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        return bytes.withUnsafeBufferPointer { sendAll(fd, $0.baseAddress!, $0.count) }
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
