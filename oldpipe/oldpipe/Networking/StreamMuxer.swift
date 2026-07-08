import AVFoundation
import Foundation

// MARK: - StreamMuxer
// Combines a downloaded video-only track and audio-only track (two separate local mp4/m4a
// files) into a single playable mp4 using AVMutableComposition + AVAssetExportSession with
// the passthrough preset (NO re-encode — fast and low-CPU, which matters on the iPhone 4S).
//
// This is how oldpipe offers >360p: YouTube removed the muxed 720p format (itag 22) in June
// 2024, so high quality now exists ONLY as separate adaptive video + audio streams that must
// be combined on-device. A passthrough remux of a real YouTube itag-136 (720p H.264) +
// itag-140 (AAC) pair was spike-confirmed to produce a valid 1-video/1-audio mp4 on macOS;
// on-device failure falls back to the 360p single-file download.

final class StreamMuxer {

    // Own serial queue — one export at a time (iPhone 4S memory/thermal budget).
    private static let muxQueue = DispatchQueue(label: "com.oldpipe.mux")

    // Mux videoPath (video-only) + audioPath (audio-only) into outputPath (mp4). completion
    // fires on the main thread: (success, diagnostic). diagnostic is nil on success, else a
    // short human-readable reason (surfaced as "Download failed — <reason>" so on-device
    // failures — which the macOS spike can't reproduce — can be root-caused from the screen).
    static func mux(videoPath: String, audioPath: String, outputPath: String,
                    completion: @escaping (Bool, String?) -> Void) {
        muxQueue.async {
            let err = syncMux(videoPath: videoPath, audioPath: audioPath, outputPath: outputPath)
            DispatchQueue.main.async { completion(err == nil, err) }
        }
    }

    // Returns nil on success, else a short failure reason.
    private static func syncMux(videoPath: String, audioPath: String, outputPath: String) -> String? {
        let vURL = URL(fileURLWithPath: videoPath)
        let aURL = URL(fileURLWithPath: audioPath)
        let outURL = URL(fileURLWithPath: outputPath)
        try? FileManager.default.removeItem(at: outURL)

        let comp = AVMutableComposition()
        // CRITICAL on iOS 6: AVURLAsset picks its demuxer from the file's PATH EXTENSION (it
        // does not content-sniff like modern iOS). The tracks are downloaded to <id>.vpart /
        // <id>.apart, and an unrecognized ".vpart"/".apart" extension makes the tracks key
        // load FAIL with "cannot open" (AVErrorFileFormatNotRecognized). Pass the real MIME
        // type out-of-band (AVURLAssetOutOfBandMIMETypeKey, iOS 4+) so AVFoundation opens the
        // mp4/m4a container regardless of the temp extension. (itag 136/137 = video/mp4,
        // itag 140/139 = AAC audio in an mp4 container = audio/mp4.)
        // Key is the raw string ("AVURLAssetOutOfBandMIMETypeKey" — its own literal value in the
        // ObjC headers); the Swift SDK doesn't export the symbol, but AVFoundation honors the key.
        let vOpts: [String: Any] = ["AVURLAssetOutOfBandMIMETypeKey": "video/mp4"]
        let aOpts: [String: Any] = ["AVURLAssetOutOfBandMIMETypeKey": "audio/mp4"]
        let vAsset = AVURLAsset(url: vURL, options: vOpts)
        let aAsset = AVURLAsset(url: aURL, options: aOpts)

        // CRITICAL on iOS 6: AVURLAsset.tracks and .duration are NOT auto-loaded on
        // synchronous access (unlike macOS / modern iOS where property access blocks and
        // loads). Force-load the keys first (we're on the background muxQueue, so blocking
        // is fine).
        if let e = loadSynchronously(vAsset, keys: ["tracks", "duration"]) { return "vload " + e }
        if let e = loadSynchronously(aAsset, keys: ["tracks", "duration"]) { return "aload " + e }

        // Track counts are the key diagnostic: 0 video tracks after a successful load means
        // iOS 6's AVFoundation could not parse the container (e.g. YouTube's fragmented mp4).
        guard let vSrc = vAsset.tracks(withMediaType: .video).first else {
            return "no video track (v\(vAsset.tracks.count) a\(aAsset.tracks.count))"
        }
        guard let aSrc = aAsset.tracks(withMediaType: .audio).first else {
            return "no audio track (v\(vAsset.tracks.count) a\(aAsset.tracks.count))"
        }

        // Trim both tracks to the shorter of the two so neither runs past the other.
        let dur = CMTimeMinimum(vAsset.duration, aAsset.duration)
        if !dur.isNumeric || dur.seconds <= 0 { return "bad duration" }

        guard let vTrack = comp.addMutableTrack(withMediaType: .video,
                                                preferredTrackID: kCMPersistentTrackID_Invalid),
              let aTrack = comp.addMutableTrack(withMediaType: .audio,
                                                preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return "addTrack failed" }
        do {
            try vTrack.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: vSrc, at: .zero)
            try aTrack.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: aSrc, at: .zero)
        } catch { return "insert " + (error as NSError).localizedDescription }
        // Preserve the source rotation so portrait/shorts stay upright.
        vTrack.preferredTransform = vSrc.preferredTransform

        // NOTE: do NOT gate on AVAssetExportSession.exportPresets(compatibleWith:) — the spike
        // showed it false-negatives on Passthrough for this composition even though the export
        // then succeeds. Create the session and trust the real export status instead.
        // Try mp4 first; if that export fails, retry the same passthrough composition into a
        // .mov container (still no re-encode — cheap) since iOS 6's exporter is pickier about
        // the mp4 output type. Both write to the same <id>.mp4 path (AVPlayer sniffs the
        // container, so the extension doesn't matter for local playback).
        if let e1 = runExport(comp, outURL: outURL, fileType: .mp4) {
            try? FileManager.default.removeItem(at: outURL)
            if let e2 = runExport(comp, outURL: outURL, fileType: .mov) {
                try? FileManager.default.removeItem(at: outURL)
                return "mp4[\(e1)] mov[\(e2)]"
            }
        }
        return nil
    }

    // Runs one passthrough export. Returns nil on success, else a short status string.
    private static func runExport(_ comp: AVMutableComposition, outURL: URL,
                                  fileType: AVFileType) -> String? {
        guard let export = AVAssetExportSession(asset: comp,
                                                presetName: AVAssetExportPresetPassthrough)
        else { return "noSession" }
        export.outputURL = outURL
        export.outputFileType = fileType
        export.shouldOptimizeForNetworkUse = true

        let sem = DispatchSemaphore(value: 0)
        export.exportAsynchronously { sem.signal() }
        // Long 720p videos can take a while even for a passthrough remux; generous ceiling.
        if sem.wait(timeout: .now() + 900) == .timedOut {
            export.cancelExport()
            return "timeout"
        }
        if export.status == .completed, FileManager.default.fileExists(atPath: outURL.path) {
            return nil
        }
        return "st\(export.status.rawValue) " + ((export.error as NSError?)?.localizedDescription ?? "")
    }

    // Synchronously load asset keys (iOS 4+). Returns nil if every key ends up .loaded,
    // else a short reason. Blocks the calling (background) thread up to 60s.
    private static func loadSynchronously(_ asset: AVURLAsset, keys: [String]) -> String? {
        let sem = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: keys) { sem.signal() }
        if sem.wait(timeout: .now() + 60) == .timedOut { return "timeout" }
        for k in keys {
            var err: NSError?
            let st = asset.statusOfValue(forKey: k, error: &err)
            if st != .loaded { return "\(k) st\(st.rawValue) " + (err?.localizedDescription ?? "") }
        }
        return nil
    }
}
