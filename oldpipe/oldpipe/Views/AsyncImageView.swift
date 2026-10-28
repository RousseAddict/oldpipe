import UIKit

class AsyncImageView: UIImageView {

    // MARK: - Memory cache
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        // The memory the cache used to settle at — 20 thumbnails decoded at 806 KB each — now
        // holds ~70 of them at 230 KB (see downscaleAndDecode). At 20, about three screens of
        // rows, a list scrolled back any further re-decoded them from disk.
        c.countLimit = 100
        c.totalCostLimit = 16 * 1024 * 1024  // 16 MB decoded bytes
        return c
    }()

    // MARK: - Disk cache
    private static let diskCacheDir: String = {
        let dirs = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)
        let base = dirs.first ?? NSTemporaryDirectory()
        let dir = (base as NSString).appendingPathComponent("com.oldpipe.images")
        try? FileManager.default.createDirectory(atPath: dir,
                                                  withIntermediateDirectories: true,
                                                  attributes: nil)
        return dir
    }()

    private static let nonAlphanumerics = CharacterSet.alphanumerics.inverted

    private static func diskPath(for url: String) -> String {
        let safe = url.components(separatedBy: nonAlphanumerics).joined(separator: "_")
        let key = safe.count > 120 ? String(safe.suffix(120)) : safe
        return (diskCacheDir as NSString).appendingPathComponent("\(key).jpg")
    }

    // MARK: - Decode queue (serial — UIGraphicsBeginImageContextWithOptions unsafe concurrent on iOS 6)
    private static let decodeQueue = AppQueue(label: "com.oldpipe.imagedecode")

    // MARK: - In-flight registry
    // One pipeline per URL, shared by every view that asks for it (two cells showing the
    // same thumbnail cost one transfer, not two). When the last waiter cancels, the
    // underlying CurlFetcher is cancelled too — that is what stops an abandoned screen's
    // thumbnails from occupying the 2-wide curl gate ahead of the screen you just opened.
    //
    // Touched ONLY on the main thread (same invariant as DownloadManager.inFlight), so no
    // lock: every entry/exit below is either already on main or hops to main first.

    fileprivate final class ImageRequest {
        var token: CurlFetcher?
        var waiters: [Int: (UIImage) -> Void] = [:]
        var nextWaiterId = 0
        // Set on main when the last waiter withdraws, read on decodeQueue — the one field
        // here touched off main, hence the lock.
        private var _cancelled = false
        var cancelled: Bool {
            get { objc_sync_enter(self); defer { objc_sync_exit(self) }; return _cancelled }
            set { objc_sync_enter(self); _cancelled = newValue; objc_sync_exit(self) }
        }
    }

    // Opaque handle a caller keeps so it can withdraw its own waiter later. It names the
    // request it joined, not just the URL: a later request for the same URL numbers its
    // waiters from 0 again, so a ticket left over from a finished one (a failed load never
    // clears it) used to withdraw some other view's waiter.
    final class ImageRequestTicket {
        fileprivate let url: String
        fileprivate let waiterId: Int
        fileprivate weak var request: ImageRequest?
        fileprivate init(url: String, waiterId: Int, request: ImageRequest) {
            self.url = url; self.waiterId = waiterId; self.request = request
        }
    }

    private static var inflight: [String: ImageRequest] = [:]

    // MARK: - Instance state
    private var ticket: ImageRequestTicket?

    // MARK: - Load into self

    func load(url: String) {
        // Drop any previous request on THIS view first — cell reuse, or the mini bar
        // switching tracks, would otherwise leave the old transfer running.
        cancel()
        if let cached = AsyncImageView.cache.object(forKey: url as NSString) {
            image = cached; return
        }
        image = nil
        ticket = AsyncImageView.fetch(url: url) { [weak self] img in
            guard let self = self else { return }
            self.ticket = nil
            self.image = img
        }
    }

    func cancel() {
        AsyncImageView.cancel(ticket)
        ticket = nil
    }

    // Views that are simply thrown away (VideoPlayerVC rebuilds its related rows from
    // scratch on every relayout) never get a cancel() call. The registry only holds a
    // [weak self] closure, so it does not retain the view and this always fires.
    deinit { AsyncImageView.cancel(ticket) }

    // MARK: - Load for table/collection cell
    // For cells whose image view isn't an AsyncImageView (UITableViewCell.imageView).
    // Store the returned ticket on the cell and cancel it in prepareForReuse.

    @discardableResult
    static func loadCell(url: String, completion: @escaping (UIImage) -> Void) -> ImageRequestTicket? {
        if let cached = cache.object(forKey: url as NSString) { completion(cached); return nil }
        return fetch(url: url, completion: completion)
    }

    static func cancel(_ ticket: ImageRequestTicket?) {
        guard let t = ticket, let req = t.request, inflight[t.url] === req else { return }
        req.waiters.removeValue(forKey: t.waiterId)
        guard req.waiters.isEmpty else { return }   // another view still wants this image
        // Torn down on the next turn of the main queue, not now. A reloadData cancels every
        // visible row in prepareForReuse, and the same rows ask for the same URLs again moments
        // later in the same layout pass: tearing down at once threw away each request's place
        // in the 2-wide curl queue, so every progressive Home reload sent the thumbnails on
        // screen to the back of it again (and one already downloading was fetched twice).
        // Asked for again before this runs, the request has a waiter and simply carries on.
        AppQueue.main.async {
            guard req.waiters.isEmpty, inflight[t.url] === req else { return }
            req.cancelled = true
            req.token?.cancel()
            inflight.removeValue(forKey: t.url)
        }
    }

    // MARK: - Shared pipeline: disk → network → decode → cache

    private static func fetch(url: String, completion: @escaping (UIImage) -> Void) -> ImageRequestTicket? {
        // Join the pipeline already running for this URL.
        if let existing = inflight[url] {
            let id = existing.nextWaiterId
            existing.nextWaiterId += 1
            existing.waiters[id] = completion
            return ImageRequestTicket(url: url, waiterId: id, request: existing)
        }

        // Register BEFORE hopping to decodeQueue, otherwise two cells asking for the same
        // URL in the same run loop pass both miss and both open a socket.
        let req = ImageRequest()
        req.waiters[0] = completion
        req.nextWaiterId = 1
        inflight[url] = req

        let path = diskPath(for: url)
        decodeQueue.async {
            // Rows scrolled past in a fling queue their reads here faster than they run; one
            // whose view has since let go is skipped rather than read, decoded and cached ahead
            // of the rows now on screen. (Its entry left `inflight` when it was cancelled.)
            if req.cancelled { return }
            // A request for the same URL queued just ahead may already have decoded it.
            if let img = cache.object(forKey: url as NSString) {
                AppQueue.main.async { finish(req, url: url, image: img) }
                return
            }
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let img = safeDecode(data) {
                cache.setObject(img, forKey: url as NSString, cost: bitmapCost(img))
                AppQueue.main.async { finish(req, url: url, image: img) }
                return
            }
            AppQueue.main.async {
                // Cancelled while the disk read was queued → don't open a socket at all.
                guard inflight[url] === req else { return }
                req.token = CurlFetcher.fetchData(url: url, timeout: 15) { data in
                    guard let data = data else { finish(req, url: url, image: nil); return }
                    decodeQueue.async {
                        let img = safeDecode(data)
                        if let img = img {
                            try? data.write(to: URL(fileURLWithPath: path), options: .atomicWrite)
                            cache.setObject(img, forKey: url as NSString, cost: bitmapCost(img))
                        }
                        // Every exit path lands here, including a decode failure —
                        // otherwise the URL stays stuck in `inflight` forever and later
                        // requests for it join a pipeline that will never complete.
                        AppQueue.main.async { finish(req, url: url, image: img) }
                    }
                }
            }
        }
        return ImageRequestTicket(url: url, waiterId: 0, request: req)
    }

    // Identity check: cancel-then-re-request for the same URL puts a NEW ImageRequest in
    // the table. Only the current owner may clear the entry or it would strand the new
    // request's waiters.
    private static func finish(_ req: ImageRequest, url: String, image: UIImage?) {
        guard inflight[url] === req else { return }
        inflight.removeValue(forKey: url)
        guard let image = image else { return }
        for (_, waiter) in req.waiters { waiter(image) }
    }

    // MARK: - Decode helpers

    private static func safeDecode(_ data: Data) -> UIImage? {
        guard let raw = UIImage(data: data) else { return nil }
        guard raw.size.width > 0, raw.size.height > 0 else { return nil }
        return downscaleAndDecode(raw)
    }

    // Decoded at the source's own pixels, never more, with the long side capped at maxPx: 320
    // is the width of the mqdefault frame every list thumbnail is, so those decode 1:1 and only
    // larger sources, such as channel avatars, come out smaller. Drawn at scale 1 — the cap
    // used to be applied in points with the screen's scale, which turned a 320x180 thumbnail
    // into a 600x336 bitmap: 3.5x the memory for no detail the source didn't have.
    private static func downscaleAndDecode(_ image: UIImage, maxPx: CGFloat = 320) -> UIImage {
        let w = image.size.width * image.scale, h = image.size.height * image.scale
        let ratio: CGFloat = (w > maxPx || h > maxPx) ? min(maxPx / w, maxPx / h) : 1.0
        let target = CGSize(width: floor(w * ratio), height: floor(h * ratio))
        guard target.width > 0, target.height > 0 else { return image }
        UIGraphicsBeginImageContextWithOptions(target, false, 1)
        image.draw(in: CGRect(origin: .zero, size: target))
        let result = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return result
    }

    private static func bitmapCost(_ image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale) * 4
    }

    // MARK: - Cache size (Settings display)
    // Total bytes of every thumbnail currently on disk. diskCacheDir is private, so this
    // helper lives inside the class to expose the size without leaking the path.
    static func diskCacheSize() -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: diskCacheDir) else { return 0 }
        var total = 0
        for f in files {
            let p = (diskCacheDir as NSString).appendingPathComponent(f)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: p),
               let bytes = (attrs[.size] as? NSNumber)?.intValue {
                total += bytes
            }
        }
        return total
    }

    // MARK: - Cache purge (Settings → Reset Cache)
    // Clears decoded images from memory and every cached thumbnail on disk.
    static func purgeCache() {
        cache.removeAllObjects()
        if let files = try? FileManager.default.contentsOfDirectory(atPath: diskCacheDir) {
            for f in files {
                try? FileManager.default.removeItem(atPath: (diskCacheDir as NSString).appendingPathComponent(f))
            }
        }
    }
}
