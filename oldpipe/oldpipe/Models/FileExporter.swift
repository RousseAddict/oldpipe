import UIKit

// MARK: - FileExporter
// "File" in the Save to section of the Download picker, and "Save as MP4 File" / "Save as M4A
// File" on the Download button once a video is downloaded (VideoPlayerVC). Writes a real file
// into Documents/, where iTunes File Sharing exposes it: a video quality becomes <title>.mp4,
// the audio-only stream <title>.m4a.
//
// WHY NOT THE MUSIC APP: there is no public way to put a file into it. MPMediaLibrary is
// read-only on every iOS this app runs on, and the one write call that exists
// (addItem(withProductID:), iOS 9.3+) takes an Apple Music catalog id, not a local file. So the
// user drags the file out of iTunes and adds it to their library themselves. The picker row
// says "File" rather than "Music" for exactly that reason.
//
// What the file is made from, by what the download is:
//   muxed 360p      already one .mp4 (downloads/<id>.mp4): copied in under the new name.
//   HLS video tier  index.m3u8 + seg<i>.ts: MP4Remuxer joins the segments into one .mp4, the
//                   same conversion Save to Photos uses.
//   audio only      an HLS bundle too (iOS 6 AVPlayer cannot play the fMP4 the adaptive audio
//                   stream ships as): MP4Remuxer writes a single-track .m4a.
// Nothing is re-encoded. A remuxed file carries the title and channel as iTunes metadata, so
// it does not show up as a bare file name; the copied 360p file is YouTube's own, as it came.
//
// Unlike Save to Photos there is no compatibility probe: nothing here refuses a quality. A
// 1080p60 file this phone cannot play is still a fine file to copy to a computer.
//
// Two ways in, by what is on disk:
//   downloaded      export(): made from the download, which stays as it is.
//   not downloaded  downloadAndExportVideo/Audio(): fetched into workDir, exported, deleted.
//                   DownloadManager never hears of it, so it shows in no Downloads row.
//
// Exports run one at a time on a serial queue and keep going after the user leaves the screen.

final class FileExporter {

    static let shared = FileExporter()

    // Same static-serial-queue convention as OfflineDownloader: one thread, exports queue up.
    private static let queue = AppQueue(label: "com.oldpipe.fileexport")

    // Export-only downloads and copies in progress live here; finished files go to Documents/.
    private static let workDir: String =
        (NSTemporaryDirectory() as NSString).appendingPathComponent("file-export")

    // Main-thread-only state, like DownloadManager.inFlight.
    private var status: [String: String] = [:]      // id -> "Waiting...", "Exporting 34%"...
    private var exported: [String: String] = [:]    // id -> file name, for the confirmation
    private var backgroundTasks: [String: UIBackgroundTaskIdentifier] = [:]
    private var ownsDownload: Set<String> = []      // running downloadAndExport…(), not export()
    private var progressiveTransfers: [String: CurlFetcher] = [:]   // an export-only 360p fetch

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

    // Any finished download: a video one becomes an .mp4, an audio-only one an .m4a.
    static func canExport(_ videoId: String) -> Bool {
        return DownloadManager.isDownloaded(videoId) && DownloadManager.kind(for: videoId) != .none
    }

    // MARK: - Export a download already on disk

    func export(_ video: Video) {
        let id = video.id
        guard status[id] == nil, FileExporter.canExport(id) else { return }
        // The file and the download coexist. A copy is the download's size and a remux comes
        // out smaller than its bundle (TS carries packet overhead), so the input's size is
        // the safe estimate.
        guard hasRoom(for: DownloadManager.diskBytes(for: id)) else { return }
        let audioOnly = DownloadManager.isAudioOnly(id)
        let progressive = DownloadManager.kind(for: id) == .progressive
        begin(id)
        status[id] = "Waiting..."
        beginBackgroundTask(id)
        if progressive {
            let src = DownloadManager.filePath(for: id)
            FileExporter.queue.async { self.copyIn(id, video: video, from: src, move: false) }
        } else {
            let bundle = DownloadManager.bundleDir(for: id)
            FileExporter.queue.async {
                self.convert(id, video: video, bundle: bundle, audioOnly: audioOnly, ownsBundle: false)
            }
        }
    }

    // MARK: - Download just to export

    // Fetch a video tier into workDir, make the .mp4, delete what was fetched. `audioStream`
    // nil = the muxed 360p stream, which arrives as the .mp4 itself.
    func downloadAndExportVideo(_ video: Video, quality: String, videoStream: VideoStream,
                                audioStream: VideoStream?, estimatedBytes: Int64) {
        let id = video.id
        guard status[id] == nil else { return }
        // A bundle and the file made from it coexist until the bundle is deleted; a 360p fetch
        // is only moved.
        guard hasRoom(for: audioStream == nil ? estimatedBytes : estimatedBytes * 2) else { return }
        begin(id)
        ownsDownload.insert(id)
        status[id] = "Waiting..."
        beginBackgroundTask(id)
        DebugLog.log("FileExport", "id=\(id) \(quality) downloading for a file only")

        guard let audio = audioStream else {
            let path = FileExporter.workPath("\(id)-download.mp4")
            progressiveTransfers[id] = CurlFetcher.downloadToFile(url: videoStream.url, outputPath: path,
                                                                  progress: { p in
                // Moving it into place afterwards is instant, so the download is the whole wait.
                self.setProgress(id, Int(p * 99))
            }) { ok in
                self.progressiveTransfers[id] = nil
                // A Stop aborts the transfer (see cancel()), which also ends here, as a failure.
                let stopped = self.isCancelled(id)
                if !ok || stopped {
                    unlink(path)
                    self.finish(id, failure: stopped ? nil : self.downloadFailedText)
                    return
                }
                FileExporter.queue.async { self.copyIn(id, video: video, from: path, move: true) }
            }
            return
        }
        let bundle = FileExporter.workPath("\(id)-bundle")
        // Never resume into a bundle left by an earlier attempt: it may hold another quality.
        try? FileManager.default.removeItem(atPath: bundle)
        OfflineDownloader.start(video: video, videoStream: videoStream, audioStream: audio,
                                into: bundle, cancelKey: FileExporter.downloadKey(id),
                                progress: { p in
            // The download is most of the wait; the conversion after it gets the last 10%.
            self.setProgress(id, Int(p * 90))
        }) { ok in
            self.downloadEnded(id, video: video, bundle: bundle, ok: ok, audioOnly: false)
        }
    }

    // Fetch the audio into workDir, make the .m4a, delete the bundle.
    func downloadAndExportAudio(_ video: Video, audioStream: VideoStream, estimatedBytes: Int64) {
        let id = video.id
        guard status[id] == nil else { return }
        guard hasRoom(for: estimatedBytes * 2) else { return }
        begin(id)
        ownsDownload.insert(id)
        status[id] = "Waiting..."
        beginBackgroundTask(id)
        DebugLog.log("FileExport", "id=\(id) downloading audio for a file only")

        let bundle = FileExporter.workPath("\(id)-bundle")
        try? FileManager.default.removeItem(atPath: bundle)
        OfflineDownloader.startAudio(video: video, audioStream: audioStream,
                                     into: bundle, cancelKey: FileExporter.downloadKey(id),
                                     progress: { p in
            self.setProgress(id, Int(p * 90))
        }) { ok in
            self.downloadEnded(id, video: video, bundle: bundle, ok: ok, audioOnly: true)
        }
    }

    private func downloadEnded(_ id: String, video: Video, bundle: String, ok: Bool, audioOnly: Bool) {
        let stopped = isCancelled(id)
        if !ok || stopped {
            try? FileManager.default.removeItem(atPath: bundle)
            finish(id, failure: stopped ? nil : downloadFailedText)
            return
        }
        FileExporter.queue.async {
            self.convert(id, video: video, bundle: bundle, audioOnly: audioOnly, ownsBundle: true)
        }
    }

    // MARK: - Stop

    func cancel(_ videoId: String) {
        guard canStop(videoId) else { return }
        setCancelled(videoId, true)
        if ownsDownload.contains(videoId) {
            OfflineDownloader.cancel(FileExporter.downloadKey(videoId))
            progressiveTransfers[videoId]?.cancel()
        }
        status[videoId] = "Stopping..."
    }

    // DownloadManager.remove: an export of that download reads the files about to be deleted.
    // An export-only download reads none of them, so it carries on.
    func downloadRemoved(_ videoId: String) {
        if status[videoId] != nil, !ownsDownload.contains(videoId) { setCancelled(videoId, true) }
    }

    // MARK: - Making the file (runs on `queue`)

    private func convert(_ id: String, video: Video, bundle: String, audioOnly: Bool, ownsBundle: Bool) {
        defer { if ownsBundle { try? FileManager.default.removeItem(atPath: bundle) } }
        let abort = { self.isCancelled(id) }
        if abort() { AppQueue.main.async { self.finish(id) }; return }

        // Pick the name before writing, so a clash is resolved against what is already there.
        let ext = audioOnly ? "m4a" : "mp4"
        let name = FileExporter.uniqueName(for: video.title, ext: ext)
        let out = FileExporter.documentsPath(name)
        let started = Date()
        let reason = MP4Remuxer.remux(bundleDir: bundle, outPath: out,
                                      audioOnly: audioOnly,
                                      title: video.title, artist: video.channelName,
                                      progress: { done, total in
            let pct = done * 100 / max(total, 1)
            AppQueue.main.async { self.setProgress(id, ownsBundle ? 90 + pct / 10 : pct) }
        }, shouldAbort: abort)
        let ms = Int(Date().timeIntervalSince(started) * 1000)

        if let reason = reason {
            DebugLog.log("FileExport", "id=\(id) remux failed after \(ms)ms: \(reason)")
            AppQueue.main.async {
                self.finish(id, failure: reason == "cancelled" ? nil : self.convertFailedText(ext))
            }
            return
        }
        DebugLog.log("FileExport", "id=\(id) wrote \(name) (\(FileExporter.fileSize(out)) bytes) in \(ms)ms")
        AppQueue.main.async { self.completed(id, name: name, path: out) }
    }

    // A muxed 360p file already is the .mp4: copied in from a download (which stays), or moved
    // in from an export-only fetch. A copy goes through workDir and is moved into Documents
    // whole, so iTunes never lists a half-written file.
    private func copyIn(_ id: String, video: Video, from src: String, move: Bool) {
        if isCancelled(id) {
            if move { unlink(src) }
            AppQueue.main.async { self.finish(id) }
            return
        }
        let name = FileExporter.uniqueName(for: video.title, ext: "mp4")
        let out = FileExporter.documentsPath(name)
        let fm = FileManager.default
        do {
            if move {
                try fm.moveItem(atPath: src, toPath: out)
            } else {
                let tmp = FileExporter.workPath("\(id)-copy.mp4")
                try? fm.removeItem(atPath: tmp)
                try fm.copyItem(atPath: src, toPath: tmp)
                try fm.moveItem(atPath: tmp, toPath: out)
            }
        } catch {
            DebugLog.log("FileExport", "id=\(id) \(move ? "move" : "copy") failed: \(error)")
            if move { unlink(src) }
            // A download deleted mid-copy fails the copy too; that one was asked for.
            AppQueue.main.async { self.finish(id, failure: self.isCancelled(id) ? nil : self.writeFailedText) }
            return
        }
        DebugLog.log("FileExport", "id=\(id) \(move ? "moved" : "copied") 360p in as \(name)")
        AppQueue.main.async { self.completed(id, name: name, path: out) }
    }

    // Main thread. Stopped while the last piece was being written: drop the file, export nothing.
    private func completed(_ id: String, name: String, path: String) {
        if isCancelled(id) {
            unlink(path)
            finish(id)
            return
        }
        exported[id] = name
        finish(id)
        alert("Saved", "\u{201C}\(name)\u{201D} is in oldpipe's Documents folder. "
            + "Connect the device to iTunes, open the Apps tab and look under File Sharing "
            + "to copy it off.")
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
        return out.isEmpty ? "oldpipe" : out
    }

    // "<title>.mp4", or "<title> 2.mp4" when that is taken — exporting twice must not
    // silently overwrite the first file.
    private static func uniqueName(for title: String, ext: String) -> String {
        let base = safeName(title)
        var name = "\(base).\(ext)"
        var n = 2
        while FileManager.default.fileExists(atPath: documentsPath(name)) && n < 1000 {
            name = "\(base) \(n).\(ext)"
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

    private func convertFailedText(_ ext: String) -> String {
        return ext == "m4a" ? "Couldn't build an M4A file from this download."
                            : "Couldn't build an MP4 file from this download."
    }
    private let writeFailedText = "Couldn't write the file. The device may be full."
    private let downloadFailedText = "The download didn't finish, so no file was saved."

    private func begin(_ id: String) {
        // Nothing running: whatever is in workDir was left by an export the app did not live
        // to finish.
        if status.isEmpty { try? FileManager.default.removeItem(atPath: FileExporter.workDir) }
        try? FileManager.default.createDirectory(atPath: FileExporter.workDir,
                                                 withIntermediateDirectories: true, attributes: nil)
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
        if let message = failure { alert("Save as File", message) }
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
              String(format: "Saving this file needs about %.0f MB but only %.0f MB is free.",
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
    private static func downloadKey(_ id: String) -> String { return "file-\(id)" }

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
