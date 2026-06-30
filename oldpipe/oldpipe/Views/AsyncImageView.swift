import UIKit

class AsyncImageView: UIImageView {

    // MARK: - Memory cache
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 20
        c.totalCostLimit = 30 * 1024 * 1024  // 30 MB decoded bytes
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
    private static let decodeQueue = DispatchQueue(label: "com.oldpipe.imagedecode")

    // MARK: - Instance state
    private var loadingURL: String?

    // MARK: - Load into self

    func load(url: String) {
        if let cached = AsyncImageView.cache.object(forKey: url as NSString) {
            image = cached; return
        }
        loadingURL = url
        image = nil
        let capturedURL = url
        AsyncImageView.fetch(url: url) { [weak self] img in
            guard let self = self, self.loadingURL == capturedURL else { return }
            self.image = img
        }
    }

    func cancel() { loadingURL = nil }

    // MARK: - Load for table/collection cell

    static func loadCell(url: String, completion: @escaping (UIImage) -> Void) {
        if let cached = cache.object(forKey: url as NSString) { completion(cached); return }
        fetch(url: url, completion: completion)
    }

    // MARK: - Shared pipeline: disk → network → decode → cache

    private static func fetch(url: String, completion: @escaping (UIImage) -> Void) {
        let path = diskPath(for: url)
        decodeQueue.async {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let img = safeDecode(data) {
                cache.setObject(img, forKey: url as NSString, cost: bitmapCost(img))
                DispatchQueue.main.async { completion(img) }
                return
            }
            CurlFetcher.fetchData(url: url, timeout: 15) { data in
                guard let data = data else { return }
                AsyncImageView.decodeQueue.async {
                    guard let img = safeDecode(data) else { return }
                    try? data.write(to: URL(fileURLWithPath: path), options: .atomicWrite)
                    cache.setObject(img, forKey: url as NSString, cost: bitmapCost(img))
                    DispatchQueue.main.async { completion(img) }
                }
            }
        }
    }

    // MARK: - Decode helpers

    private static func safeDecode(_ data: Data) -> UIImage? {
        guard let raw = UIImage(data: data) else { return nil }
        guard raw.size.width > 0, raw.size.height > 0 else { return nil }
        return downscaleAndDecode(raw)
    }

    private static func downscaleAndDecode(_ image: UIImage, maxPx: CGFloat = 300) -> UIImage {
        let w = image.size.width, h = image.size.height
        let ratio: CGFloat = (w > maxPx || h > maxPx) ? min(maxPx / w, maxPx / h) : 1.0
        let target = CGSize(width: floor(w * ratio), height: floor(h * ratio))
        guard target.width > 0, target.height > 0 else { return image }
        UIGraphicsBeginImageContextWithOptions(target, false, UIScreen.main.scale)
        image.draw(in: CGRect(origin: .zero, size: target))
        let result = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return result
    }

    private static func bitmapCost(_ image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale) * 4
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
