import UIKit

// MARK: - AudioExporter
// "M4A file", from the Save to section of the Download picker (VideoPlayerVC).
//
// WHY NOT THE MUSIC APP: there is no public way to put a file into it. MPMediaLibrary is
// read-only on every iOS this app runs on, and the one write call that exists
// (addItem(withProductID:), iOS 9.3+) takes an Apple Music catalog id, not a local file. So
// this writes a real .m4a into Documents/ instead, where iTunes File Sharing exposes it: the
// user drags it out and adds it to their library themselves. The picker row says "M4A file"
// rather than "Music" for exactly that reason — nothing here lands in the Music app by itself.
//
// An audio download is an HLS bundle of seg<i>.ts (iOS 6 AVPlayer cannot play the fMP4 the
// adaptive audio stream actually ships as), so MP4Remuxer repackages it — the AAC frames are
// copied through untouched, nothing is re-encoded, and the title and channel go in as iTunes
// metadata so the file does not show up as a bare file name.
//
// Two ways in, by what is on disk:
//   downloaded      export(): the bundle on disk is repackaged in place.
//   not downloaded  downloadAndExport(): fetched into workDir, exported, deleted.
//                   DownloadManager never hears of it, so it shows in no Downloads row.
//
// Exports run one at a time on a serial queue and keep going after the user leaves the screen.
// Deliberately NOT modelled on PhotoExporter's full shape: there is no compatibility probe to
// run (no Photos to refuse a quality) and no progressive path (a muxed 360p file is a video).

final class AudioExporter {

    static let shared = AudioExporter()

    // Same static-serial-queue convention as OfflineDownloader: one thread, exports queue up.
    private static let queue = AppQueue(label: "com.oldpipe.audioexport")

    // Export-only downloads live here; the finished .m4a goes to Documents/ and nowhere else.
    private static let workDir: String =
        (NSTemporaryDirectory() as NSString).appendingPathComponent("audio-export")

    // Main-thread-only state, like DownloadManager.inFlight.
    private var status: [String: String] = [:]      // id -> "Waiting...", "Exporting 34%"...
    private var exported: [String: String] = [:]    // id -> file name, for the confirmation
    private var backgroundTasks: [String: UIBackgroundTaskIdentifier] = [:]
    private var ownsDownload: Set<String> = []      // running downloadAndExport(), not export()

    // Written on the main thread, read from the export queue, so every access takes the lock.
    private var cancelledIds: Set<String> = []

    // MARK: - State for the UI

    func isBusy(_ videoId: String) -> Bool { return status[videoId] != nil }

    func canStop(_ videoId: String) -> Bool {
        return status[videoId] != nil && !isCancelled(videoId)
    }

    // The file written this session, for the "saved as ..." confirmation.
    func exportedName(_ videoId: String) -> String? { return exported[videoId] }

    func statusText(_ videoId: String) -> String? { return status[videoId] }

    // Only a finished AUDIO download can be exported: a video download's bundle has a video
    // track, which does not belong in an .m4a.
    static func canExport(_ videoId: String) -> Bool {
        return DownloadManager.isDownloaded(videoId) && DownloadManager.isAudioOnly(videoId)
            && DownloadManager.kind(for: videoId) == .hls
    }

    // MARK: - Export a download already on disk

    func export(_ video: Video) {
        let id = video.id
        guard status[id] == nil, AudioExporter.canExport(id) else { return }
        // The .m4a and the bundle coexist. A TS bundle is about 40% bigger than the AAC it
        // carries, so the output is smaller than the input — asking for the input's size is
        // the safe over-estimate.
        guard hasRoom(for: DownloadManager.diskBytes(for: id)) else { return }
        begin(id)
        status[id] = "Waiting..."
        beginBackgroundTask(id)
        let bundle = DownloadManager.bundleDir(for: id)
        AudioExporter.queue.async {
            self.convert(id, video: video, bundle: bundle, ownsBundle: false)
        }
    }

    // MARK: - Download just to export

    // Fetch the audio into workDir, export it, delete the bundle.
    func downloadAndExport(_ video: Video, audioStream: VideoStream, estimatedBytes: Int64) {
        let id = video.id
        guard status[id] == nil else { return }
        guard hasRoom(for: estimatedBytes * 2) else { return }
        begin(id)
        try? FileManager.default.createDirectory(atPath: AudioExporter.workDir,
                                                 withIntermediateDirectories: true, attributes: nil)
        ownsDownload.insert(id)
        status[id] = "Waiting..."
        beginBackgroundTask(id)
        DebugLog.log("AudioExport", "id=\(id) downloading audio for export only")

        let bundle = AudioExporter.workPath("\(id)-bundle")
        // Never resume into a bundle left by an earlier attempt.
        try? FileManager.default.removeItem(atPath: bundle)
        OfflineDownloader.startAudio(video: video, audioStream: audioStream,
                                     into: bundle, cancelKey: AudioExporter.downloadKey(id),
                                     progress: { p in
            // The download is most of the wait; the repackaging after it gets the last 10%.
            self.setProgress(id, Int(p * 90))
        }) { ok in
            let stopped = self.isCancelled(id)
            if !ok || stopped {
                try? FileManager.default.removeItem(atPath: bundle)
                self.finish(id, failure: stopped ? nil : self.downloadFailedText)
                return
            }
            AudioExporter.queue.async {
                self.convert(id, video: video, bundle: bundle, ownsBundle: true)
            }
        }
    }

    // MARK: - Stop

    func cancel(_ videoId: String) {
        guard canStop(videoId) else { return }
        setCancelled(videoId, true)
        if ownsDownload.contains(videoId) {
            OfflineDownloader.cancel(AudioExporter.downloadKey(videoId))
        }
        status[videoId] = "Stopping..."
    }

    // DownloadManager.remove: an export of that download reads the files about to be deleted.
    // An export-only download reads none of them, so it carries on.
    func downloadRemoved(_ videoId: String) {
        if status[videoId] != nil, !ownsDownload.contains(videoId) { setCancelled(videoId, true) }
    }

    // MARK: - Repackaging (runs on `queue`)

    private func convert(_ id: String, video: Video, bundle: String, ownsBundle: Bool) {
        defer { if ownsBundle { try? FileManager.default.removeItem(atPath: bundle) } }
        let abort = { self.isCancelled(id) }
        if abort() { AppQueue.main.async { self.finish(id) }; return }

        // Pick the name before writing, so a clash is resolved against what is already there.
        let name = AudioExporter.uniqueName(for: video.title)
        let out = AudioExporter.documentsPath(name)
        let started = Date()
        let reason = MP4Remuxer.remux(bundleDir: bundle, outPath: out,
                                      audioOnly: true,
                                      title: video.title, artist: video.channelName,
                                      progress: { done, total in
            let pct = done * 100 / max(total, 1)
            AppQueue.main.async { self.setProgress(id, ownsBundle ? 90 + pct / 10 : pct) }
        }, shouldAbort: abort)
        let ms = Int(Date().timeIntervalSince(started) * 1000)

        if let reason = reason {
            DebugLog.log("AudioExport", "id=\(id) remux failed after \(ms)ms: \(reason)")
            AppQueue.main.async {
                self.finish(id, failure: reason == "cancelled" ? nil : self.convertFailedText)
            }
            return
        }
        let bytes = AudioExporter.fileSize(out)
        DebugLog.log("AudioExport", "id=\(id) wrote \(name) (\(bytes) bytes) in \(ms)ms")
        AppQueue.main.async {
            // Stopped while the last segment was being written: drop the file, export nothing.
            if self.isCancelled(id) {
                unlink(out)
                self.finish(id)
                return
            }
            self.exported[id] = name
            self.finish(id)
            self.alert("Saved", "\u{201C}\(name)\u{201D} is in oldpipe's Documents folder. "
                + "Connect the device to iTunes, open the Apps tab and look under File Sharing "
                + "to copy it off.")
        }
    }

    // MARK: - Naming

    // Documents/ itself, not a subfolder: iTunes File Sharing lists it directly, so the file
    // is one click away instead of behind a folder.
    private static func documentsPath(_ name: String) -> String {
        let dir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        return (dir as NSString).appendingPathComponent(name)
    }

    // A file name, not a path. Strips the separators and the characters that make a file
    // awkward to move between filesystems, and keeps it short enough to read in a list.
    // Hand-rolled rather than via CharacterSet: the trimming sets are old API, but this file
    // runs on iOS 5 too and the project has been bitten by iOS 7+ CharacterSet members before.
    static func safeName(_ title: String) -> String {
        var out = ""
        for ch in title {
            switch ch {
            case "/", ":", "\\", "\"", "*", "?", "<", ">", "|": out.append("-")
            case "\n", "\r", "\t": out.append(" ")
            default: out.append(ch)
            }
        }
        while out.hasPrefix(" ") || out.hasPrefix(".") { out.removeFirst() }
        while out.hasSuffix(" ") || out.hasSuffix(".") { out.removeLast() }
        if out.count > 80 {
            out = String(out.prefix(80))
            while out.hasSuffix(" ") { out.removeLast() }
        }
        return out.isEmpty ? "audio" : out
    }

    // "<title>.m4a", or "<title> 2.m4a" when that is taken — exporting twice must not
    // silently overwrite the first file.
    private static func uniqueName(for title: String) -> String {
        let base = safeName(title)
        var name = base + ".m4a"
        var n = 2
        while FileManager.default.fileExists(atPath: documentsPath(name)) && n < 1000 {
            name = "\(base) \(n).m4a"
            n += 1
        }
        return name
    }

    private static func fileSize(_ path: String) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let n = (attrs[.size] as? NSNumber)?.int64Value else { return 0 }
        return n
    }

    // MARK: - Helpers (main thread)

    private let convertFailedText = "Couldn't build an M4A file from this download."
    private let downloadFailedText = "The download didn't finish, so no file was saved."

    private func begin(_ id: String) {
        if status.isEmpty { try? FileManager.default.removeItem(atPath: AudioExporter.workDir) }
        setCancelled(id, false)
        exported[id] = nil
    }

    private func setProgress(_ id: String, _ pct: Int) {
        guard status[id] != nil, !isCancelled(id) else { return }
        status[id] = "Exporting \(pct)%"
    }

    private func finish(_ id: String, failure: String? = nil) {
        status[id] = nil
        ownsDownload.remove(id)
        setCancelled(id, false)
        if let t = backgroundTasks.removeValue(forKey: id) {
            UIApplication.shared.endBackgroundTask(t)
        }
        if let message = failure { alert("M4A File", message) }
    }

    private func beginBackgroundTask(_ id: String) {
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(expirationHandler: {
            self.cancel(id)
            UIApplication.shared.endBackgroundTask(task)
            if self.backgroundTasks[id] == task { self.backgroundTasks[id] = nil }
        })
        backgroundTasks[id] = task
    }

    // Same 50 MB headroom the download sheet keeps. 0 free = unknown, in which case the
    // export is not blocked on a number we couldn't read.
    private func hasRoom(for needed: Int64) -> Bool {
        let free = DownloadManager.freeDiskBytes()
        guard free > 0, needed + 50 * 1024 * 1024 > free else { return true }
        alert("Not Enough Space",
              String(format: "Saving an M4A needs about %.0f MB but only %.0f MB is free.",
                     Double(needed) / (1024.0 * 1024.0), Double(free) / (1024.0 * 1024.0)))
        return false
    }

    private func alert(_ title: String, _ message: String) {
        let a = UIAlertView()
        a.title = title
        a.message = message
        a.addButton(withTitle: "OK")
        a.cancelButtonIndex = 0
        a.show()
    }

    private static func workPath(_ name: String) -> String {
        return (workDir as NSString).appendingPathComponent(name)
    }

    // OfflineDownloader's cancel key for an export-only download: distinct from the video id,
    // so a real download of the same video neither stops it nor is stopped by it.
    private static func downloadKey(_ id: String) -> String { return "m4a-\(id)" }

    private func setCancelled(_ id: String, _ on: Bool) {
        objc_sync_enter(self)
        if on { cancelledIds.insert(id) } else { cancelledIds.remove(id) }
        objc_sync_exit(self)
    }

    private func isCancelled(_ id: String) -> Bool {
        objc_sync_enter(self); let c = cancelledIds.contains(id); objc_sync_exit(self)
        return c
    }
}
