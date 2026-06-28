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
    // Serial queue — prevents concurrent curl_global_init race on first use
    private static let curlQueue = DispatchQueue(label: "com.oldpipe.curl")
    // dispatch_once via static let — runs exactly once, on first background access
    private static let curlGlobalInit: Bool = { curl_bridge_global_init(); return true }()

    // GET request
    static func fetchData(url: String, timeout: Int = 30, completion: @escaping (Data?) -> Void) {
        let fetcher = CurlFetcher()
        retain(fetcher)
        CurlFetcher.curlQueue.async {
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
                         completion: @escaping (Data?) -> Void) {
        let fetcher = CurlFetcher()
        retain(fetcher)
        CurlFetcher.curlQueue.async {
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
        CurlFetcher.curlQueue.async {
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
