import UIKit

// MARK: - PhotoExporter
// "Save to Photos", from the Share sheet on the video page (VideoPlayerVC).
//
// UISaveVideoAtPathToSavedPhotosAlbum (iOS 3.1+) does the actual import on every target, but it
// only takes one MP4/MOV file. A direct 360p download already is one (downloads/<id>.mp4) and
// goes straight in. Every other quality is an HLS bundle, which MP4Remuxer first turns into a
// temporary .mp4 — byte-identical samples, nothing re-encoded.
//
// Three ways in, by what is on disk:
//   downloaded         export(): the download is saved in place, or converted and saved.
//   still downloading  saveWhenDownloaded(): DownloadManager calls downloadFinished() at the
//                      end, and the export starts then.
//   not downloaded     downloadAndSave(): fetched into workDir, saved, deleted. DownloadManager
//                      never hears of it, so it shows in no Downloads row and the player
//                      never picks it up as an offline copy.
//
// Whether this device's Photos accepts a quality (1080p on an iPhone 4, 60fps on an A5...) is
// only answerable on the device, so a bundle is PROBED first: its first segment alone is
// remuxed and checked with UIVideoAtPathIsCompatibleWithSavedPhotosAlbum. Codec, profile,
// level, size and frame rate are the same as the whole file's, so a "no" costs about a second
// instead of a full conversion — and, for a Photos-only download, one segment instead of the
// whole download.
//
// Exports run one at a time on a serial queue and keep going after the user leaves the screen
// (and, within the OS's limit, the app).

final class PhotoExporter: NSObject {

    static let shared = PhotoExporter()

    // Same static-serial-queue convention as OfflineDownloader: one thread, exports queue up.
    private static let queue = AppQueue(label: "com.oldpipe.photoexport")

    // Converted files and Photos-only downloads live here and nowhere else. The save callback
    // only ever deletes paths under this directory — a progressive download is saved in place
    // and must survive.
    private static let workDir: String =
        (NSTemporaryDirectory() as NSString).appendingPathComponent("photo-export")

    // Main-thread-only state, like DownloadManager.inFlight.
    private var status: [String: String] = [:]          // id -> "Waiting...", "Saving 34%"...
    private var saved: Set<String> = []                  // this session, for the row label
    private var savingPaths: [String: String] = [:]      // file handed to Photos -> id
    private var backgroundTasks: [String: UIBackgroundTaskIdentifier] = [:]
    private var photoOnly: Set<String> = []              // running downloadAndSave(), not export()
    private var pending: Set<String> = []                // saveWhenDownloaded(), not started yet

    // Written on the main thread, read from the export queue, so every access takes the lock.
    private var cancelledIds: Set<String> = []

    // MARK: - State for the UI

    func isBusy(_ videoId: String) -> Bool { return status[videoId] != nil }

    // Whether Stop still means anything: a file already handed to Photos is Photos' own import.
    func canStop(_ videoId: String) -> Bool {
        if pending.contains(videoId) { return true }
        return status[videoId] != nil && !isCancelled(videoId) && !savingPaths.values.contains(videoId)
    }

    // Saved this session — the confirmation warns that saving again makes a second copy.
    func wasSaved(_ videoId: String) -> Bool { return saved.contains(videoId) }

    // nil = nothing to say; the row shows its usual quality and size.
    func statusText(_ videoId: String) -> String? {
        if let s = status[videoId] { return s }
        return saved.contains(videoId) ? "Saved to Photos \u{2713}" : nil
    }

    // Only a finished video download can be exported (audio-only is not a video).
    static func canExport(_ videoId: String) -> Bool {
        return DownloadManager.isDownloaded(videoId) && !DownloadManager.isAudioOnly(videoId)
    }

    // MARK: - Export a download

    func export(_ video: Video) {
        let id = video.id
        guard status[id] == nil, PhotoExporter.canExport(id) else { return }
        let quality = DownloadManager.qualityLabel(for: id)
        let kind = DownloadManager.kind(for: id)
        // A progressive file is saved in place, so only Photos' copy is new. A bundle's
        // converted copy and Photos' own copy of it briefly coexist with the bundle.
        let size = DownloadManager.diskBytes(for: id)
        guard kind != .none, hasRoom(for: kind == .hls ? size * 2 : size) else { return }
        begin(id)

        if kind == .progressive {
            let path = DownloadManager.filePath(for: id)
            guard UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(path) else {
                showIncompatible(quality)
                return
            }
            DebugLog.log("PhotoExport", "id=\(id) progressive, saving in place")
            status[id] = "Finishing..."
            beginBackgroundTask(id)
            save(path, id: id)
        } else {
            status[id] = "Waiting..."
            beginBackgroundTask(id)
            let bundle = DownloadManager.bundleDir(for: id)
            PhotoExporter.queue.async {
                self.convert(id, bundle: bundle, quality: quality, ownsBundle: false)
            }
        }
    }

    // MARK: - Save once a running download finishes

    func saveWhenDownloaded(_ videoId: String) {
        guard status[videoId] == nil else { return }
        pending.insert(videoId)
    }

    // DownloadManager calls this at the end of every video download, whatever the outcome.
    func downloadFinished(_ video: Video, success: Bool) {
        guard pending.remove(video.id) != nil else { return }
        if success && PhotoExporter.canExport(video.id) {
            export(video)
        } else {
            alert("Save to Photos", downloadFailedText)
        }
    }

    // MARK: - Download just for Photos

    // Fetch `quality` into workDir, save it, delete it. `audioStream` nil = the muxed 360p
    // stream, which arrives as the .mp4 Photos takes; anything else is an HLS bundle first.
    func downloadAndSave(_ video: Video, quality: String, videoStream: VideoStream,
                         audioStream: VideoStream?, estimatedBytes: Int64) {
        let id = video.id
        guard status[id] == nil else { return }
        // The bundle and its converted copy coexist until the bundle is deleted, then the copy
        // and Photos' own.
        guard hasRoom(for: estimatedBytes * 2) else { return }
        begin(id)
        try? FileManager.default.createDirectory(atPath: PhotoExporter.workDir,
                                                 withIntermediateDirectories: true, attributes: nil)
        photoOnly.insert(id)
        status[id] = "Waiting..."   // until the download queue gets to it
        beginBackgroundTask(id)
        DebugLog.log("PhotoExport", "id=\(id) \(quality) downloading for Photos only")

        guard let audio = audioStream else {
            downloadProgressive(id, url: videoStream.url, quality: quality)
            return
        }
        let bundle = PhotoExporter.workPath("\(id)-bundle")
        // Never resume into a bundle left by an earlier attempt: it may hold another quality.
        try? FileManager.default.removeItem(atPath: bundle)
        var probed = false
        OfflineDownloader.start(video: video, videoStream: videoStream, audioStream: audio,
                                into: bundle, cancelKey: PhotoExporter.downloadKey(id),
                                progress: { p in
            // The download is most of the wait; the conversion after it gets the last 10%.
            self.setProgress(id, Int(p * 90))
            // First segment on disk: probe it now, so a quality Photos refuses here is found
            // after one segment instead of after the whole download.
            if !probed {
                probed = true
                PhotoExporter.queue.async { self.probeEarly(id, bundle: bundle, quality: quality) }
            }
        }) { ok in
            let stopped = self.isCancelled(id)
            if !ok || stopped {
                try? FileManager.default.removeItem(atPath: bundle)
                self.finish(id, failure: stopped ? nil : self.downloadFailedText)
                return
            }
            PhotoExporter.queue.async {
                self.convert(id, bundle: bundle, quality: quality, ownsBundle: true)
            }
        }
    }

    private func downloadProgressive(_ id: String, url: String, quality: String) {
        let path = PhotoExporter.workPath("\(id)-download.mp4")
        CurlFetcher.downloadToFile(url: url, outputPath: path, progress: { p in
            self.setProgress(id, Int(p * 100))
        }) { ok in
            // A progressive copy runs inside one curl call, so a Stop only lands here.
            let stopped = self.isCancelled(id)
            if !ok || stopped {
                unlink(path)
                self.finish(id, failure: stopped ? nil : self.downloadFailedText)
                return
            }
            guard UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(path) else {
                unlink(path)
                self.finish(id)
                self.showIncompatible(quality)
                return
            }
            self.status[id] = "Finishing..."
            self.save(path, id: id)   // the save callback deletes it (it is under workDir)
        }
    }

    // MARK: - Stop

    // The Share sheet's Stop. A queued export never starts; a running download or conversion
    // stops at its next segment (a progressive copy runs to its end first) and cleans up.
    func cancel(_ videoId: String) {
        if pending.remove(videoId) != nil { return }
        guard canStop(videoId) else { return }
        stop(videoId)
        status[videoId] = "Stopping..."
    }

    // DownloadManager.remove: an export of that download reads the files about to be deleted.
    // A Photos-only download reads none of them, so it carries on.
    func downloadRemoved(_ videoId: String) {
        pending.remove(videoId)
        if status[videoId] != nil, !photoOnly.contains(videoId) { setCancelled(videoId, true) }
    }

    private func stop(_ id: String) {
        setCancelled(id, true)
        if photoOnly.contains(id) { OfflineDownloader.cancel(PhotoExporter.downloadKey(id)) }
    }

    // MARK: - Conversion (runs on `queue`)

    // `ownsBundle` = a Photos-only bundle: already probed after its first segment, and nobody's
    // download, so it is deleted whatever happens here.
    private func convert(_ id: String, bundle: String, quality: String, ownsBundle: Bool) {
        defer { if ownsBundle { try? FileManager.default.removeItem(atPath: bundle) } }
        let abort = { self.isCancelled(id) }
        if abort() { AppQueue.main.async { self.finish(id) }; return }
        try? FileManager.default.createDirectory(atPath: PhotoExporter.workDir,
                                                 withIntermediateDirectories: true, attributes: nil)

        if !ownsBundle {
            AppQueue.main.async { self.setProgress(id, 0) }
            guard let compatible = probe(id, bundle: bundle) else {
                AppQueue.main.async { self.finish(id, failure: abort() ? nil : self.convertFailedText) }
                return
            }
            guard compatible else {
                AppQueue.main.async {
                    self.finish(id)
                    self.showIncompatible(quality)
                }
                return
            }
        }

        let out = PhotoExporter.workPath("\(id).mp4")
        let started = Date()
        let reason = MP4Remuxer.remux(bundleDir: bundle, outPath: out, progress: { done, total in
            let pct = done * 100 / max(total, 1)
            AppQueue.main.async { self.setProgress(id, ownsBundle ? 90 + pct / 10 : pct) }
        }, shouldAbort: abort)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if let reason = reason {
            DebugLog.log("PhotoExport", "id=\(id) remux failed after \(ms)ms: \(reason)")
            AppQueue.main.async { self.finish(id, failure: reason == "cancelled" ? nil : self.convertFailedText) }
            return
        }
        DebugLog.log("PhotoExport", "id=\(id) remuxed in \(ms)ms, handing to Photos")
        AppQueue.main.async {
            // Stopped while the last segment was being written: drop the copy, save nothing.
            if self.isCancelled(id) {
                unlink(out)
                self.finish(id)
                return
            }
            self.status[id] = "Finishing..."
            self.save(out, id: id)
        }
    }

    // A Photos-only download's first segment just landed. A "no" stops the download; its
    // completion then cleans up without an alert of its own.
    private func probeEarly(_ id: String, bundle: String, quality: String) {
        guard !isCancelled(id), let compatible = probe(id, bundle: bundle), !compatible else { return }
        AppQueue.main.async {
            guard self.status[id] != nil, !self.isCancelled(id) else { return }
            self.stop(id)
            self.showIncompatible(quality)
        }
    }

    // The first segment alone, remuxed and offered to Photos. nil = it couldn't be built.
    private func probe(_ id: String, bundle: String) -> Bool? {
        let path = PhotoExporter.workPath("\(id)-probe.mp4")
        defer { unlink(path) }
        if let reason = MP4Remuxer.remux(bundleDir: bundle, outPath: path, maxSegments: 1,
                                         shouldAbort: { self.isCancelled(id) }) {
            DebugLog.log("PhotoExport", "id=\(id) probe failed: \(reason)")
            return nil
        }
        let compatible = AppQueue.main.sync { UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(path) }
        DebugLog.log("PhotoExport", "id=\(id) probe: Photos compatible = \(compatible)")
        return compatible
    }

    // MARK: - Photos

    private func save(_ path: String, id: String) {
        savingPaths[path] = id
        UISaveVideoAtPathToSavedPhotosAlbum(path, self,
                                            #selector(video(_:didFinishSavingWithError:contextInfo:)), nil)
    }

    // Photos copies the file asynchronously; only now may a converted file be deleted.
    @objc func video(_ videoPath: String, didFinishSavingWithError error: NSError?,
                     contextInfo: UnsafeMutableRawPointer?) {
        let id = savingPaths.removeValue(forKey: videoPath)
        if videoPath.hasPrefix(PhotoExporter.workDir + "/") { unlink(videoPath) }
        guard let videoId = id else { return }
        if let error = error {
            DebugLog.log("PhotoExport", "id=\(videoId) Photos refused: \(error.domain) \(error.code) \(error.localizedDescription)")
            // A failure caused by deleting the download mid-save is not worth an alert.
            finish(videoId, failure: isCancelled(videoId) ? nil :
                "Couldn't save to Photos. If oldpipe was denied access, allow it in Settings \u{203A} Privacy \u{203A} Photos.")
        } else {
            DebugLog.log("PhotoExport", "id=\(videoId) saved to Photos")
            if !isCancelled(videoId) { saved.insert(videoId) }
            finish(videoId)
        }
    }

    // MARK: - Helpers (main thread)

    private let convertFailedText = "Couldn't convert this video for Photos."
    private let downloadFailedText = "The download didn't finish, so nothing was saved to Photos."

    // Start of any export. Nothing running = whatever is in workDir is a leftover from a crash
    // or a kill.
    private func begin(_ id: String) {
        if status.isEmpty { try? FileManager.default.removeItem(atPath: PhotoExporter.workDir) }
        setCancelled(id, false)
        saved.remove(id)   // so the end of THIS export is what decides the "Saved" label
    }

    // "Saving N%", unless a Stop already replaced it with "Stopping...".
    private func setProgress(_ id: String, _ pct: Int) {
        guard status[id] != nil, !isCancelled(id) else { return }
        status[id] = "Saving \(pct)%"
    }

    private func finish(_ id: String, failure: String? = nil) {
        status[id] = nil
        photoOnly.remove(id)
        setCancelled(id, false)
        if let t = backgroundTasks.removeValue(forKey: id) {
            UIApplication.shared.endBackgroundTask(t)
        }
        if let message = failure { alert("Save to Photos", message) }
    }

    // Lets a long 1080p download or conversion finish after the user leaves the app. If the OS
    // runs out of patience first, it is stopped and cleans up after itself. A file already
    // handed to Photos is left alone: that import is Photos' own and will still land.
    private func beginBackgroundTask(_ id: String) {
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(expirationHandler: {
            if !self.savingPaths.values.contains(id) { self.stop(id) }
            UIApplication.shared.endBackgroundTask(task)
            if self.backgroundTasks[id] == task { self.backgroundTasks[id] = nil }
        })
        backgroundTasks[id] = task
    }

    // `needed` bytes plus the same 50 MB headroom the download sheet keeps. 0 free = unknown,
    // in which case the export is not blocked on a number we couldn't read.
    private func hasRoom(for needed: Int64) -> Bool {
        let free = DownloadManager.freeDiskBytes()
        guard free > 0, needed + 50 * 1024 * 1024 > free else { return true }
        alert("Not Enough Space",
              String(format: "Saving to Photos needs about %.0f MB but only %.0f MB is free.",
                     Double(needed) / (1024.0 * 1024.0), Double(free) / (1024.0 * 1024.0)))
        return false
    }

    private func showIncompatible(_ quality: String) {
        let what = quality.isEmpty ? "This video" : "This quality (\(quality))"
        alert("Save to Photos", "\(what) can't be saved to Photos on this device. "
              + "A lower quality will work.")
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

    // OfflineDownloader's cancel key for a Photos-only download: distinct from the video id, so
    // a real download of the same video neither stops it nor is stopped by it.
    private static func downloadKey(_ id: String) -> String { return "photos-\(id)" }

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
