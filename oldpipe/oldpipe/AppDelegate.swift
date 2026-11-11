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
let iPadFlexLeft: UIView.AutoresizingMask = [.flexibleLeftMargin]
#else
let iPadFlexWidth: UIView.AutoresizingMask = []
let iPadFlexWidthHeight: UIView.AutoresizingMask = []
let iPadFlexWidthTop: UIView.AutoresizingMask = []
let iPadFlexHeight: UIView.AutoresizingMask = []
let iPadFlexTop: UIView.AutoresizingMask = []
let iPadFlexLeft: UIView.AutoresizingMask = []
#endif

// MARK: - AppSettings
// Simple persisted user preferences (UserDefaults booleans). Kept at module scope so both
// SettingsVC (writes) and HomeVC (reads) can reach it without a shared instance. bool(forKey:)
// returns false for a missing key, so the default is OFF without any extra registration —
// and it sidesteps the 5.1.5 runtime's `as? Bool` NSNumber-nil gotcha.
enum AppSettings {
    private static let shortsOnHomeKey = "shorts_on_home"

    static var shortsOnHome: Bool {
        get { UserDefaults.standard.bool(forKey: shortsOnHomeKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: shortsOnHomeKey)
            UserDefaults.standard.synchronize()
        }
    }

    private static let defaultQualityKey = "default_quality"

    // "auto" = no preference, videos always start at the normal 360p path (the user picks
    // quality manually via the hd button, same as before). Otherwise "480"/"720"/"1080" —
    // VideoPlayerVC steps down through the HLS tiers when the exact pick isn't available
    // for a given video. A plain string (not bool) so String(forKey:) sidesteps the 5.1.5
    // runtime's `as? Bool`/`as? Int` NSNumber-nil gotcha entirely.
    static var defaultQuality: String {
        get { UserDefaults.standard.string(forKey: defaultQualityKey) ?? "auto" }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultQualityKey)
            UserDefaults.standard.synchronize()
        }
    }

    static func defaultQualityLabel() -> String {
        switch defaultQuality {
        case "480": return "480p"
        case "720": return "720p"
        case "1080": return "1080p"
        default: return "Auto (360p)"
        }
    }

    private static let lastDownloadChoiceKey = "last_download_choice"

    // The row label the download modal last confirmed ("720p60", "Audio only", ...). This
    // REPLACED a Download Quality setting: the modal shows every option with its size, so a
    // second place to express the same preference was redundant — and remembering the actual
    // choice beats a stored preference, since it needs no maintenance and covers "I only ever
    // download audio" without a dedicated option. Empty = nothing picked yet.
    //
    // A LABEL rather than an itag, so it survives a video that publishes a different ladder:
    // the modal matches it exactly first, then falls back to the closest tier at or below that
    // resolution. String-backed like every other key (the 5.1.5 `as? Int` gotcha).
    static var lastDownloadChoice: String {
        get { UserDefaults.standard.string(forKey: lastDownloadChoiceKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: lastDownloadChoiceKey)
            UserDefaults.standard.synchronize()
        }
    }

    private static let lastCaptionLanguagesKey = "last_caption_languages"

    // CaptionTrack keys ticked in the download modal last time, comma-joined ("en,fr|asr").
    // Same idea as lastDownloadChoice: remember the choice instead of asking for a setting.
    // Keys rather than indices, because the track list differs from video to video — the modal
    // re-ticks whichever of these the current video happens to offer.
    static var lastCaptionLanguages: [String] {
        get {
            let raw = UserDefaults.standard.string(forKey: lastCaptionLanguagesKey) ?? ""
            return raw.isEmpty ? [] : raw.components(separatedBy: ",")
        }
        set {
            UserDefaults.standard.set(newValue.joined(separator: ","), forKey: lastCaptionLanguagesKey)
            UserDefaults.standard.synchronize()
        }
    }

    private static let defaultFpsKey = "default_fps"

    // "30" (the default) or "60": which variant to take when a video publishes BOTH at the
    // resolution being played. A tie-breaker ONLY, never a filter — most 60fps uploads carry
    // no 30fps tier at all above 480p, so honouring this strictly would silently cap those
    // videos at 480p. Resolution always wins over frame rate. String-backed like the above.
    static var defaultFps: String {
        get { UserDefaults.standard.string(forKey: defaultFpsKey) ?? "30" }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultFpsKey)
            UserDefaults.standard.synchronize()
        }
    }

    static func defaultFpsLabel() -> String {
        return defaultFps == "60" ? "60 fps" : "30 fps"
    }

    private static let captionSizeKey = "caption_size"

    // Caption text size. "auto" (the default) scales with the width of the view the captions
    // are drawn in — the inline video container, or the whole screen in fullscreen — because
    // a flat point size that reads fine on a 320pt iPhone is tiny on an iPad. The rest pin it
    // to a fixed size. String-backed for the same reason as defaultQuality.
    static var captionSize: String {
        get { UserDefaults.standard.string(forKey: captionSizeKey) ?? "auto" }
        set {
            UserDefaults.standard.set(newValue, forKey: captionSizeKey)
            UserDefaults.standard.synchronize()
        }
    }

    // hostWidth is only consulted by "auto". Clamped so a phone in portrait stays legible
    // and an iPad in fullscreen doesn't end up with captions covering the picture.
    static func captionFontSize(hostWidth: CGFloat) -> CGFloat {
        switch captionSize {
        case "small": return 12
        case "medium": return 14
        case "large": return 18
        case "xlarge": return 22
        default: return min(28, max(12, floor(hostWidth * 0.035)))
        }
    }

    static func captionSizeLabel() -> String {
        switch captionSize {
        case "small": return "Small"
        case "medium": return "Medium"
        case "large": return "Large"
        case "xlarge": return "Extra Large"
        default: return "Auto"
        }
    }

    private static let captionLanguageKey = "caption_language"

    // The caption language to turn on by itself when a video opens. "off" (the default) keeps
    // captions off until picked in the player, as before; otherwise a primary language code
    // (Captions.primaryLanguage). A video gets its human-made track in that language, else its
    // auto-generated one, else no captions — never a machine translation. A track picked or
    // turned off in the player still wins for that video. String-backed like the rest.
    static var captionLanguage: String {
        get { UserDefaults.standard.string(forKey: captionLanguageKey) ?? "off" }
        set {
            UserDefaults.standard.set(newValue, forKey: captionLanguageKey)
            UserDefaults.standard.synchronize()
        }
    }

    // What the Settings sheet offers, in order: off, the device's own language when the list
    // lacks it, then languages YouTube captions often come in. Kept short so the sheet fits an
    // iPhone 4's screen.
    static func captionLanguageChoices() -> [String] {
        let common = ["en", "fr", "es", "pt", "de", "it", "ru", "ar", "ja", "zh"]
        let device = Captions.primaryLanguage(Locale.preferredLanguages.first ?? "en")
        return ["off"] + (common.contains(device) ? [] : [device]) + common
    }

    // English names, like the rest of the UI. NSLocale's displayName(forKey:value:) is iOS 2+;
    // Locale.localizedString(forLanguageCode:) would be iOS 10.
    static func captionLanguageName(_ code: String) -> String {
        guard code != "off" else { return "Off" }
        return NSLocale(localeIdentifier: "en").displayName(forKey: .languageCode, value: code) ?? code
    }

    static func captionLanguageLabel() -> String {
        return captionLanguageName(captionLanguage)
    }

    private static let debugLoggingKey = "debug_logging_enabled"

    // Off by default. When on, DebugLog.log(_:_:) records breadcrumbs through the playback
    // pipeline (Home tap -> stream resolution -> proxy -> AVPlayerItem status) so a user
    // hitting "video won't play" can copy a trace from Settings > Debug instead of us having
    // to reproduce it blind.
    static var debugLoggingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: debugLoggingKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: debugLoggingKey)
            UserDefaults.standard.synchronize()
        }
    }
}

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    // Checkpoint 3. UIApplicationMain builds the delegate before calling any of its
    // methods, so reaching here means the app image, the Swift runtime and
    // UIApplicationMain itself are all alive — narrowing the gap that marker 4 closes.
    override init() {
        super.init()
        CrashLog.mark("3. AppDelegate.init: UIApplicationMain reached delegate creation")
    }

    var window: UIWindow?
    private var miniBar: MiniPlayerBar?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // FIRST statement in the app's own code. If the log file is missing or empty after a
        // crash, the process died before this line — i.e. in dyld, the entry stub or Swift
        // runtime init — which narrows the search as sharply as any breadcrumb could.
        CrashLog.install()

        CrashLog.mark("nav: building HomeVC")
        let nav = UINavigationController(rootViewController: HomeVC())
        nav.navigationBar.barStyle = .black
        nav.navigationBar.tintColor = Theme.accent // YouTube red
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

        CrashLog.mark("window: creating")
        let win = PlayerWindow(frame: UIScreen.main.bounds)
        win.backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
        win.rootViewController = nav
        win.makeKeyAndVisible()
        window = win

        // Persistent mini player bar at the bottom of the window. It polls
        // VideoPlayer.shared and reopens the full player on tap.
        CrashLog.mark("miniBar: creating")
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
            nav.openVideo(video)
        }
        win.addSubview(bar)
        miniBar = bar

        // Required for lock-screen / headset transport controls (routed via PlayerWindow).
        UIApplication.shared.beginReceivingRemoteControlEvents()
        CrashLog.mark("didFinishLaunching: OK")
        return true
    }

    #if IOS5_TARGET
    // Emulator test hook. Only the iOS 5 build registers the oldpipe:// scheme (build-ios5.sh),
    // so `uiopen oldpipe://history/0` over SSH opens History's newest video the way a tap
    // would, which lets a video-page crash be chased with nobody at the screen.
    //   oldpipe://snapshot              the screen as Documents/snapshot.png
    //   oldpipe://scroll/<y>, oldpipe://back   scroll the top page / pop it
    //   oldpipe://search[/<query>]      open Search as its bar button does, optionally running <query>
    //   oldpipe://tap/<row>             select row <row> of the top page's list, as a tap would
    //   oldpipe://press/<action>[/<n>]  tap the top page's button or bar item wired to <action>,
    //                                   e.g. playTapped, channelTapped, toggleMenu; with <n>, the
    //                                   n-th such button from 0 (pillTapped/1 = the first group)
    //   oldpipe://cast/start/<ip>       cast History's newest video to a receiver at <ip>
    //   oldpipe://cast/<toggle|stop|next|queue>, cast/seek/<s>, cast/volume/<0-1>
    // The cast ones drive CastController the way the page's buttons do, against a stand-in
    // receiver, since the emulator can neither tap nor reach a real Chromecast.
    func application(_ application: UIApplication, open url: URL,
                     sourceApplication: String?, annotation: Any) -> Bool {
        if url.host == "snapshot" {
            saveSnapshot()
            return true
        }
        if url.host == "scroll", let y = Double(url.lastPathComponent),
           let nav = window?.rootViewController as? UINavigationController,
           let sv = nav.topViewController?.view.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
            sv.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            return true
        }
        if url.host == "back" {
            (window?.rootViewController as? UINavigationController)?.popViewController(animated: false)
            return true
        }
        if url.host == "search", let nav = window?.rootViewController as? UINavigationController {
            nav.goSearch()
            if url.pathComponents.count > 1, let page = nav.viewControllers.last as? SearchVC {
                page.search(for: url.lastPathComponent)
            }
            return true
        }
        if url.host == "tap", let row = Int(url.lastPathComponent),
           let page = (window?.rootViewController as? UINavigationController)?.topViewController {
            if let table = firstVisible(UITableView.self, in: page.view) {
                table.delegate?.tableView?(table, didSelectRowAt: IndexPath(row: row, section: 0))
            }
            return true
        }
        if url.host == "press",
           let page = (window?.rootViewController as? UINavigationController)?.topViewController {
            let args = Array(url.pathComponents.dropFirst())   // drop the leading "/"
            if let action = args.first {
                press(action, nth: args.count > 1 ? Int(args[1]) ?? 0 : 0, on: page)
            }
            return true
        }
        if url.host == "cast" {
            castHook(Array(url.pathComponents.dropFirst()))   // drop the leading "/"
            return true
        }
        guard url.host == "history", let n = Int(url.lastPathComponent) else { return true }
        let videos = HistoryManager.all()
        guard n >= 0, n < videos.count,
              let nav = window?.rootViewController as? UINavigationController else { return true }
        CrashLog.mark("url: opening history #\(n) \(videos[n].id)")
        nav.openVideo(videos[n])
        return true
    }

    private func saveSnapshot() {
        guard let win = window else { return }
        UIGraphicsBeginImageContextWithOptions(win.bounds.size, true, 0)
        defer { UIGraphicsEndImageContext() }
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        win.layer.render(in: ctx)
        guard let img = UIGraphicsGetImageFromCurrentImageContext(),
              let png = img.pngData() else { return }
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        (png as NSData).write(toFile: docs + "/snapshot.png", atomically: true)
    }

    private func castHook(_ args: [String]) {
        let cast = CastController.shared
        CrashLog.mark("url: cast \(args.joined(separator: " "))")
        switch args.first ?? "" {
        case "start":
            guard args.count > 1, let v = HistoryManager.all().first else { return }
            cast.cast(v, on: CastDevice(name: "FakeTV", host: args[1], port: 8009))
        case "queue":
            // History as a playlist queue, the way PlaylistDetailVC seeds one: autoplay and
            // Next then walk it.
            VideoPlayer.shared.setQueue(HistoryManager.all(), startIndex: 0)
        case "toggle": cast.togglePlayPause()
        case "stop": cast.stop()
        case "next": if let v = cast.video { cast.skipToNext(from: v.id) }
        case "seek": if args.count > 1, let s = Double(args[1]) { cast.seek(to: s) }
        case "volume": if args.count > 1, let l = Double(args[1]) { cast.setVolume(l) }
        default: break
        }
    }

    // What a tap on a control does: its actions are sent, so the page runs its own code path.
    // Bar items first (Home's menu is one), then any visible button in the page's view whose
    // touch-up action is named `action`, with or without the colon of a sender argument.
    private func press(_ action: String, nth: Int, on page: UIViewController) {
        CrashLog.mark("url: press \(action) \(nth)")
        func wired(_ name: String) -> Bool { return name == action || name == action + ":" }
        var skip = nth
        let items = (page.navigationItem.leftBarButtonItems ?? []) + (page.navigationItem.rightBarButtonItems ?? [])
        if let item = items.first(where: { $0.action.map { wired(NSStringFromSelector($0)) } ?? false }),
           let sel = item.action {
            UIApplication.shared.sendAction(sel, to: item.target, from: item, for: nil)
            return
        }
        var queue: [UIView] = [page.view]
        while !queue.isEmpty {
            let v = queue.removeFirst()
            if let b = v as? UIButton, b.isEnabled,
               b.allTargets.contains(where: { (b.actions(forTarget: $0.base, forControlEvent: .touchUpInside) ?? []).contains(where: wired) }) {
                if skip == 0 {
                    b.sendActions(for: .touchUpInside)
                    return
                }
                skip -= 1
            }
            // Not into a hidden view: nothing inside one can be tapped (an empty screen's button
            // while the list is showing).
            queue.append(contentsOf: v.subviews.filter { !$0.isHidden })
        }
    }

    // Breadth-first, so the page's own list wins over one nested further down.
    private func firstVisible<T: UIView>(_ type: T.Type, in root: UIView) -> T? {
        var queue: [UIView] = [root]
        while !queue.isEmpty {
            let v = queue.removeFirst()
            if let hit = v as? T, !hit.isHidden { return hit }
            queue.append(contentsOf: v.subviews.filter { !$0.isHidden })
        }
        return nil
    }
    #endif

    // On return from the background, iOS may have (a) torn down StreamProxy's loopback listen
    // socket and (b) deactivated our audio session while suspended. Both leave a resumed app
    // unable to start a new proxied stream — it stalls and falls back to download. Rebuild the
    // proxy listener if it is dead (next play re-binds a fresh port; a live one keeps serving
    // the video still playing) and re-activate the audio session.
    func applicationDidBecomeActive(_ application: UIApplication) {
        DebugLog.log("App", "applicationDidBecomeActive — checking proxy listener + reactivating audio session")
        StreamProxy.shared.resetIfDead()
        VideoPlayer.shared.reactivateSession()
        // The Chromecast connection rarely survives a suspension: rejoin what the TV is playing
        // (or, on a cold launch, the cast that was on when iOS killed the app).
        CastController.shared.appDidBecomeActive()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        CastController.shared.appDidEnterBackground()
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
