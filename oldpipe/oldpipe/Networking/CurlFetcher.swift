import Foundation

// MARK: - C-compatible callbacks (file scope)

private let curlDataWriteCallback: @convention(c) (UnsafeRawPointer?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, userdata in
    guard let ptr = ptr, let userdata = userdata else { return 0 }
    let bytes = size * nmemb
    Unmanaged<NSMutableData>.fromOpaque(userdata).takeUnretainedValue().append(ptr, length: bytes)
    return bytes
}

private let curlFileWriteCallback: @convention(c) (UnsafeRawPointer?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, userdata in
    guard let ptr = ptr, let userdata = userdata else { return 0 }
    let bytes = size * nmemb
    let box = Unmanaged<CurlDownloadBox>.fromOpaque(userdata).takeUnretainedValue()
    box.fileHandle?.write(Data(bytes: ptr, count: bytes))
    box.bytesReceived += Int64(bytes)
    return bytes
}

private let curlProgressCallback: @convention(c) (UnsafeMutableRawPointer?, Int64, Int64, Int64, Int64) -> Int32 = { clientp, dltotal, dlnow, _, _ in
    guard let clientp = clientp, dltotal > 0 else { return 0 }
    let box = Unmanaged<CurlDownloadBox>.fromOpaque(clientp).takeUnretainedValue()
    let progress = Float(dlnow) / Float(dltotal)
    AppQueue.main.async { box.progressHandler?(progress) }
    return 0
}

private class CurlDownloadBox {
    var fileHandle: FileHandle?
    var bytesReceived: Int64 = 0
    var progressHandler: ((Float) -> Void)?
}

// MARK: - Ranged GET

// Accumulator for one bounded ranged GET. `shouldAbort` is polled from the libcurl progress
// callback (off the main thread) so a caller can kill a mid-flight transfer: StreamProxy uses
// it for its superseded-generation check, OfflineDownloader for user cancellation.
// Phase timings of one transfer, filled by rangeFetch when the caller passes one.
// `reusedConnection` is the question this exists to answer: a fresh TCP+TLS handshake
// costs 1-3s on an iPhone 4S, so a segment loop that silently reconnects every time is
// slow for a reason no amount of mux optimisation will fix.
final class CurlTiming {
    var namelookup = 0.0
    var connect = 0.0
    var appconnect = 0.0
    var total = 0.0
    // libcurl reports 0 for a phase that did not happen. No connect AND no TLS handshake
    // means this transfer rode an existing connection out of the shared cache.
    var reusedConnection: Bool { return connect == 0 && appconnect == 0 }
    var ms: Int { return Int(total * 1000) }
    var tlsMs: Int { return Int(appconnect * 1000) }
}

final class CurlRangeCtx {
    var data = Data()
    var aborted = false
    let shouldAbort: () -> Bool
    init(shouldAbort: @escaping () -> Bool) { self.shouldAbort = shouldAbort }
}

private let curlRangeWriteCallback: @convention(c) (UnsafeRawPointer?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, userdata in
    let bytes = size * nmemb
    guard let ptr = ptr, let userdata = userdata else { return 0 }
    let ctx = Unmanaged<CurlRangeCtx>.fromOpaque(userdata).takeUnretainedValue()
    if ctx.aborted { return 0 }
    ctx.data.append(Data(bytes: ptr, count: bytes))
    return bytes
}

private let curlRangeProgressCallback: @convention(c) (UnsafeMutableRawPointer?, Int64, Int64, Int64, Int64) -> Int32 = { clientp, _, _, _, _ in
    guard let clientp = clientp else { return 0 }
    let ctx = Unmanaged<CurlRangeCtx>.fromOpaque(clientp).takeUnretainedValue()
    if ctx.aborted { return 1 }
    if ctx.shouldAbort() { ctx.aborted = true; return 1 }
    return 0
}

// MARK: - CurlFetcher

class CurlFetcher {
    private static var active: [CurlFetcher] = []

    // Normal-lane concurrent worker queue (feed channel-browses + thumbnails) — lets independent
    // transfers run in parallel instead of one-at-a-time.
    // (No QoS — DispatchQoS is iOS 8+; this app targets iOS 6/7.)
    private static let curlQueue = AppQueue(label: "com.oldpipe.curl", attributes: .concurrent)
    // Serial gate: holds back dispatch to curlQueue until a slot frees, so we never spawn
    // a worker thread per queued request (iPhone 4S has a hard thread/stack-memory budget).
    private static let gateQueue = AppQueue(label: "com.oldpipe.curl.gate")
    // Caps concurrent in-flight transfers on the feed lane. 2 (was 4): on the dual-core A5
    // (iPhone 4S), 4 simultaneous OpenSSL/TLS transfers saturate both cores with crypto and
    // starve an interactive player request (tapped during feed load) of CPU — making its TLS
    // handshake crawl. 2 still parallelises the feed meaningfully while leaving a core free so
    // the high-priority player request on highQueue completes promptly.
    private static let curlLimit = AppSemaphore(value: 2)
    // High-priority lane = a DEDICATED SERIAL queue. A serial queue owns its own private worker
    // thread, so an interactive request (tapping a video → player/stream fetch) gets a thread
    // immediately and is NOT subject to the concurrent pool's width-throttling — which is what
    // starved it before, when all 4 normal-lane threads were blocked in a synchronous
    // curl_bridge_perform on slow/timing-out feed sockets. Player requests are sequential
    // (bootstrap visitorData → player), so serializing the high lane is fine.
    private static let highQueue = AppQueue(label: "com.oldpipe.curl.high")
    // Feed turnstile (preemption). Closed by a high-priority request for its whole duration so the
    // feed lane starts NO new transfers while a player request is in flight. This is the real fix:
    // the shipped OpenSSL 3.4.x serializes concurrent TLS handshakes on internal global locks, so a
    // simultaneous feed handshake stalls the player's handshake no matter how threads/cores are
    // split. Pausing new feed work lets the player run against near-zero concurrent TLS. Value 1 =
    // open; a high request waits it to 0 (closed) and signals back to 1 when done. The highQueue is
    // serial, so begin/close and end/open are always balanced (only one high request runs at once).
    private static let feedTurnstile = AppSemaphore(value: 1)
    // dispatch_once via static let — runs exactly once even under concurrent first access
    // (Swift lazy-static init is thread-safe), so curl_global_init is never called concurrently.
    private static let curlGlobalInit: Bool = { curl_bridge_global_init(); return true }()

    // Public trigger for the same once-init — used by StreamProxy, which drives libcurl
    // directly (off CurlFetcher's lanes) and must guarantee curl_global_init has run first.
    static func ensureGlobalInit() { _ = curlGlobalInit }

    // StreamProxy drives libcurl directly (off these lanes) but must still PREEMPT the feed while
    // it primes a googlevideo stream handshake — otherwise concurrent feed TLS (serialized on
    // OpenSSL's global locks) stalls the stream's handshake, AVPlayer never gets bytes in time,
    // and playback falls back to download. These bracket the proxy's handshake window using the
    // SAME feedTurnstile as the high-priority API lane (binary semaphore = mutual exclusion), so
    // no new feed transfer starts until the stream is flowing. Calls MUST be balanced 1:1.
    static func pauseFeed() { feedTurnstile.wait() }
    static func resumeFeed() { feedTurnstile.signal() }

    // googlevideo rejects a generic UA; every CDN transfer (proxy, transmux, offline download)
    // presents the same android client string the player response was minted for.
    static let googlevideoUserAgent = "com.google.android.youtube/19.09.37 (Linux; U; Android 11) gzip"

    // SYNCHRONOUS plain GET. Same contract and audience as rangeFetch below: the caller is
    // already on a background queue (OfflineDownloader's), so blocking is the point. Used to
    // pull caption transcripts at download time, where the async lanes would mean threading a
    // completion chain through the middle of the segment loop.
    static func getSync(url: String, timeout: Int = 30) -> Data? {
        _ = curlGlobalInit
        pauseFeed()
        defer { resumeFeed() }
        return CurlFetcher().syncFetchData(url: url, timeout: timeout)
    }

    // SYNCHRONOUS bounded ranged GET against the googlevideo CDN — the one primitive both the
    // live transmux path (StreamProxy.fetchRange) and the offline downloader need. Callers are
    // already on a background thread (a proxy connection thread, or OfflineDownloader's serial
    // queue), so blocking here is the point.
    //
    // Pauses the feed lane for the duration — same anti-concurrent-TLS rule as the proxy's
    // streaming path — but unlike a stream these transfers are short and bounded, so the
    // pause/resume brackets the whole call.
    //
    // Requires the EXACT ranged byte count: a 200 (server ignored the range) or a truncated
    // body would silently corrupt fragment offsets downstream. Returns nil on network error,
    // non-206, abort, or any short/over-long body.
    static func rangeFetch(url: String, start: Int64, end: Int64, timeout: Int = 60,
                           timing: CurlTiming? = nil,
                           shouldAbort: @escaping () -> Bool = { false }) -> Data? {
        guard end >= start else { return nil }
        _ = curlGlobalInit
        let ctx = CurlRangeCtx(shouldAbort: shouldAbort)
        let ctxPtr = Unmanaged.passUnretained(ctx).toOpaque()

        guard let h = curl_bridge_init() else { return nil }
        defer { curl_bridge_cleanup(h) }
        url.withCString { curl_bridge_set_url(h, $0) }
        curl_bridge_set_ssl_noverify(h)
        curl_bridge_set_follow_redirects(h)
        curl_bridge_set_timeout(h, CLong(timeout))
        googlevideoUserAgent.withCString { curl_bridge_set_useragent(h, $0) }
        "Range: bytes=\(start)-\(end)".withCString { curl_bridge_add_header(h, $0) }
        curl_bridge_set_write_fn(h, curlRangeWriteCallback, ctxPtr)
        curl_bridge_set_progress_fn(h, curlRangeProgressCallback, ctxPtr)

        pauseFeed()
        defer { resumeFeed() }

        let rc = curl_bridge_perform(h)
        let code = curl_bridge_response_code(h)
        // Read timings BEFORE the guard: a failed transfer's phase times are the most
        // interesting ones, and the handle is cleaned up on the way out.
        if let t = timing {
            curl_bridge_timing(h, &t.namelookup, &t.connect, &t.appconnect, &t.total)
        }
        let want = end - start + 1
        guard rc == 0, code == 206, !ctx.aborted, Int64(ctx.data.count) == want else { return nil }
        return ctx.data
    }

    // Submit background work. highPriority runs on the dedicated serial highQueue (its own thread)
    // and CLOSES the feed turnstile for its duration so no new feed transfer competes for TLS.
    // Normal work passes the turnstile (blocks while a player request holds it), then waits for a
    // free slot and dispatches onto the concurrent queue, releasing the slot when it returns.
    private static func submit(highPriority: Bool = false, _ work: @escaping () -> Void) {
        if highPriority {
            highQueue.async {
                feedTurnstile.wait()        // close feed lane: no new transfers start
                work()
                feedTurnstile.signal()      // reopen feed lane
            }
            return
        }
        gateQueue.async {
            feedTurnstile.wait(); feedTurnstile.signal()  // pass only when the feed lane is open
            curlLimit.wait()
            curlQueue.async {
                work()
                curlLimit.signal()
            }
        }
    }

    // GET request. priority: true routes through the high-priority lane (preempts the
    // background feed), same as postJSON — used for user-initiated GETs like captions.
    //
    // Returns the fetcher as a cancellation handle. Calling cancel() on it before the work
    // closure reaches the front of the gate means NO socket is ever opened — which is the
    // point: scrolling a list away used to leave its thumbnail GETs queued ahead of the
    // thumbnails of the screen you just pushed, behind a 2-wide semaphore.
    @discardableResult
    static func fetchData(url: String, timeout: Int = 30, priority: Bool = false,
                          completion: @escaping (Data?) -> Void) -> CurlFetcher {
        let fetcher = CurlFetcher()
        retain(fetcher)
        submit(highPriority: priority) {
            // Cancelled while queued → skip the transfer entirely. submit() still signals
            // the slot after this closure returns, so the accounting stays balanced.
            if fetcher.isCancelled {
                AppQueue.main.async { release(fetcher) }
                return
            }
            let data = fetcher.syncFetchData(url: url, timeout: timeout)
            AppQueue.main.async {
                release(fetcher)
                if fetcher.isCancelled { return }
                completion(data)
            }
        }
        return fetcher
    }

    // MARK: - Cancellation

    // Guarded by the same objc_sync lock as `active` — cancel() is called from the main
    // thread while the flag is read on a curl worker thread.
    private var cancelled = false

    func cancel() {
        objc_sync_enter(CurlFetcher.self); cancelled = true; objc_sync_exit(CurlFetcher.self)
    }

    private var isCancelled: Bool {
        objc_sync_enter(CurlFetcher.self)
        let c = cancelled
        objc_sync_exit(CurlFetcher.self)
        return c
    }

    // POST JSON request with custom headers
    static func postJSON(url: String,
                         body: String,
                         headers: [String],
                         userAgent: String = "com.google.android.youtube/19.09.37 (Linux; U; Android 11) gzip",
                         timeout: Int = 30,
                         priority: Bool = false,
                         completion: @escaping (Data?) -> Void) {
        let fetcher = CurlFetcher()
        retain(fetcher)
        submit(highPriority: priority) {
            let data = fetcher.syncPostJSON(url: url, body: body, headers: headers,
                                            userAgent: userAgent, timeout: timeout)
            AppQueue.main.async { release(fetcher); completion(data) }
        }
    }

    // File download with progress
    static func downloadToFile(url: String,
                               outputPath: String,
                               progress: ((Float) -> Void)?,
                               completion: @escaping (Bool) -> Void) {
        let fetcher = CurlFetcher()
        retain(fetcher)
        submit {
            let ok = fetcher.syncDownload(url: url, outputPath: outputPath, progress: progress)
            AppQueue.main.async { release(fetcher); completion(ok) }
        }
    }

    // MARK: - Lifecycle

    private static func retain(_ f: CurlFetcher) {
        objc_sync_enter(CurlFetcher.self); active.append(f); objc_sync_exit(CurlFetcher.self)
    }
    private static func release(_ f: CurlFetcher) {
        objc_sync_enter(CurlFetcher.self); active.removeAll { $0 === f }; objc_sync_exit(CurlFetcher.self)
    }

    // MARK: - Sync implementations

    private func syncFetchData(url: String, timeout: Int) -> Data? {
        _ = CurlFetcher.curlGlobalInit
        let h = curl_bridge_init(); defer { curl_bridge_cleanup(h) }
        let buf = NSMutableData()
        let ptr = Unmanaged.passUnretained(buf).toOpaque()
        url.withCString { curl_bridge_set_url(h, $0) }
        curl_bridge_set_ssl_noverify(h)
        curl_bridge_set_follow_redirects(h)
        curl_bridge_set_timeout(h, CLong(timeout))
        curl_bridge_set_write_fn(h, curlDataWriteCallback, ptr)
        guard curl_bridge_perform(h) == 0 else { return nil }
        guard curl_bridge_response_code(h) == 200 else { return nil }
        return buf as Data
    }

    private func syncPostJSON(url: String, body: String, headers: [String],
                              userAgent: String, timeout: Int) -> Data? {
        _ = CurlFetcher.curlGlobalInit
        let h = curl_bridge_init(); defer { curl_bridge_cleanup(h) }
        let buf = NSMutableData()
        let ptr = Unmanaged.passUnretained(buf).toOpaque()
        url.withCString { curl_bridge_set_url(h, $0) }
        curl_bridge_set_ssl_noverify(h)
        curl_bridge_set_follow_redirects(h)
        curl_bridge_set_timeout(h, CLong(timeout))
        curl_bridge_set_write_fn(h, curlDataWriteCallback, ptr)
        for header in headers {
            header.withCString { curl_bridge_add_header(h, $0) }
        }
        userAgent.withCString { curl_bridge_set_useragent(h, $0) }
        // Pass body as a C string with explicit length (avoids null-terminator issues)
        let bodyData = Array(body.utf8)
        bodyData.withUnsafeBytes { rawBuf in
            let cptr = rawBuf.baseAddress!.assumingMemoryBound(to: Int8.self)
            curl_bridge_set_post_body(h, cptr, CLong(bodyData.count))
        }
        let rc = curl_bridge_perform(h)
        let code = curl_bridge_response_code(h)
        guard rc == 0 else { return nil }
        guard code == 200 else { return nil }
        return buf as Data
    }

    private func syncDownload(url: String, outputPath: String, progress: ((Float) -> Void)?) -> Bool {
        _ = CurlFetcher.curlGlobalInit
        let h = curl_bridge_init(); defer { curl_bridge_cleanup(h) }
        FileManager.default.createFile(atPath: outputPath, contents: nil, attributes: nil)
        guard let fh = FileHandle(forWritingAtPath: outputPath) else { return false }
        let box = CurlDownloadBox(); box.fileHandle = fh; box.progressHandler = progress
        let boxPtr = Unmanaged.passUnretained(box).toOpaque()
        url.withCString { curl_bridge_set_url(h, $0) }
        curl_bridge_set_ssl_noverify(h)
        curl_bridge_set_follow_redirects(h)
        curl_bridge_set_timeout(h, 600)
        curl_bridge_set_write_fn(h, curlFileWriteCallback, boxPtr)
        if progress != nil { curl_bridge_set_progress_fn(h, curlProgressCallback, boxPtr) }
        let rc = curl_bridge_perform(h)
        fh.closeFile()
        guard rc == 0 else { try? FileManager.default.removeItem(atPath: outputPath); return false }
        let code = curl_bridge_response_code(h)
        guard code == 200 || code == 206 else {
            try? FileManager.default.removeItem(atPath: outputPath); return false
        }
        return box.bytesReceived > 0
    }
}
