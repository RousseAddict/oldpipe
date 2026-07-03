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
    DispatchQueue.main.async { box.progressHandler?(progress) }
    return 0
}

private class CurlDownloadBox {
    var fileHandle: FileHandle?
    var bytesReceived: Int64 = 0
    var progressHandler: ((Float) -> Void)?
}

// MARK: - CurlFetcher

class CurlFetcher {
    private static var active: [CurlFetcher] = []

    // Normal-lane concurrent worker queue (feed channel-browses + thumbnails) — lets independent
    // transfers run in parallel instead of one-at-a-time.
    // (No QoS — DispatchQoS is iOS 8+; this app targets iOS 6/7.)
    private static let curlQueue = DispatchQueue(label: "com.oldpipe.curl", attributes: .concurrent)
    // Serial gate: holds back dispatch to curlQueue until a slot frees, so we never spawn
    // a worker thread per queued request (iPhone 4S has a hard thread/stack-memory budget).
    private static let gateQueue = DispatchQueue(label: "com.oldpipe.curl.gate")
    // Caps concurrent in-flight transfers on the feed lane. 2 (was 4): on the dual-core A5
    // (iPhone 4S), 4 simultaneous OpenSSL/TLS transfers saturate both cores with crypto and
    // starve an interactive player request (tapped during feed load) of CPU — making its TLS
    // handshake crawl. 2 still parallelises the feed meaningfully while leaving a core free so
    // the high-priority player request on highQueue completes promptly.
    private static let curlLimit = DispatchSemaphore(value: 2)
    // High-priority lane = a DEDICATED SERIAL queue. A serial queue owns its own private worker
    // thread, so an interactive request (tapping a video → player/stream fetch) gets a thread
    // immediately and is NOT subject to the concurrent pool's width-throttling — which is what
    // starved it before, when all 4 normal-lane threads were blocked in a synchronous
    // curl_bridge_perform on slow/timing-out feed sockets. Player requests are sequential
    // (bootstrap visitorData → player), so serializing the high lane is fine.
    private static let highQueue = DispatchQueue(label: "com.oldpipe.curl.high")
    // Feed turnstile (preemption). Closed by a high-priority request for its whole duration so the
    // feed lane starts NO new transfers while a player request is in flight. This is the real fix:
    // the shipped OpenSSL 3.4.x serializes concurrent TLS handshakes on internal global locks, so a
    // simultaneous feed handshake stalls the player's handshake no matter how threads/cores are
    // split. Pausing new feed work lets the player run against near-zero concurrent TLS. Value 1 =
    // open; a high request waits it to 0 (closed) and signals back to 1 when done. The highQueue is
    // serial, so begin/close and end/open are always balanced (only one high request runs at once).
    private static let feedTurnstile = DispatchSemaphore(value: 1)
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

    // GET request
    static func fetchData(url: String, timeout: Int = 30, completion: @escaping (Data?) -> Void) {
        let fetcher = CurlFetcher()
        retain(fetcher)
        submit {
            let data = fetcher.syncFetchData(url: url, timeout: timeout)
            DispatchQueue.main.async { release(fetcher); completion(data) }
        }
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
            DispatchQueue.main.async { release(fetcher); completion(data) }
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
            DispatchQueue.main.async { release(fetcher); completion(ok) }
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
