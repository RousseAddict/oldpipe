import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var miniBar: MiniPlayerBar?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let nav = UINavigationController(rootViewController: HomeVC())
        nav.navigationBar.barStyle = .black
        nav.navigationBar.tintColor = UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 1) // YouTube red

        let win = PlayerWindow(frame: UIScreen.main.bounds)
        win.backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
        win.rootViewController = nav
        win.makeKeyAndVisible()
        window = win

        // Persistent mini player bar at the bottom of the window. It polls
        // VideoPlayer.shared and reopens the full player on tap.
        let barH = MiniPlayerBar.barHeight
        let bar = MiniPlayerBar(frame: CGRect(x: 0, y: win.bounds.height - barH,
                                              width: win.bounds.width, height: barH))
        bar.navProvider = { [weak nav] in nav }
        bar.onOpen = { [weak nav] video in
            guard let nav = nav else { return }
            if nav.topViewController is VideoPlayerVC { return }
            nav.pushViewController(VideoPlayerVC(video: video), animated: true)
        }
        win.addSubview(bar)
        miniBar = bar

        // Required for lock-screen / headset transport controls (routed via PlayerWindow).
        UIApplication.shared.beginReceivingRemoteControlEvents()
        return true
    }

    // Chain-endpoint fallback for remote-control events (PlayerWindow handles them first).
    override func remoteControlReceived(with event: UIEvent?) {
        guard let event = event, event.type == .remoteControl else { return }
        VideoPlayer.shared.handleRemoteControl(event.subtype)
    }
}

// A window subclass that catches lock-screen / headset transport events. The window is
// always in the responder chain (unlike a VC's first-responder, which only works while a
// VideoPlayerVC is on screen), so transport keeps working with the player popped.
class PlayerWindow: UIWindow {
    override func remoteControlReceived(with event: UIEvent?) {
        guard let event = event, event.type == .remoteControl else {
            super.remoteControlReceived(with: event)
            return
        }
        VideoPlayer.shared.handleRemoteControl(event.subtype)
    }
}
