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

// A stream whose network resolution is done but whose final playable URL is not yet built.
// `finalize` turns it into a ResolvedStream at the moment of playback. Splitting the two
// steps lets callers prefetch the (slow) network part ahead of time WITHOUT registering a
// StreamProxy route early — doing so bumps the proxy generation and would abort a
// currently-playing iOS-6 stream. `.local` = a completed download; `.remote` = a raw
// googlevideo URL not yet proxy-wrapped.
enum PreparedStream {
    case local(URL)
    case remote(String)
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

    // Network-only half of resolve(): a completed download resolves immediately; otherwise the
    // innertube getStreams call runs and the preferred remote URL is returned UN-wrapped (no
    // StreamProxy route yet). Safe to call ahead of time (prefetch) without disturbing the
    // active stream. completion fires on the main thread; nil = nothing playable.
    static func prepare(_ video: Video, completion: @escaping (PreparedStream?) -> Void) {
        if DownloadManager.isDownloaded(video.id) {
            let url = URL(fileURLWithPath: DownloadManager.filePath(for: video.id))
            completion(.local(url))
            return
        }
        YoutubeAPI.getStreams(videoId: video.id) { streams, _, _ in
            guard let preferred = pickPreferred(streams) else {
                completion(nil)
                return
            }
            completion(.remote(preferred.url))
        }
    }

    // Playback-time half: turn a PreparedStream into a playable ResolvedStream. On iOS 6 this
    // is where the StreamProxy route is finally registered (bumping the proxy generation at the
    // correct moment — the actual switch). Returns nil if the URL can't be built.
    static func finalize(_ prepared: PreparedStream) -> ResolvedStream? {
        switch prepared {
        case .local(let url):
            return ResolvedStream(url: url, isLocal: true)
        case .remote(let remote):
            let iosVersion = (UIDevice.current.systemVersion as NSString).floatValue
            if iosVersion >= 7.0 {
                guard let u = URL(string: remote) else { return nil }
                return ResolvedStream(url: u, isLocal: false)
            } else if let local = StreamProxy.shared.localURL(for: remote) {
                return ResolvedStream(url: local, isLocal: false)
            }
            return nil
        }
    }
}
