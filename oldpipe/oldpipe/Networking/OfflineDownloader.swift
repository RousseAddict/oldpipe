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
//   * Memory stays flat — at most two ~1.4MB segments are in RAM at a time (the one being
//     muxed and the one being read ahead of it), which an iPhone 4S can take.
//   * Progress is exact — segments done / segments total, not a byte estimate.

// Running totals for one download, logged per segment and summarised at the end. The
// question it exists to answer is `freshConns`: the app makes a NEW curl handle per
// segment and relies on the shared connection cache to hand back a live connection. If
// that is silently not happening, every segment pays a TCP+TLS handshake — 1-3s each on
// an iPhone 4S — and no amount of mux tuning would ever explain the result.
private final class DownloadStats {
    var fetchMs = 0, muxMs = 0, writeMs = 0
    var tlsMs = 0, freshConns = 0, requests = 0
    var bytes = 0
    // Wall-clock the SEGMENT LOOP actually sat blocked waiting for bytes, as opposed to
    // `fetchMs`, which is the time the transfers themselves took. They were the same number
    // until segments started being fetched a step ahead; now `fetchMs` measures the network
    // and `stallMs` measures what the network costs us. The gap between them is what the
    // pipeline recovered, so both are reported.
    var stallMs = 0
    let started = Date()

    func note(_ t: CurlTiming, bytes n: Int) {
        requests += 1
        fetchMs += t.ms
        bytes += n
        if !t.reusedConnection { freshConns += 1; tlsMs += t.tlsMs }
    }

    // Wall-clock, so it includes anything the three buckets miss.
    var totalMs: Int { return Int(Date().timeIntervalSince(started) * 1000) }

    func summary(_ label: String, segments: Int) -> String {
        let mb = Double(bytes) / 1048576.0
        let secs = max(Double(totalMs) / 1000.0, 0.001)
        return String(format:
            "%@ %d segs %.1f MB in %.1fs (%.2f MB/s) | fetch %dms (stall %dms) mux %dms write %dms | "
            + "%d reqs, %d FRESH CONNECTIONS (tls %dms)",
            label, segments, mb, secs, mb / secs, fetchMs, stallMs, muxMs, writeMs,
            requests, freshConns, tlsMs)
    }
}

final class OfflineDownloader {

    // ONE serial queue for every offline download, created once (a DispatchQueue(label:) per
    // call spawns an OS thread each time — the 4S thread budget rule). Serial is also what we
    // want semantically: two downloads at once would only split the same link and the A5's two
    // cores between them, and take turns at the feed turnstile that CurlFetcher.rangeFetch
    // closes until each fetch's first byte. Extra requests queue.
    private static let queue = AppQueue(label: "com.oldpipe.offline")

    // Reads one segment ahead while `queue` muxes the previous one — see PrefetchSlot. Serial,
    // and static for the same reason as every other queue in the app: one thread for the life
    // of the process, not one per call. Only ever one prefetch is outstanding, so a serial
    // queue is both sufficient and the cheapest thing that works.
    private static let prefetchQueue = AppQueue(label: "com.oldpipe.offline.prefetch")

    // How many times a stalled download may re-resolve its URLs before giving up (see refresh).
    private static let maxRefreshes = 3

    // Ids the user asked to stop. Written on the main thread, read from the download queue and
    // from inside libcurl's progress callback, so every access takes the lock.
    private static var cancelledIds: Set<String> = []

    // MARK: - Public API

    // Walk every segment of `videoStream` + `audioStream` into downloads/<id>/.
    // `progress` (0..1) and `completion` both fire on the main thread. Already-downloaded
    // segments are skipped, so calling this again after a failure resumes.
    //
    // `dir` + `cancelKey` let PhotoExporter download a bundle that is NOT a download: it lands
    // in its own temp dir, and cancelling it must not stop (or be stopped by) a real download
    // of the same video, so it is cancelled under its own key rather than the video id.
    static func start(video: Video, videoStream: VideoStream, audioStream: VideoStream,
                      captions: [CaptionTrack] = [],
                      into dir: String? = nil, cancelKey: String? = nil,
                      progress: @escaping (Float) -> Void,
                      completion: @escaping (Bool) -> Void) {
        let key = cancelKey ?? video.id
        let dir = dir ?? DownloadManager.bundleDir(for: video.id)
        clearCancel(key)
        queue.async {
            saveCaptions(captions, for: video.id)
            let ok = run(video: video, vStream: videoStream, aStream: audioStream,
                         dir: dir, key: key, progress: progress)
            AppQueue.main.async {
                // A cancel that landed after run() finished still counts: the caller has
                // already taken the download down (see cancel()).
                let cancelled = isCancelled(key)
                clearCancel(key)
                completion(ok && !cancelled)
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
                let cancelled = isCancelled(video.id)   // as in start()
                clearCancel(video.id)
                completion(ok && !cancelled)
            }
        }
    }

    // Save captions for a download whose media transfer does NOT run on this queue (the
    // progressive path hands its copy to CurlFetcher). Independent files, so it can run
    // alongside rather than blocking the transfer.
    static func saveCaptionsOnly(_ captions: [CaptionTrack], for videoId: String) {
        // Like start(): clear a cancel left over from an earlier download of this video, or
        // these captions would be skipped.
        clearCancel(videoId)
        guard !captions.isEmpty else { return }
        queue.async { saveCaptions(captions, for: videoId) }
    }

    // Fetched FIRST, before any media: a 1080p download can run for hours, and every caption
    // baseUrl is signed with a ~6h expiry. Failure here never fails the download.
    private static func saveCaptions(_ captions: [CaptionTrack], for videoId: String) {
        guard !captions.isEmpty else { return }
        // Bracketed with its own start line: captions are fetched BEFORE the media, so any
        // time spent here is time the user sees before the progress counter starts moving.
        let t0 = Date()
        DebugLog.log("Offline", "id=\(videoId) fetching \(captions.count) caption track(s)...")
        let n = Captions.saveOfflineSync(captions, for: videoId, shouldAbort: { isCancelled(videoId) })
        DebugLog.log("Offline", "id=\(videoId) captions done \(n)/\(captions.count) in "
            + "\(Int(Date().timeIntervalSince(t0) * 1000))ms")
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

    // `key` is what cancel() was called with — the video id, except for a Photos-only bundle.
    private static func run(video: Video, vStream: VideoStream, aStream: VideoStream,
                            dir: String, key: String,
                            progress: @escaping (Float) -> Void) -> Bool {
        guard ensureDir(dir) else {
            DebugLog.log("Offline", "id=\(video.id) FAILED — cannot create \(dir)")
            return false
        }

        var vURL = vStream.url
        var aURL = aStream.url

        // Both streams' init+sidx heads (bytes 0...indexEnd) — the segment map for the whole
        // download. One refresh attempt here too: a url minted minutes ago can already be stale.
        var parsed = heads(vURL: vURL, aURL: aURL, vEnd: vStream.indexEnd, aEnd: aStream.indexEnd,
                           key: key)
        if parsed == nil, let r = refresh(video.id, vItag: vStream.itag, aItag: aStream.itag) {
            vURL = r.v.url; aURL = r.a.url
            parsed = heads(vURL: vURL, aURL: aURL, vEnd: r.v.indexEnd, aEnd: r.a.indexEnd,
                           key: key)
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

        let stats = DownloadStats()
        var refreshesLeft = maxRefreshes
        var seg = 0
        var done = 0
        // The segment being fetched ahead while this loop muxes the previous one, if any.
        // The defer covers every exit — failure, cancellation and success alike — so a
        // prefetch can never outlive the download that started it.
        var pending: PrefetchSlot?
        defer { pending?.abandonAndDrain() }
        while seg < total {
            if isCancelled(key) {
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

            let abort: () -> Bool = { isCancelled(key) }

            // Bytes for this segment: already in hand if the previous iteration read ahead to
            // it, otherwise fetched right here. A prefetch for some OTHER segment can only
            // exist if the loop doubled back after refreshing the urls, in which case it was
            // fetched from urls we no longer trust and is thrown away.
            let stall0 = Date()
            let slot: PrefetchSlot
            if let p = pending, p.seg == seg {
                slot = p
            } else {
                pending?.abandonAndDrain()
                slot = PrefetchSlot(seg: seg)
                slot.fill(vURL: vURL, vr: vr, aURL: aURL, ar: ar, abort: abort)
            }
            pending = nil
            let got = slot.waitResult()
            // Wall-clock actually spent blocked. ~0 when the read-ahead landed in time, which
            // is the whole point; the transfers' own duration is tracked separately in `note`.
            let stallMs = Int(Date().timeIntervalSince(stall0) * 1000)
            stats.stallMs += stallMs
            let vTime = slot.vTiming, aTime = slot.aTiming

            guard let v = got.v, let a = got.a else {
                if isCancelled(key) { return false }
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

            // Start the NEXT segment downloading before muxing this one, so the network runs
            // during the mux+write below instead of waiting for it to finish.
            if seg + 1 < total, !isCancelled(key),
               fileSize((dir as NSString).appendingPathComponent("seg\(seg + 1).ts")) == 0,
               let nvr = HLSTransmuxer.videoRange(info, seg: seg + 1),
               let nar = HLSTransmuxer.audioRange(info, seg: seg + 1) {
                let next = PrefetchSlot(seg: seg + 1)
                // Copy the urls into lets. They are `var`s that the refresh path rewrites, and
                // a closure captures the VARIABLE, not its current value — so without this the
                // prefetch could silently change urls mid-flight.
                let nvURL = vURL, naURL = aURL
                pending = next
                prefetchQueue.async {
                    next.fill(vURL: nvURL, vr: nvr, aURL: naURL, ar: nar, abort: abort)
                }
            }

            let mux0 = Date()
            guard let ts = HLSTransmuxer.muxSegment(info, seg: seg, videoBlob: v, audioBlob: a) else {
                DebugLog.log("Offline", "id=\(video.id) FAILED — mux failed on seg \(seg)")
                return false
            }
            let muxMs = Int(Date().timeIntervalSince(mux0) * 1000)

            let write0 = Date()
            guard write(ts, to: segPath) else {
                DebugLog.log("Offline", "id=\(video.id) FAILED — cannot write seg \(seg) (disk full?)")
                return false
            }
            let writeMs = Int(Date().timeIntervalSince(write0) * 1000)

            stats.note(vTime, bytes: v.count)
            stats.note(aTime, bytes: a.count)
            stats.muxMs += muxMs
            stats.writeMs += writeMs
            DebugLog.log("Offline", "seg \(seg)/\(total) stall=\(stallMs)ms "
                + "(v \(vTime.ms)ms\(vTime.reusedConnection ? "" : " FRESH tls \(vTime.tlsMs)ms"), "
                + "a \(aTime.ms)ms\(aTime.reusedConnection ? "" : " FRESH tls \(aTime.tlsMs)ms")) "
                + "mux=\(muxMs)ms write=\(writeMs)ms")

            seg += 1; done += 1
            report(done, total, progress)
        }

        DebugLog.log("Offline", stats.summary("id=\(video.id) COMPLETE", segments: total))
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

        let stats = DownloadStats()
        var refreshesLeft = maxRefreshes
        var seg = 0
        var done = 0
        // Read-ahead, exactly as in run() — see PrefetchSlot.
        var pending: PrefetchSlot?
        defer { pending?.abandonAndDrain() }
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

            let abort: () -> Bool = { isCancelled(video.id) }
            let stall0 = Date()
            let slot: PrefetchSlot
            if let p = pending, p.seg == seg {
                slot = p
            } else {
                pending?.abandonAndDrain()
                slot = PrefetchSlot(seg: seg)
                slot.fill(vURL: nil, vr: nil, aURL: aURL, ar: ar, abort: abort)
            }
            pending = nil
            let fetched = slot.waitResult().a
            let stallMs = Int(Date().timeIntervalSince(stall0) * 1000)
            stats.stallMs += stallMs
            let aTime = slot.aTiming

            guard let blob = fetched else {
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

            // Fetch the next segment while this one is muxed and written.
            if seg + 1 < total, !isCancelled(video.id),
               fileSize((dir as NSString).appendingPathComponent("seg\(seg + 1).ts")) == 0,
               let nar = HLSTransmuxer.audioRange(info, seg: seg + 1) {
                let next = PrefetchSlot(seg: seg + 1)
                let naURL = aURL        // copy: `aURL` is a var the refresh path rewrites
                pending = next
                prefetchQueue.async {
                    next.fill(vURL: nil, vr: nil, aURL: naURL, ar: nar, abort: abort)
                }
            }

            let mux0 = Date()
            guard let ts = HLSTransmuxer.muxAudioSegment(info, seg: seg, audioBlob: blob) else {
                DebugLog.log("Offline", "id=\(video.id) FAILED — audio mux failed on seg \(seg)")
                return false
            }
            let muxMs = Int(Date().timeIntervalSince(mux0) * 1000)

            let write0 = Date()
            guard write(ts, to: segPath) else {
                DebugLog.log("Offline", "id=\(video.id) FAILED — cannot write audio seg \(seg) (disk full?)")
                return false
            }
            let writeMs = Int(Date().timeIntervalSince(write0) * 1000)

            stats.note(aTime, bytes: blob.count)
            stats.muxMs += muxMs
            stats.writeMs += writeMs
            DebugLog.log("Offline", "audio seg \(seg)/\(total) fetch=\(aTime.ms)ms stall=\(stallMs)ms"
                + "\(aTime.reusedConnection ? " (reused)" : " FRESH tls \(aTime.tlsMs)ms") "
                + "mux=\(muxMs)ms write=\(writeMs)ms")

            seg += 1; done += 1
            report(done, total, progress)
        }

        DebugLog.log("Offline", stats.summary("id=\(video.id) AUDIO COMPLETE", segments: total))
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
                              key: String) -> HLSStreamInfo? {
        let abort: () -> Bool = { isCancelled(key) }
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

// One segment's bytes, fetched a step ahead of the loop that will consume them.
//
// The loop used to fetch, mux and write strictly in turn, so the network sat idle for the
// whole mux+write and the CPU sat idle for the whole fetch. This runs the fetch for segment
// N+1 on its own thread while segment N is being muxed, which is worth roughly the smaller
// of the two per segment. Only ONE segment is ever read ahead: that is enough to keep both
// busy, and it caps peak memory at two segments rather than the whole file — the constraint
// that matters on a 4S.
//
// Fetching ahead does NOT mean fetching in parallel: two simultaneous fetches would only split
// the same link, so the win here comes entirely from overlapping the fetch with the MUX. By
// construction the loop never fetches while a prefetch is in flight.
//
// StreamProxy reads live HLS segments ahead with the same slot, one segment past the one
// AVPlayer last asked for.
final class PrefetchSlot {
    let seg: Int
    let vTiming = CurlTiming()
    let aTiming = CurlTiming()

    private let sem = AppSemaphore(value: 0)
    private let lock = NSLock()
    private var vData: Data?
    private var aData: Data?
    private var abandoned = false
    private var consumed = false

    init(seg: Int) { self.seg = seg }

    private var isAbandoned: Bool { lock.lock(); defer { lock.unlock() }; return abandoned }

    // Run the transfers and hand the result to whoever is waiting. Called either on the
    // prefetch queue (reading ahead) or inline on the download queue (nothing to read ahead
    // from — the first segment, or a retry after the urls were refreshed).
    //
    // `vURL`/`vr` are optional so the audio-only download can use the same slot: it has no
    // video track, and its consumer only ever reads `.a`.
    func fill(vURL: String?, vr: (start: Int64, end: Int64)?,
              aURL: String, ar: (start: Int64, end: Int64),
              abort: @escaping () -> Bool) {
        // Abandoning is how the loop reclaims a prefetch it can no longer use. libcurl polls
        // this from its progress callback, so an in-flight transfer unwinds within ~1s instead
        // of running to its 60s timeout.
        let stop: () -> Bool = { [weak self] in abort() || (self?.isAbandoned ?? true) }
        var v: Data?
        var vOK = true
        if let vURL = vURL, let vr = vr {
            v = CurlFetcher.rangeFetch(url: vURL, start: vr.start, end: vr.end,
                                       timing: vTiming, shouldAbort: stop)
            vOK = v != nil
        }
        // Same short-circuit as the serial version: no point fetching audio for a segment
        // whose video half already failed.
        let a = vOK ? CurlFetcher.rangeFetch(url: aURL, start: ar.start, end: ar.end,
                                             timing: aTiming, shouldAbort: stop)
                    : nil
        lock.lock(); vData = v; aData = a; lock.unlock()
        sem.signal()
    }

    // Block until fill() finishes. Exactly one consumer, so the single signal is enough.
    // Either half being nil means the fetch failed and the caller should take its refresh path.
    func waitResult() -> (v: Data?, a: Data?) {
        sem.wait()
        lock.lock(); defer { lock.unlock() }
        consumed = true
        return (vData, aData)
    }

    // Stop an in-flight prefetch the loop can no longer use (the urls were refreshed under it,
    // or the download is being torn down) and wait for it to actually finish, so its buffers
    // are released before the next segment allocates its own. A no-op once the result has
    // been taken, which keeps it safe to call from a blanket `defer`.
    func abandonAndDrain() {
        lock.lock()
        if consumed { lock.unlock(); return }
        abandoned = true
        lock.unlock()
        sem.wait()
        lock.lock(); consumed = true; vData = nil; aData = nil; lock.unlock()
    }

    // Stop a prefetch WITHOUT waiting for it: the transfer unwinds by itself within ~1s and its
    // bytes are freed with the slot. For StreamProxy, where AVPlayer has just asked for some
    // other segment (a seek) and must not be kept waiting while the wrong one winds down.
    // Nobody may wait on the slot afterwards.
    func abandon() {
        lock.lock(); abandoned = true; lock.unlock()
    }
}

// Lock-guarded hand-off for refresh()'s cross-thread result.
private final class RefreshBox {
    private let lock = NSLock()
    private var value: (v: VideoStream, a: VideoStream)?
    func set(_ v: (VideoStream, VideoStream)) { lock.lock(); value = v; lock.unlock() }
    func get() -> (v: VideoStream, a: VideoStream)? { lock.lock(); defer { lock.unlock() }; return value }
}
