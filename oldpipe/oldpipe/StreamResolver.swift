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
    // Carries the FULL streams list (not just the picked URL) so finalize can apply the
    // Settings > Default Video Quality preference at the moment of playback — deciding at
    // prepare time would be equally valid, but keeping the raw list defers the HLS-vs-360p
    // choice next to where the StreamProxy route is actually registered.
    case remote([VideoStream])
}

final class StreamResolver {

    // Pick the muxed 360p stream (itag 18), falling back to any playable MP4/video stream.
    static func pickPreferred(_ streams: [VideoStream]) -> VideoStream? {
        return streams.first { $0.itag == 18 }
            ?? streams.first { $0.mimeType.contains("mp4") && !$0.mimeType.contains("av01") }
            ?? streams.first { $0.mimeType.contains("video") }
            ?? streams.first
    }

    // The DASH audio track backing every HLS quality. Mirrors VideoPlayerVC.audioStreamForHLS.
    private static func audioStreamForHLS(_ streams: [VideoStream]) -> VideoStream? {
        return streams.first { $0.itag == 140 && $0.indexEnd > 0 }
    }

    // Settings > Default Video Quality, applied to non-interactive playback paths (playlist
    // autoplay-next, Shorts). Mirrors VideoPlayerVC.defaultQualityStream but works off a raw
    // streams array (no VC state). Steps DOWN from the preferred tier through 720p/480p if the
    // exact match isn't available. Returns nil for "auto" or when no HLS tier / audio track
    // exists for this video — callers then fall through to the normal 360p path.
    static func defaultQualityStream(_ streams: [VideoStream]) -> VideoStream? {
        let pref = AppSettings.defaultQuality
        guard pref != "auto", audioStreamForHLS(streams) != nil else { return nil }
        let opts: [VideoStream] = [135, 136, 137].compactMap { tag in
            streams.first { $0.itag == tag && $0.indexEnd > 0 && $0.mimeType.contains("avc1") }
        }
        guard !opts.isEmpty else { return nil }
        let order = ["1080", "720", "480"]
        let itagFor: [String: Int] = ["1080": 137, "720": 136, "480": 135]
        guard let startIdx = order.firstIndex(of: pref) else { return nil }
        for key in order[startIdx...] {
            if let itag = itagFor[key], let s = opts.first(where: { $0.itag == itag }) { return s }
        }
        return nil
    }

    // Wraps a chosen HLS video stream + its audio track into a local StreamProxy transmux URL.
    // Returns nil if the audio track is missing or the proxy couldn't build a route.
    private static func hlsResolvedStream(_ vStream: VideoStream, _ streams: [VideoStream]) -> ResolvedStream? {
        guard let aStream = audioStreamForHLS(streams),
              let local = StreamProxy.shared.hlsURL(videoURL: vStream.url, audioURL: aStream.url,
                                                    videoIndexEnd: vStream.indexEnd,
                                                    audioIndexEnd: aStream.indexEnd) else { return nil }
        return ResolvedStream(url: local, isLocal: false)
    }

    // Resolve a video to a playable URL. A completed offline download takes priority (no
    // network); otherwise streams are fetched via innertube. The Default Video Quality
    // preference is applied first (via the local HLS transmux proxy); if unset/unavailable,
    // the preferred 360p format is picked and either the direct googlevideo URL (iOS 7+) or a
    // local StreamProxy URL (iOS 6) is returned. completion fires on the main thread (getStreams
    // already hops to main); its argument is nil when nothing playable could be resolved.
    static func resolve(_ video: Video, completion: @escaping (ResolvedStream?) -> Void) {
        if DownloadManager.isDownloaded(video.id) {
            let url = URL(fileURLWithPath: DownloadManager.filePath(for: video.id))
            DebugLog.log("StreamResolver", "resolve id=\(video.id) -> local download")
            completion(ResolvedStream(url: url, isLocal: true))
            return
        }
        YoutubeAPI.getStreams(videoId: video.id) { streams, _, _ in
            if let vStream = defaultQualityStream(streams), let r = hlsResolvedStream(vStream, streams) {
                DebugLog.log("StreamResolver", "resolve id=\(video.id) -> HLS transmux itag=\(vStream.itag)")
                completion(r)
                return
            }
            guard let preferred = pickPreferred(streams) else {
                DebugLog.log("StreamResolver", "resolve id=\(video.id) -> FAILED, no usable stream (formats=\(streams.count))")
                completion(nil)
                return
            }
            let iosVersion = (UIDevice.current.systemVersion as NSString).floatValue
            if iosVersion >= 7.0 {
                if let u = URL(string: preferred.url) {
                    DebugLog.log("StreamResolver", "resolve id=\(video.id) -> direct itag=\(preferred.itag)")
                    completion(ResolvedStream(url: u, isLocal: false))
                } else {
                    DebugLog.log("StreamResolver", "resolve id=\(video.id) -> FAILED, invalid URL")
                    completion(nil)
                }
            } else if let local = StreamProxy.shared.localURL(for: preferred.url) {
                DebugLog.log("StreamResolver", "resolve id=\(video.id) -> proxy itag=\(preferred.itag)")
                completion(ResolvedStream(url: local, isLocal: false))
            } else {
                DebugLog.log("StreamResolver", "resolve id=\(video.id) -> FAILED, StreamProxy.localURL nil")
                completion(nil)
            }
        }
    }

    // Network-only half of resolve(): a completed download resolves immediately; otherwise the
    // innertube getStreams call runs and the FULL streams list is handed back UN-wrapped (no
    // StreamProxy route yet, no quality decision made). Safe to call ahead of time (prefetch)
    // without disturbing the active stream. completion fires on the main thread; nil = nothing
    // playable.
    static func prepare(_ video: Video, completion: @escaping (PreparedStream?) -> Void) {
        if DownloadManager.isDownloaded(video.id) {
            let url = URL(fileURLWithPath: DownloadManager.filePath(for: video.id))
            completion(.local(url))
            return
        }
        YoutubeAPI.getStreams(videoId: video.id) { streams, _, _ in
            guard pickPreferred(streams) != nil else {
                completion(nil)
                return
            }
            completion(.remote(streams))
        }
    }

    // Playback-time half: turn a PreparedStream into a playable ResolvedStream. Applies the
    // Default Video Quality preference first (via the local HLS transmux proxy); on iOS 6 this
    // is also where the StreamProxy route is finally registered (bumping the proxy generation at
    // the correct moment — the actual switch). Returns nil if the URL can't be built.
    static func finalize(_ prepared: PreparedStream) -> ResolvedStream? {
        switch prepared {
        case .local(let url):
            return ResolvedStream(url: url, isLocal: true)
        case .remote(let streams):
            if let vStream = defaultQualityStream(streams), let r = hlsResolvedStream(vStream, streams) {
                return r
            }
            guard let preferred = pickPreferred(streams) else { return nil }
            let iosVersion = (UIDevice.current.systemVersion as NSString).floatValue
            if iosVersion >= 7.0 {
                guard let u = URL(string: preferred.url) else { return nil }
                return ResolvedStream(url: u, isLocal: false)
            } else if let local = StreamProxy.shared.localURL(for: preferred.url) {
                return ResolvedStream(url: local, isLocal: false)
            }
            return nil
        }
    }
}
