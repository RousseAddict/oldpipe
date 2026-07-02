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
    // googlevideo response head, accumulated line-by-line from libcurl's header callback.
    // Reset whenever a new "HTTP/" status line arrives so only the FINAL response (after any
    // redirects curl followed) is forwarded.
    var responseHead = ""
    var headersSent = false
    var aborted = false
    init(_ fd: Int32) { clientFd = fd }
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
        let head = (conn.responseHead.isEmpty ? "HTTP/1.1 200 OK\r\n" : conn.responseHead) + "Connection: close\r\n\r\n"
        if !StreamProxy.sendAll(conn.clientFd, Array(head.utf8)) { conn.aborted = true; return 0 }
        conn.headersSent = true
    }
    let ok = StreamProxy.sendAll(conn.clientFd, ptr.assumingMemoryBound(to: UInt8.self), bytes)
    if !ok { conn.aborted = true; return 0 }   // returning < bytes tells libcurl to abort
    return bytes
}

// MARK: - StreamProxy

final class StreamProxy: NSObject {

    static let shared = StreamProxy()

    private var listenFd: Int32 = -1
    private var port: UInt16 = 0
    private var started = false

    // Maps the opaque local path token -> real googlevideo URL. Avoids encoding the URL into
    // the path (addingPercentEncoding / base64 options are iOS 7+). NSLock-guarded because
    // localURL(for:) is called on the main thread while connection threads read it.
    private var routes: [String: String] = [:]
    private var routeSeq: UInt64 = 0
    private let lock = NSLock()

    // Return a local http:// URL that proxies to `remote`. Starts the listener on first use.
    // nil only if the socket could not be opened.
    func localURL(for remote: String) -> URL? {
        guard start() else { return nil }
        lock.lock()
        routeSeq += 1
        let token = "\(routeSeq).mp4"
        routes[token] = remote
        lock.unlock()
        return URL(string: "http://127.0.0.1:\(port)/\(token)")
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

        lock.lock(); let remote = routes[token]; lock.unlock()
        guard let remoteURL = remote else {
            StreamProxy.sendAll(clientFd, Array("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n".utf8))
            return
        }

        // Forward the client's Range header verbatim so AVPlayer's byte-range requests work.
        var rangeHeader: String?
        for line in lines.dropFirst() where line.lowercased().hasPrefix("range:") {
            rangeHeader = line
        }

        proxy(remoteURL: remoteURL, rangeHeader: rangeHeader, clientFd: clientFd)
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

    private func proxy(remoteURL: String, rangeHeader: String?, clientFd: Int32) {
        let conn = ProxyConn(clientFd)
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

        _ = curl_bridge_perform(h)

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
