import UIKit

// MARK: - Navigator
// Every screen that opens a video, a channel or a YouTube playlist goes through here, so what
// Back does is decided in one place instead of at each push site.
//
// The stack is the user's trail and Back walks it: video -> related -> related takes one Back
// per hop, through each video in turn. The one exception is opening the page Back would land
// on (the channel a video was opened from, the video a related row was tapped on), which IS a
// Back, so it pops instead of stacking a second copy of that page.
// A deep trail is left through the Home and Search buttons below, not by trimming it.

extension UINavigationController {

    func openVideo(_ video: Video) {
        // An older page of the same video further down is left alone: a fresh VideoPlayerVC on
        // the playing video reattaches to live playback (the mini bar's own path).
        if (pageBelowTop as? VideoPlayerVC)?.video.id == video.id {
            popViewController(animated: true)
            return
        }
        pushViewController(VideoPlayerVC(video: video), animated: true)
    }

    // Plays a playlist in random order. Only the queue is shuffled — the playlist's own order
    // is untouched — and autoplay walks it like any other queue, stopping at the end.
    // Tapping a row afterwards seeds the in-order queue again, which is what ends shuffle.
    func openShuffled(_ videos: [Video]) {
        guard !videos.isEmpty else { return }
        let order = videos.shuffled()   // pure stdlib, same as HomeVC's feed shuffle
        VideoPlayer.shared.setQueue(order, startIndex: 0)
        openVideo(order[0])
    }

    func openChannel(id: String, name: String) {
        if (pageBelowTop as? ChannelVC)?.channelId == id {
            popViewController(animated: true)
            return
        }
        pushViewController(ChannelVC(channelId: id, name: name), animated: true)
    }

    func openYTPlaylist(id: String, title: String) {
        if (pageBelowTop as? YTPlaylistVC)?.playlistId == id {
            popViewController(animated: true)
            return
        }
        pushViewController(YTPlaylistVC(playlistId: id, title: title), animated: true)
    }

    // The page Back would land on; nil on the root.
    private var pageBelowTop: UIViewController? {
        let stack = viewControllers
        return stack.count >= 2 ? stack[stack.count - 2] : nil
    }

    // MARK: - Quick exits
    // A trail can run many pages deep, and iOS 6 has no swipe-back, so the pages it runs
    // through (video, channel, YouTube playlist) carry one-tap ways out of it:
    //   - Home goes back to the root page.
    //   - Search leaves just Home > Search. The Search page already in the stack is reused, so
    //     the last query and its results are still there.
    // Both drop the trail; playback carries on in the mini bar, as on any pop.

    func goHome() {
        popToRootViewController(animated: true)
    }

    func goSearch() {
        guard let root = viewControllers.first else { return }
        let search = viewControllers.first(where: { $0 is SearchVC }) as? SearchVC ?? SearchVC()
        search.focusOnAppear = true
        // Animates as a pop when the Search page was already in the stack, a push when it is new.
        setViewControllers([root, search], animated: true)
    }
}

// The Home / Search bar items. A bar item does not retain its target, so every page's items
// share this one long-lived object, which acts on the app's single navigation stack.
final class QuickExits: NSObject {

    private static let shared = QuickExits()

    // Image-only (Phosphor house and magnifying-glass) so two fit beside a title at 320pt.
    // Search is rightmost, where Home's own Search button sits.
    static func items(search: Bool = true) -> [UIBarButtonItem] {
        let home = UIBarButtonItem(image: UIImage(named: "home"), style: .plain,
                                   target: shared, action: #selector(QuickExits.homeTapped))
        guard search else { return [home] }
        let find = UIBarButtonItem(image: UIImage(named: "search"), style: .plain,
                                   target: shared, action: #selector(QuickExits.searchTapped))
        return [find, home]   // rightBarButtonItems run right to left
    }

    private var nav: UINavigationController? {
        return (UIApplication.shared.delegate as? AppDelegate)?.window?.rootViewController
            as? UINavigationController
    }

    @objc private func homeTapped() { nav?.goHome() }
    @objc private func searchTapped() { nav?.goSearch() }
}
