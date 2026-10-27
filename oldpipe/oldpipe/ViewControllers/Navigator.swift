import UIKit

// MARK: - Navigator
// Every screen that opens a video, a channel or a YouTube playlist goes through here, so what
// Back does is decided in one place instead of at each push site.
//
// The stack is the user's BROWSING trail (Home, Search, a channel, a playlist). Watching is not
// a place, so:
//   - At most one video page is ever in the stack. Opening a video drops any older one, which
//     makes video -> related video a replacement (one Back to the list it came from), and
//     video -> channel -> video leave just the channel behind the new page.
//   - A channel or playlist already in the stack is gone back to, never pushed a second time.
// Dropping a video page never stops playback: VideoPlayer.shared owns it and the mini bar takes
// over, exactly as on a pop.

extension UINavigationController {

    func openVideo(_ video: Video) {
        // Always a fresh page, even for a video already open further down: a new VideoPlayerVC
        // on the playing video reattaches to live playback (the mini bar's own path), so the
        // buried one holds nothing worth moving. A dropped page already ran viewWillDisappear
        // when it was covered, so its singleton callbacks and timers are released.
        // setViewControllers (iOS 3+) animates as a plain push since the new top is new.
        var stack = viewControllers.filter { !($0 is VideoPlayerVC) }
        stack.append(VideoPlayerVC(video: video))
        setViewControllers(stack, animated: true)
    }

    func openChannel(id: String, name: String) {
        if let existing = viewControllers.first(where: { ($0 as? ChannelVC)?.channelId == id }) {
            popToViewController(existing, animated: true)
            return
        }
        pushViewController(ChannelVC(channelId: id, name: name), animated: true)
    }

    func openYTPlaylist(id: String, title: String) {
        if let existing = viewControllers.first(where: { ($0 as? YTPlaylistVC)?.playlistId == id }) {
            popToViewController(existing, animated: true)
            return
        }
        pushViewController(YTPlaylistVC(playlistId: id, title: title), animated: true)
    }
}
