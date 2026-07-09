import UIKit

// MARK: - StreamResolver
// UI-independent resolution of a Video into a playable URL for the VideoPlayer singleton.
// This exists because the autoplay-next queue lives in VideoPlayer.shared and must advance
// even after VideoPlayerVC (which owns the interactive stream-loading + download fallback)
// has been popped — the mini bar keeps playback going. StreamResolver mirrors the VC's
// stream selection and iOS-version streaming path (direct googlevideo on iOS 7+, local
// StreamProxy on iOS 6) but deliberately has NO download fallback: if a stream can't be
// resolved, the queue simply stops rather than duplicating the VC's fragile fallback logic.

struct ResolvedStream {
    let url: URL
    let isLocal: Bool
}

final class StreamResolver {

    // Pick the muxed 360p stream (itag 18), falling back to any playable MP4/video stream.
    static func pickPreferred(_ streams: [VideoStream]) -> VideoStream? {
        return streams.first { $0.itag == 18 }
            ?? streams.first { $0.mimeType.contains("mp4") && !$0.mimeType.contains("av01") }
            ?? streams.first { $0.mimeType.contains("video") }
            ?? streams.first
    }

    // Resolve a video to a playable URL. A completed offline download takes priority (no
    // network); otherwise streams are fetched via innertube, the preferred format is picked,
    // and either the direct googlevideo URL (iOS 7+) or a local StreamProxy URL (iOS 6) is
    // returned. completion fires on the main thread (getStreams already hops to main); its
    // argument is nil when nothing playable could be resolved.
    static func resolve(_ video: Video, completion: @escaping (ResolvedStream?) -> Void) {
        if DownloadManager.isDownloaded(video.id) {
            let url = URL(fileURLWithPath: DownloadManager.filePath(for: video.id))
            completion(ResolvedStream(url: url, isLocal: true))
            return
        }
        YoutubeAPI.getStreams(videoId: video.id) { streams, _, _ in
            guard let preferred = pickPreferred(streams) else {
                completion(nil)
                return
            }
            let iosVersion = (UIDevice.current.systemVersion as NSString).floatValue
            if iosVersion >= 7.0 {
                if let u = URL(string: preferred.url) {
                    completion(ResolvedStream(url: u, isLocal: false))
                } else {
                    completion(nil)
                }
            } else if let local = StreamProxy.shared.localURL(for: preferred.url) {
                completion(ResolvedStream(url: local, isLocal: false))
            } else {
                completion(nil)
            }
        }
    }
}
