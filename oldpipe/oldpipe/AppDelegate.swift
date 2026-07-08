import UIKit

// Autoresizing masks used by the iPad (iOS 8) rotation reflow. On the iOS 6/7 build
// (-D IOS6_TARGET) these compile to [] — the UIView default — so subview layout stays
// fixed exactly as the original app. This matters because the iOS 6 in-call / double-height
// status bar resizes the app window, and a flexible mask would (newly) reflow subviews;
// compiling to [] guarantees iOS 6 iPhone behavior is byte-for-byte untouched. Only the
// iOS 8 build (-D IOS8_TARGET) gets the real flexible masks that drive iPad reflow.
#if IOS8_TARGET
let iPadFlexWidth: UIView.AutoresizingMask = [.flexibleWidth]
let iPadFlexWidthHeight: UIView.AutoresizingMask = [.flexibleWidth, .flexibleHeight]
let iPadFlexWidthTop: UIView.AutoresizingMask = [.flexibleWidth, .flexibleTopMargin]
let iPadFlexHeight: UIView.AutoresizingMask = [.flexibleHeight]
let iPadFlexTop: UIView.AutoresizingMask = [.flexibleTopMargin]
#else
let iPadFlexWidth: UIView.AutoresizingMask = []
let iPadFlexWidthHeight: UIView.AutoresizingMask = []
let iPadFlexWidthTop: UIView.AutoresizingMask = []
let iPadFlexHeight: UIView.AutoresizingMask = []
let iPadFlexTop: UIView.AutoresizingMask = []
#endif

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var miniBar: MiniPlayerBar?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let nav = UINavigationController(rootViewController: HomeVC())
        nav.navigationBar.barStyle = .black
        nav.navigationBar.tintColor = UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 1) // YouTube red
        #if IOS8_TARGET || IOS7_TARGET
        // See the UINavigationControllerDelegate extension below — clear the extended-layout
        // edges so every screen starts BELOW the (translucent, iOS 7+) bars, matching the
        // iOS-6 layout model the app is written in. Set on the delegate for pushed VCs AND
        // directly on the root so the first screen is correct before it lays out. This is the
        // iOS-8 *UI* fix, so it's ALSO compiled into the iOS 7 build (which is the iOS-6
        // behavior + this UI fix, but WITHOUT the iPad rotation mechanics). The iOS 6 build
        // does NOT compile it, so its layout is provably untouched.
        nav.delegate = self
        nav.topViewController?.edgesForExtendedLayout = []
        nav.topViewController?.extendedLayoutIncludesOpaqueBars = false
        #endif

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
        // iPad: keep the bar pinned to the bottom and full width when the window rotates.
        // iOS 6/7 build: [] (default) — the window is fixed portrait so this is a no-op.
        bar.autoresizingMask = iPadFlexWidthTop
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

#if IOS8_TARGET || IOS7_TARGET
// iOS 7+ lays a VC's view UNDER the translucent nav + status bar by default
// (edgesForExtendedLayout = .all). The whole app is written in the iOS-6 layout model
// (content y=0 sits just below an OPAQUE bar), so on iOS 7/8 every screen's top content
// hides behind the bar on first appear — and only self-corrects after a rotation forces a
// fresh layout pass. Clearing the extended edges on each pushed VC makes its view start
// below the bars, restoring the iOS-6 model. Compiled into BOTH the iOS 8 build and the
// iOS 7 build (iOS-6 behavior + this UI fix); the iOS 6 build excludes it, so its layout is
// provably untouched.
extension AppDelegate: UINavigationControllerDelegate {
    func navigationController(_ navigationController: UINavigationController,
                              willShow viewController: UIViewController, animated: Bool) {
        viewController.edgesForExtendedLayout = []
        viewController.extendedLayoutIncludesOpaqueBars = false
    }
}
#endif
