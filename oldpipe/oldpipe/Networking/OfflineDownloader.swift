import Foundation

// MARK: - OfflineDownloader
//
// Offline counterpart of StreamProxy's HLS transmux path.
//
// Anonymous innertube serves >360p only as SEPARATE video-only + audio-only DASH fMP4 streams,
// so there is no single URL to copy to disk the way a muxed 360p download does. The live player
// solves that by transmuxing one segment at a time on demand (StreamProxy.serveHLS). This class
// runs the EXACT SAME pipeline, just eagerly and to disk: every segment is fetched, muxed once
// and written to downloads/<id>/ as a self-contained local HLS VOD bundle —
//
//     downloads/<id>/index.m3u8          (HLSTransmuxer.playlist, verbatim)
//     downloads/<id>/seg0.ts, seg1.ts... (HLSTransmuxer.muxSegment output)
//
// which StreamProxy.offlineHLSURL then serves straight back to AVPlayer with no network at all.
// Nothing here knows how to mux: the risky half is HLSTransmuxer, already validated by ffmpeg
// and on-device for live playback.
//
// Three properties fall out of working segment-by-segment, and they are the reason this shape
// was chosen over writing a single .mp4:
//   * Resume is free — a segment already on disk is skipped, so a failed or cancelled download
//     picks up where it stopped instead of restarting a 90MB transfer.
//   * Memory stays flat — one ~1.4MB segment is in RAM at a time, which an iPhone 4S can take.
//   * Progress is exact — segments done / segments total, not a byte estimate.

final class OfflineDownloader {

    // ONE serial queue for every offline download, created once (a DispatchQueue(label:) per
    // call spawns an OS thread each time — the 4S thread budget rule). Serial is also what we
    // want semantically: CurlFetcher.rangeFetch closes the feed turnstile for each transfer, so
    // two concurrent downloads would spend their time fighting over it. Extra requests queue.
    private static let queue = AppQueue(label: "com.oldpipe.offline")

    // How many times a stalled download may re-resolve its URLs before giving up (see refresh).
    private static let maxRefreshes = 3

    // Ids the user asked to stop. Written on the main thread, read from the download queue and
    // from inside libcurl's progress callback, so every access takes the lock.
    private static var cancelledIds: Set<String> = []

    // MARK: - Public API

    // Walk every segment of `videoStream` + `audioStream` into downloads/<id>/.
    // `progress` (0..1) and `completion` both fire on the main thread. Already-downloaded
    // segments are skipped, so calling this again after a failure resumes.
    static func start(video: Video, videoStream: VideoStream, audioStream: VideoStream,
                      captions: [CaptionTrack] = [],
                      progress: @escaping (Float) -> Void,
                      completion: @escaping (Bool) -> Void) {
        clearCancel(video.id)
        queue.async {
            saveCaptions(captions, for: video.id)
            let ok = run(video: video, vStream: videoStream, aStream: audioStream, progress: progress)
            AppQueue.main.async {
                clearCancel(video.id)
                completion(ok)
            }
        }
    }

    // Audio-only download (itag 140): the same walk with no video track. The result is still an
    // HLS bundle rather than a copied .m4a, because the DASH audio stream is FRAGMENTED MP4 and
    // iOS 6 AVPlayer cannot play fMP4 at all — and because a playlist gives an exact duration,
    // which a raw ADTS .aac would not (the scrubber and the premature-EOF watchdog need it).
    static func startAudio(video: Video, audioStream: VideoStream,
                           captions: [CaptionTrack] = [],
                           progress: @escaping (Float) -> Void,
                           completion: @escaping (Bool) -> Void) {
        clearCancel(video.id)
        queue.async {
            saveCaptions(captions, for: video.id)
            let ok = runAudio(video: video, aStream: audioStream, progress: progress)
            AppQueue.main.async {
                clearCancel(video.id)
                completion(ok)
            }
        }
    }

    // Save captions for a download whose media transfer does NOT run on this queue (the
    // progressive path hands its copy to CurlFetcher). Independent files, so it can run
    // alongside rather than blocking the transfer.
    static func saveCaptionsOnly(_ captions: [CaptionTrack], for videoId: String) {
        guard !captions.isEmpty else { return }
        queue.async { saveCaptions(captions, for: videoId) }
    }

    // Fetched FIRST, before any media: a 1080p download can run for hours, and every caption
    // baseUrl is signed with a ~6h expiry. Failure here never fails the download.
    private static func saveCaptions(_ captions: [CaptionTrack], for videoId: String) {
        guard !captions.isEmpty else { return }
        Captions.saveOfflineSync(captions, for: videoId, shouldAbort: { isCancelled(videoId) })
    }

    // Stop a download. The in-flight ranged GET aborts within ~1s (libcurl progress callback)
    // and the segment loop exits at the next boundary; the completion still fires, with false.
    // Segments already written stay on disk so a later retry resumes from there.
    static func cancel(_ videoId: String) {
        objc_sync_enter(self); cancelledIds.insert(videoId); objc_sync_exit(self)
    }

    private static func isCancelled(_ videoId: String) -> Bool {
        objc_sync_enter(self); let c = cancelledIds.contains(videoId); objc_sync_exit(self)
        return c
    }

    private static func clearCancel(_ videoId: String) {
        objc_sync_enter(self); cancelledIds.remove(videoId); objc_sync_exit(self)
    }

    // MARK: - The download itself (runs on `queue`)

    private static func run(video: Video, vStream: VideoStream, aStream: VideoStream,
                            progress: @escaping (Float) -> Void) -> Bool {
        let dir = DownloadManager.bundleDir(for: video.id)
        guard ensureDir(dir) else {
            DebugLog.log("Offline", "id=\(video.id) FAILED — cannot create \(dir)")
            return false
        }

        var vURL = vStream.url
        var aURL = aStream.url

        // Both streams' init+sidx heads (bytes 0...indexEnd) — the segment map for the whole
        // download. One refresh attempt here too: a url minted minutes ago can already be stale.
        var parsed = heads(vURL: vURL, aURL: aURL, vEnd: vStream.indexEnd, aEnd: aStream.indexEnd,
                           videoId: video.id)
        if parsed == nil, let r = refresh(video.id, vItag: vStream.itag, aItag: aStream.itag) {
            vURL = r.v.url; aURL = r.a.url
            parsed = heads(vURL: vURL, aURL: aURL, vEnd: r.v.indexEnd, aEnd: r.a.indexEnd,
                           videoId: video.id)
        }
        guard let info = parsed else {
            DebugLog.log("Offline", "id=\(video.id) FAILED — could not parse stream heads")
            return false
        }

        let total = info.segmentCount
        guard total > 0 else {
            DebugLog.log("Offline", "id=\(video.id) FAILED — sidx has no segments")
            return false
        }

        // The playlist is pure arithmetic over the sidx (durations + seg<i>.ts names), identical
        // to what the live path serves, so it can be written up front and never revisited.
        let m3u8 = HLSTransmuxer.playlist(info)
        guard write(Data(m3u8.utf8), to: (dir as NSString).appendingPathComponent("index.m3u8")) else {
            DebugLog.log("Offline", "id=\(video.id) FAILED — cannot write playlist")
            return false
        }

        DebugLog.log("Offline", "id=\(video.id) start itag=\(vStream.itag) segments=\(total)")

        var refreshesLeft = maxRefreshes
        var seg = 0
        var done = 0
        while seg < total {
            if isCancelled(video.id) {
                DebugLog.log("Offline", "id=\(video.id) cancelled at seg \(seg)/\(total)")
                return false
            }

            let segPath = (dir as NSString).appendingPathComponent("seg\(seg).ts")
            // Resume: a segment already written is a segment not fetched again.
            if fileSize(segPath) > 0 {
                seg += 1; done += 1
                report(done, total, progress)
                continue
            }

            guard let vr = HLSTransmuxer.videoRange(info, seg: seg),
                  let ar = HLSTransmuxer.audioRange(info, seg: seg) else {
                DebugLog.log("Offline", "id=\(video.id) FAILED — no byte range for seg \(seg)")
                return false
            }

            let abort: () -> Bool = { isCancelled(video.id) }
            let vBlob = CurlFetcher.rangeFetch(url: vURL, start: vr.start, end: vr.end, shouldAbort: abort)
            let aBlob = vBlob == nil ? nil
                : CurlFetcher.rangeFetch(url: aURL, start: ar.start, end: ar.end, shouldAbort: abort)

            guard let v = vBlob, let a = aBlob else {
                if isCancelled(video.id) { return false }
                // googlevideo urls carry an `expire` (~6h) and can also start refusing ranges
                // mid-download. Re-resolve and retry THIS segment rather than failing the lot.
                guard refreshesLeft > 0,
                      let r = refresh(video.id, vItag: vStream.itag, aItag: aStream.itag) else {
                    DebugLog.log("Offline", "id=\(video.id) FAILED — seg \(seg) unfetchable")
                    return false
                }
                refreshesLeft -= 1
                vURL = r.v.url; aURL = r.a.url
                DebugLog.log("Offline", "id=\(video.id) refreshed urls at seg \(seg) (\(refreshesLeft) left)")
                continue    // same seg, new urls
            }

            guard let ts = HLSTransmuxer.muxSegment(info, seg: seg, videoBlob: v, audioBlob: a) else {
                DebugLog.log("Offline", "id=\(video.id) FAILED — mux failed on seg \(seg)")
                return false
            }
            guard write(ts, to: segPath) else {
                DebugLog.log("Offline", "id=\(video.id) FAILED — cannot write seg \(seg) (disk full?)")
                return false
            }

            seg += 1; done += 1
            report(done, total, progress)
        }

        DebugLog.log("Offline", "id=\(video.id) COMPLETE \(total) segments")
        return true
    }

    // Audio-only twin of run(). One segment per audio fragment, so there is no video range to
    // fetch and no window to trim — see HLSTransmuxer.muxAudioSegment.
    private static func runAudio(video: Video, aStream: VideoStream,
                                 progress: @escaping (Float) -> Void) -> Bool {
        let dir = DownloadManager.bundleDir(for: video.id)
        guard ensureDir(dir) else {
            DebugLog.log("Offline", "id=\(video.id) FAILED — cannot create \(dir)")
            return false
        }

        var aURL = aStream.url
        var parsed = audioHead(aURL, end: aStream.indexEnd, videoId: video.id)
        if parsed == nil, let a = refreshAudio(video.id, aItag: aStream.itag) {
            aURL = a.url
            parsed = audioHead(aURL, end: a.indexEnd, videoId: video.id)
        }
        guard let info = parsed else {
            DebugLog.log("Offline", "id=\(video.id) FAILED — could not parse audio head")
            return false
        }

        let total = info.segmentCount
        guard total > 0 else {
            DebugLog.log("Offline", "id=\(video.id) FAILED — audio sidx has no segments")
            return false
        }

        let m3u8 = HLSTransmuxer.playlist(info)
        guard write(Data(m3u8.utf8), to: (dir as NSString).appendingPathComponent("index.m3u8")) else {
            DebugLog.log("Offline", "id=\(video.id) FAILED — cannot write audio playlist")
            return false
        }

        DebugLog.log("Offline", "id=\(video.id) start AUDIO itag=\(aStream.itag) segments=\(total)")

        var refreshesLeft = maxRefreshes
        var seg = 0
        var done = 0
        while seg < total {
            if isCancelled(video.id) {
                DebugLog.log("Offline", "id=\(video.id) audio cancelled at seg \(seg)/\(total)")
                return false
            }

            let segPath = (dir as NSString).appendingPathComponent("seg\(seg).ts")
            if fileSize(segPath) > 0 {
                seg += 1; done += 1
                report(done, total, progress)
                continue
            }

            guard let ar = HLSTransmuxer.audioRange(info, seg: seg) else {
                DebugLog.log("Offline", "id=\(video.id) FAILED — no audio range for seg \(seg)")
                return false
            }
            guard let blob = CurlFetcher.rangeFetch(url: aURL, start: ar.start, end: ar.end,
                                                    shouldAbort: { isCancelled(video.id) }) else {
                if isCancelled(video.id) { return false }
                guard refreshesLeft > 0, let a = refreshAudio(video.id, aItag: aStream.itag) else {
                    DebugLog.log("Offline", "id=\(video.id) FAILED — audio seg \(seg) unfetchable")
                    return false
                }
                refreshesLeft -= 1
                aURL = a.url
                DebugLog.log("Offline", "id=\(video.id) refreshed audio url at seg \(seg) (\(refreshesLeft) left)")
                continue
            }

            guard let ts = HLSTransmuxer.muxAudioSegment(info, seg: seg, audioBlob: blob) else {
                DebugLog.log("Offline", "id=\(video.id) FAILED — audio mux failed on seg \(seg)")
                return false
            }
            guard write(ts, to: segPath) else {
                DebugLog.log("Offline", "id=\(video.id) FAILED — cannot write audio seg \(seg) (disk full?)")
                return false
            }

            seg += 1; done += 1
            report(done, total, progress)
        }

        DebugLog.log("Offline", "id=\(video.id) AUDIO COMPLETE \(total) segments")
        return true
    }

    // MARK: - Helpers

    private static func audioHead(_ aURL: String, end: Int64, videoId: String) -> HLSStreamInfo? {
        guard end > 0,
              let head = CurlFetcher.rangeFetch(url: aURL, start: 0, end: end,
                                                shouldAbort: { isCancelled(videoId) })
        else { return nil }
        return HLSTransmuxer.parseAudioOnly(audioHead: head)
    }

    // Same contract as refresh(), for the single-stream case.
    private static func refreshAudio(_ videoId: String, aItag: Int) -> VideoStream? {
        let box = RefreshBox()
        let sem = AppSemaphore(value: 0)
        AppQueue.main.async {
            YoutubeAPI.getStreams(videoId: videoId) { streams, _, _, _, _ in
                if let a = streams.first(where: { $0.itag == aItag && $0.indexEnd > 0 }) {
                    box.set((a, a))
                }
                sem.signal()
            }
        }
        guard sem.waitFor(seconds: 90) else { return nil }
        return box.get()?.v
    }

    private static func heads(vURL: String, aURL: String, vEnd: Int64, aEnd: Int64,
                              videoId: String) -> HLSStreamInfo? {
        let abort: () -> Bool = { isCancelled(videoId) }
        guard vEnd > 0, aEnd > 0,
              let vHead = CurlFetcher.rangeFetch(url: vURL, start: 0, end: vEnd, shouldAbort: abort),
              let aHead = CurlFetcher.rangeFetch(url: aURL, start: 0, end: aEnd, shouldAbort: abort)
        else { return nil }
        return HLSTransmuxer.parse(videoHead: vHead, audioHead: aHead)
    }

    // Re-resolve the SAME itags through innertube. The already-parsed HLSStreamInfo stays valid
    // across this: the sidx describes the layout of the itag's file, which is identical whichever
    // url serves it — only the host and the signed query change. So a refresh swaps the urls and
    // the segment loop carries on with the byte offsets it already has.
    //
    // Blocks the download queue on the (main-thread) innertube completion. Safe because this
    // never runs on main: start() always hops to `queue` first.
    private static func refresh(_ videoId: String, vItag: Int, aItag: Int) -> (v: VideoStream, a: VideoStream)? {
        let box = RefreshBox()
        let sem = AppSemaphore(value: 0)
        AppQueue.main.async {
            YoutubeAPI.getStreams(videoId: videoId) { streams, _, _, _, _ in
                if let v = streams.first(where: { $0.itag == vItag && $0.indexEnd > 0 }),
                   let a = streams.first(where: { $0.itag == aItag && $0.indexEnd > 0 }) {
                    box.set((v, a))
                }
                sem.signal()
            }
        }
        // A timeout must not leave the completion writing into something we're reading, hence
        // the locked box rather than a captured var.
        guard sem.waitFor(seconds: 90) else { return nil }
        return box.get()
    }

    private static func report(_ done: Int, _ total: Int, _ progress: @escaping (Float) -> Void) {
        let p = Float(done) / Float(total)
        AppQueue.main.async { progress(p) }
    }

    private static func ensureDir(_ dir: String) -> Bool {
        if FileManager.default.fileExists(atPath: dir) { return true }
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                    attributes: nil)
            return true
        } catch { return false }
    }

    // Write via a .part file + rename so an interrupted write can never leave a short segment
    // that the resume check (size > 0) would mistake for a finished one.
    private static func write(_ data: Data, to path: String) -> Bool {
        let tmp = path + ".part"
        guard (data as NSData).write(toFile: tmp, atomically: true) else { return false }
        try? FileManager.default.removeItem(atPath: path)
        do { try FileManager.default.moveItem(atPath: tmp, toPath: path) } catch { return false }
        return true
    }

    // NSNumber-boxed read: a direct `as? Int64` returns nil on the 5.1.5 runtime shipped for iOS 6.
    private static func fileSize(_ path: String) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let n = (attrs[.size] as? NSNumber)?.int64Value else { return 0 }
        return n
    }
}

// Lock-guarded hand-off for refresh()'s cross-thread result.
private final class RefreshBox {
    private let lock = NSLock()
    private var value: (v: VideoStream, a: VideoStream)?
    func set(_ v: (VideoStream, VideoStream)) { lock.lock(); value = v; lock.unlock() }
    func get() -> (v: VideoStream, a: VideoStream)? { lock.lock(); defer { lock.unlock() }; return value }
}
