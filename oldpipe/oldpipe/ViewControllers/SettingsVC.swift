import UIKit

// MARK: - SettingsVC
// One scrolling form: Preferences, Export, Import, Cache, Reset All, Debug.
//
// Export / import carry the user's config (subscriptions + playlists) as plain JSON text.
// iOS 6 has no usable file-sharing / document infrastructure, so transport is the
// system pasteboard: Export builds a pretty-printed JSON blob into a read-only text
// view (+ Copy button); Import parses pasted JSON and MERGES it into existing data
// (subscriptions de-duplicated by channel id, playlists upserted by playlist id).
//
// Rows are built by addPreferenceRow / addSwitchRow / addHeader / addSubtitle, which each
// take `y` as inout and advance it — the form is laid out by manual running offset, so a
// row that forgets to advance silently stacks on top of the next one.

class SettingsVC: UIViewController, UIGestureRecognizerDelegate, UIAlertViewDelegate, UIActionSheetDelegate {

    private var scrollView: UIScrollView!
    private var exportView: UITextView!
    private var importView: UITextView!
    private var statusLabel: UILabel!
    private var cacheSizeLabel: UILabel!
    private var debugCountLabel: UILabel!
    private var copyBtn: UIButton?
    private var qualityBtn: UIButton?
    private var fpsBtn: UIButton?
    private var captionSizeBtn: UIButton?
    private var copyDebugBtn: UIButton?
    private var copyCrashBtn: UIButton?
    private var didSetupUI = false
    private var loadingSpinner: UIActivityIndicatorView?

    private let bg = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
    private let fieldBg = UIColor(white: 0.12, alpha: 1)

    // The two slow bits of loading Settings — serializing every subscription/playlist to JSON
    // and scanning the on-disk thumbnail cache to sum its size — run here off the main thread
    // so the screen shows a spinner instead of freezing.
    private static let loadQueue = AppQueue(label: "com.oldpipe.settings.load")

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = bg

        // Spinner shown while the (deferred) heavy load runs — visible during the push and
        // until loadHeavyData finishes.
        let spin = UIActivityIndicatorView(style: .whiteLarge)
        spin.center = CGPoint(x: UIScreen.main.bounds.width / 2, y: (UIScreen.main.bounds.height - 64) / 2)
        spin.startAnimating()
        view.addSubview(spin)
        loadingSpinner = spin
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didSetupUI else { return }
        didSetupUI = true
        setupUI()
        loadHeavyData()
    }

    // Compute the export JSON + disk-cache size on a background queue, then fill the fields and
    // remove the spinner on the main thread.
    private func loadHeavyData() {
        SettingsVC.loadQueue.async { [weak self] in
            let json = self?.buildExportJSON() ?? "{}"
            let bytes = AsyncImageView.diskCacheSize()
            AppQueue.main.async {
                guard let self = self else { return }
                self.exportView.text = json
                self.cacheSizeLabel.text = "Current cache size: \(self.formatBytes(bytes))"
                self.loadingSpinner?.stopAnimating()
                self.loadingSpinner?.removeFromSuperview()
                self.loadingSpinner = nil
            }
        }
    }

    private func setupUI() {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        let navH: CGFloat = 64
        let pad: CGFloat = 16
        let contentW = w - pad * 2

        scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: w, height: h - navH))
        scrollView.backgroundColor = bg
        // iPad rotates natively; the flexible masks (here + on every child below, via the
        // layout helpers) stretch the form to the landscape width. iPhone is portrait-locked
        // in the pbxproj so autoresizing never triggers there.
        scrollView.autoresizingMask = iPadFlexWidthHeight
        view.addSubview(scrollView)

        // Tap anywhere outside the import field to dismiss the keyboard. cancelsTouchesInView
        // = false so the tap still reaches the Copy/Paste/Import buttons (iOS 6 button-tap
        // conflict avoided); the delegate ignores taps that land inside importView itself.
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        scrollView.addGestureRecognizer(tap)

        var y: CGFloat = 16

        // ── Preferences ────────────────────────────────────────────────────────────
        y = addHeader("Preferences", at: y, width: contentW, pad: pad)

        addSwitchRow(subtitle: "Show a Shorts tab on the Home screen with short videos from your subscribed channels.",
                     label: "Enable Shorts on Home Screen",
                     isOn: AppSettings.shortsOnHome,
                     action: #selector(shortsSwitchChanged(_:)),
                     at: &y, screenWidth: w, width: contentW, pad: pad)

        qualityBtn = addPreferenceRow(
            subtitle: "Automatically use this quality for playback instead of picking each time (falls back to a lower tier if the exact quality isn't available for a video).",
            title: "Default Quality: \(AppSettings.defaultQualityLabel())",
            action: #selector(qualityTapped), at: &y, width: contentW, pad: pad)

        fpsBtn = addPreferenceRow(
            subtitle: "Which version to play when a video offers the same quality at both frame rates. Videos published only at 60 fps still play at 60 fps.",
            title: "Frame Rate: \(AppSettings.defaultFpsLabel())",
            action: #selector(fpsTapped), at: &y, width: contentW, pad: pad)

        // NOTE: there is deliberately NO download-quality row. The download modal lists every
        // option with its size and remembers what was picked last, so a stored preference here
        // would be a second, worse way to say the same thing.
        captionSizeBtn = addPreferenceRow(
            subtitle: "Size of the closed-caption text during playback. Auto scales it with the size of the video on screen.",
            title: "Caption Size: \(AppSettings.captionSizeLabel())",
            action: #selector(captionSizeTapped), at: &y, width: contentW, pad: pad)

        y += 16

        // ── Export ───────────────────────────────────────────────────────────────
        y = addHeader("Export", at: y, width: contentW, pad: pad)
        y = addSubtitle("Copy this text somewhere safe (Notes, email). It contains your subscriptions and playlists.",
                        at: y, width: contentW, pad: pad)

        exportView = UITextView(frame: CGRect(x: pad, y: y, width: contentW, height: 150))
        exportView.backgroundColor = fieldBg
        exportView.textColor = UIColor(white: 0.9, alpha: 1)
        exportView.font = UIFont(name: "Courier", size: 12) ?? UIFont.systemFont(ofSize: 12)
        exportView.isEditable = false   // NOTE: do NOT set isSelectable — it's iOS 7+ and crashes on iOS 6
        exportView.layer.cornerRadius = 6
        exportView.autoresizingMask = iPadFlexWidth
        scrollView.addSubview(exportView)
        y += 150 + 10

        let copy = makeButton("Copy to Clipboard", at: y, width: contentW, pad: pad, accent: false)
        copy.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        scrollView.addSubview(copy)
        copyBtn = copy
        y += 44 + 28

        // ── Import ───────────────────────────────────────────────────────────────
        y = addHeader("Import", at: y, width: contentW, pad: pad)
        y = addSubtitle("Paste exported text below, then tap Import. Your current data is kept; new items are merged in.",
                        at: y, width: contentW, pad: pad)

        importView = UITextView(frame: CGRect(x: pad, y: y, width: contentW, height: 150))
        importView.backgroundColor = fieldBg
        importView.textColor = UIColor(white: 0.9, alpha: 1)
        importView.font = UIFont(name: "Courier", size: 12) ?? UIFont.systemFont(ofSize: 12)
        importView.isEditable = true
        importView.layer.cornerRadius = 6
        importView.autoresizingMask = iPadFlexWidth
        scrollView.addSubview(importView)
        y += 150 + 10

        let paste = makeButton("Paste from Clipboard", at: y, width: contentW, pad: pad, accent: false)
        paste.addTarget(self, action: #selector(pasteTapped), for: .touchUpInside)
        scrollView.addSubview(paste)
        y += 44 + 10

        let importBtn = makeButton("Import", at: y, width: contentW, pad: pad, accent: true)
        importBtn.addTarget(self, action: #selector(importTapped), for: .touchUpInside)
        scrollView.addSubview(importBtn)
        y += 44 + 28

        // ── Cache ──────────────────────────────────────────────────────────────────
        y = addHeader("Cache", at: y, width: contentW, pad: pad)
        y = addSubtitle("Clears the cached home feed and downloaded thumbnails. Your subscriptions and playlists are kept.",
                        at: y, width: contentW, pad: pad)

        cacheSizeLabel = UILabel(frame: CGRect(x: pad, y: y, width: contentW, height: 20))
        cacheSizeLabel.backgroundColor = .clear
        cacheSizeLabel.textColor = UIColor(white: 0.7, alpha: 1)
        cacheSizeLabel.font = UIFont.boldSystemFont(ofSize: 13)
        cacheSizeLabel.autoresizingMask = iPadFlexWidth
        cacheSizeLabel.text = "Calculating cache size\u{2026}"
        scrollView.addSubview(cacheSizeLabel)
        y += 20 + 8

        let resetBtn = makeButton("Reset Cache", at: y, width: contentW, pad: pad, accent: true)
        resetBtn.addTarget(self, action: #selector(resetTapped), for: .touchUpInside)
        scrollView.addSubview(resetBtn)
        y += 44 + 28

        // ── Reset All ────────────────────────────────────────────────────────────────
        y = addHeader("Reset All", at: y, width: contentW, pad: pad)
        y = addSubtitle("Erases everything: subscriptions, playlists, watch history, downloads and all caches. This cannot be undone.",
                        at: y, width: contentW, pad: pad)

        let resetAllBtn = makeButton("Reset All", at: y, width: contentW, pad: pad, accent: true)
        resetAllBtn.addTarget(self, action: #selector(resetAllTapped), for: .touchUpInside)
        scrollView.addSubview(resetAllBtn)
        y += 44 + 12

        statusLabel = UILabel(frame: CGRect(x: pad, y: y, width: contentW, height: 40))
        statusLabel.backgroundColor = .clear
        statusLabel.textColor = UIColor(white: 0.55, alpha: 1)
        statusLabel.font = UIFont.systemFont(ofSize: 13)
        statusLabel.numberOfLines = 2
        statusLabel.autoresizingMask = iPadFlexWidth
        scrollView.addSubview(statusLabel)
        y += 40 + 16

        // ── Debug ──────────────────────────────────────────────────────────────────
        y = addHeader("Debug", at: y, width: contentW, pad: pad)

        addSwitchRow(subtitle: "Records a breadcrumb trail through video playback to help diagnose \"video won't play\" reports. Off by default, no cost when disabled.",
                     label: "Enable Debug Logging",
                     isOn: AppSettings.debugLoggingEnabled,
                     action: #selector(debugSwitchChanged(_:)),
                     at: &y, screenWidth: w, width: contentW, pad: pad)

        debugCountLabel = UILabel(frame: CGRect(x: pad, y: y, width: contentW, height: 20))
        debugCountLabel.backgroundColor = .clear
        debugCountLabel.textColor = UIColor(white: 0.7, alpha: 1)
        debugCountLabel.font = UIFont.boldSystemFont(ofSize: 13)
        debugCountLabel.autoresizingMask = iPadFlexWidth
        debugCountLabel.text = "\(DebugLog.count()) log entries"
        scrollView.addSubview(debugCountLabel)
        y += 20 + 8

        let copyDebug = makeButton("Copy Debug Log", at: y, width: contentW, pad: pad, accent: false)
        copyDebug.addTarget(self, action: #selector(copyDebugTapped), for: .touchUpInside)
        scrollView.addSubview(copyDebug)
        copyDebugBtn = copyDebug
        y += 44 + 10

        let clearDebug = makeButton("Clear Debug Log", at: y, width: contentW, pad: pad, accent: false)
        clearDebug.addTarget(self, action: #selector(clearDebugTapped), for: .touchUpInside)
        scrollView.addSubview(clearDebug)
        y += 44 + 28

        // The crash log is separate from the debug log above: always recorded, written straight
        // to disk, and it covers the launch path — so it is the one to ask a user for when the
        // app dies before it can show anything.
        let crashHint = UILabel(frame: CGRect(x: pad, y: y, width: contentW, height: 34))
        crashHint.backgroundColor = .clear
        crashHint.textColor = UIColor(white: 0.55, alpha: 1)
        crashHint.font = UIFont.systemFont(ofSize: 11)
        crashHint.numberOfLines = 2
        crashHint.autoresizingMask = iPadFlexWidth
        crashHint.text = "Crash log is always on. If the app won't start, copy the file(s) named oldpipe-launch*.log from the app's Documents folder."
        scrollView.addSubview(crashHint)
        y += 34 + 6

        let copyCrash = makeButton("Copy Crash Log", at: y, width: contentW, pad: pad, accent: false)
        copyCrash.addTarget(self, action: #selector(copyCrashTapped), for: .touchUpInside)
        scrollView.addSubview(copyCrash)
        copyCrashBtn = copyCrash
        y += 44 + 28

        scrollView.contentSize = CGSize(width: w, height: y + 80)   // +80 covers mini player bar
    }

    // MARK: - Preferences

    @objc private func shortsSwitchChanged(_ sender: UISwitch) {
        AppSettings.shortsOnHome = sender.isOn
    }

    // Sheet tags are a space of their own here (VideoPlayerVC uses 1-7 for its own sheets):
    // 10 = playback quality, 11 = caption size, 12 = frame rate. 13 was the download quality
    // sheet, removed with that setting — free to reuse.
    //
    // Empty init + addButton, NOT the variadic otherButtonTitles: convenience init, which
    // crashes on the 5.1.5 runtime.
    private func showChoiceSheet(tag: Int, title: String, options: [String]) {
        let sheet = UIActionSheet()
        sheet.delegate = self
        sheet.tag = tag
        sheet.title = title
        for o in options { sheet.addButton(withTitle: o) }
        sheet.addButton(withTitle: "Cancel")
        sheet.cancelButtonIndex = options.count
        sheet.show(in: view)
    }

    @objc private func qualityTapped() {
        showChoiceSheet(tag: 10, title: "Default Video Quality",
                        options: ["Auto (360p)", "480p", "720p", "1080p"])
    }

    @objc private func fpsTapped() {
        showChoiceSheet(tag: 12, title: "Frame Rate", options: ["30 fps", "60 fps"])
    }

    @objc private func captionSizeTapped() {
        showChoiceSheet(tag: 11, title: "Caption Size",
                        options: ["Auto", "Small", "Medium", "Large", "Extra Large"])
    }

    // The sheets all have the same shape: an index-aligned value list, then store + retitle.
    // The Cancel button sits one past the end of `values`, so an out-of-range index — Cancel,
    // or a dismissal — falls through apply() and changes nothing.
    func actionSheet(_ actionSheet: UIActionSheet, clickedButtonAt buttonIndex: Int) {
        switch actionSheet.tag {
        case 10:
            apply(["auto", "480", "720", "1080"], buttonIndex) {
                AppSettings.defaultQuality = $0
                self.qualityBtn?.setTitle("Default Quality: \(AppSettings.defaultQualityLabel())", for: .normal)
            }
        case 11:
            apply(["auto", "small", "medium", "large", "xlarge"], buttonIndex) {
                AppSettings.captionSize = $0
                self.captionSizeBtn?.setTitle("Caption Size: \(AppSettings.captionSizeLabel())", for: .normal)
            }
        case 12:
            apply(["30", "60"], buttonIndex) {
                AppSettings.defaultFps = $0
                self.fpsBtn?.setTitle("Frame Rate: \(AppSettings.defaultFpsLabel())", for: .normal)
            }
        default:
            break
        }
    }

    private func apply(_ values: [String], _ index: Int, _ set: (String) -> Void) {
        guard index >= 0, index < values.count else { return }
        set(values[index])
    }

    // MARK: - Debug

    @objc private func debugSwitchChanged(_ sender: UISwitch) {
        AppSettings.debugLoggingEnabled = sender.isOn
    }

    @objc private func copyDebugTapped() {
        UIPasteboard.general.string = DebugLog.exportText()
        flash(copyDebugBtn, "Copied \u{2713}", revertTo: "Copy Debug Log")
    }

    @objc private func copyCrashTapped() {
        UIPasteboard.general.string = CrashLog.exportText()
        flash(copyCrashBtn, "Copied \u{2713}", revertTo: "Copy Crash Log")
    }

    @objc private func clearDebugTapped() {
        DebugLog.clear()
        debugCountLabel.text = "0 log entries"
    }

    // MARK: - Cache size

    private func refreshCacheSize() {
        cacheSizeLabel.text = "Calculating cache size\u{2026}"
        SettingsVC.loadQueue.async { [weak self] in
            let bytes = AsyncImageView.diskCacheSize()
            AppQueue.main.async {
                guard let self = self else { return }
                self.cacheSizeLabel.text = "Current cache size: \(self.formatBytes(bytes))"
            }
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes <= 0 { return "0 KB" }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        if mb >= 1.0 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024.0)
    }

    // MARK: - Layout helpers

    // One preference row: explanatory subtitle + a button that opens its choice sheet. Returns
    // the button so the caller can keep it and retitle it after a pick.
    @discardableResult
    private func addPreferenceRow(subtitle: String, title: String, action: Selector,
                                  at y: inout CGFloat, width: CGFloat, pad: CGFloat) -> UIButton {
        y = addSubtitle(subtitle, at: y, width: width, pad: pad)
        let b = makeButton(title, at: y, width: width, pad: pad, accent: false)
        b.addTarget(self, action: action, for: .touchUpInside)
        scrollView.addSubview(b)
        y += 44 + 12
        return b
    }

    // One switch row: subtitle, then a right-anchored UISwitch with its label filling the space
    // to the left. The switch is built FIRST on purpose — on iOS 6 a UISwitch is ~79pt wide
    // (vs ~51pt on later OSes), so sizing the label against a fixed gutter let long text run
    // underneath it. Right-anchored so it stays pinned when the iPad form widens.
    private func addSwitchRow(subtitle: String, label text: String, isOn: Bool, action: Selector,
                              at y: inout CGFloat, screenWidth w: CGFloat,
                              width: CGFloat, pad: CGFloat) {
        y = addSubtitle(subtitle, at: y, width: width, pad: pad)
        let rowH: CGFloat = 44

        let sw = UISwitch()
        let swW = max(sw.bounds.width, 51)
        sw.frame = CGRect(x: w - pad - swW, y: y + (rowH - sw.bounds.height) / 2,
                          width: swW, height: sw.bounds.height)
        sw.onTintColor = Theme.accent
        sw.isOn = isOn
        sw.autoresizingMask = iPadFlexLeft
        sw.addTarget(self, action: action, for: .valueChanged)
        scrollView.addSubview(sw)

        let l = UILabel(frame: CGRect(x: pad, y: y, width: sw.frame.origin.x - pad - 10, height: rowH))
        l.backgroundColor = .clear
        l.textColor = .white
        l.font = UIFont.systemFont(ofSize: 16)
        l.adjustsFontSizeToFitWidth = true
        #if IOS5_TARGET
        // minimumScaleFactor is iOS 6; its iOS 2 predecessor is an absolute size.
        // Swift hides minimumFontSize outright (pre-iOS-7 deprecations are marked
        // unavailable), so it has to be reached through KVC.
        l.setValue(12.8, forKey: "minimumFontSize")   // 16pt * 0.8
        #else
        l.minimumScaleFactor = 0.8
        #endif
        l.text = text
        l.autoresizingMask = iPadFlexWidth
        scrollView.addSubview(l)
        y += rowH + 12
    }

    private func addHeader(_ text: String, at y: CGFloat, width: CGFloat, pad: CGFloat) -> CGFloat {
        let l = UILabel(frame: CGRect(x: pad, y: y, width: width, height: 26))
        l.backgroundColor = .clear
        l.textColor = .white
        l.font = UIFont.boldSystemFont(ofSize: 20)
        l.text = text
        l.autoresizingMask = iPadFlexWidth
        scrollView.addSubview(l)
        return y + 26 + 4
    }

    private func addSubtitle(_ text: String, at y: CGFloat, width: CGFloat, pad: CGFloat) -> CGFloat {
        let l = UILabel(frame: CGRect(x: pad, y: y, width: width, height: 44))
        l.backgroundColor = .clear
        l.textColor = UIColor(white: 0.55, alpha: 1)
        l.font = UIFont.systemFont(ofSize: 13)
        l.numberOfLines = 0
        l.text = text
        l.autoresizingMask = iPadFlexWidth
        scrollView.addSubview(l)
        return y + 44 + 8
    }

    private func makeButton(_ title: String, at y: CGFloat, width: CGFloat, pad: CGFloat, accent isAccent: Bool) -> UIButton {
        let b = UIButton(type: .custom)
        b.frame = CGRect(x: pad, y: y, width: width, height: 44)
        b.setTitle(title, for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        b.backgroundColor = isAccent ? Theme.accent : UIColor(white: 0.20, alpha: 1)
        b.layer.cornerRadius = 8
        b.autoresizingMask = iPadFlexWidth
        return b
    }

    // MARK: - Export

    private func buildExportJSON() -> String {
        let payload: [String: Any] = [
            "version": 1,
            "subscriptions": SubscriptionManager.all().map { $0.toDict() },
            "playlists": PlaylistManager.all().map { $0.toDict() },
            "groups": ChannelGroupManager.all().map { $0.toDict() }
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    @objc private func copyTapped() {
        UIPasteboard.general.string = exportView.text
        flash(copyBtn, "Copied \u{2713}", revertTo: "Copy to Clipboard")
    }

    private func flash(_ btn: UIButton?, _ text: String, revertTo: String) {
        btn?.setTitle(text, for: .normal)
        let t = Timer(timeInterval: 1.5, target: SettingsBlockTarget { [weak btn] in
            btn?.setTitle(revertTo, for: .normal)
        }, selector: #selector(SettingsBlockTarget.fire), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
    }

    // MARK: - Import

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    // Don't let the dismiss-tap fire when the user is tapping into the import field.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if let v = touch.view, v.isDescendant(of: importView) { return false }
        return true
    }

    @objc private func pasteTapped() {
        importView.text = UIPasteboard.general.string ?? ""
    }

    @objc private func importTapped() {
        importView.resignFirstResponder()
        let raw = importView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any] else {
            setStatus("Could not read the pasted text. Make sure it's the full exported JSON.", ok: false)
            return
        }

        var subCount = 0
        if let subs = dict["subscriptions"] as? [[String: Any]] {
            let channels = subs.compactMap { Channel.from(dict: $0) }
            SubscriptionManager.subscribe(channels)   // one write for the whole list
            subCount = channels.count
        }

        var plCount = 0
        if let pls = dict["playlists"] as? [[String: Any]] {
            let parsed = pls.compactMap { Playlist.from(dict: $0) }
            PlaylistManager.merge(parsed)
            plCount = parsed.count
        }

        var grCount = 0
        if let grs = dict["groups"] as? [[String: Any]] {
            let parsed = grs.compactMap { ChannelGroup.from(dict: $0) }
            ChannelGroupManager.merge(parsed)
            grCount = parsed.count
        }

        if subCount == 0 && plCount == 0 && grCount == 0 {
            setStatus("No subscriptions, playlists or groups found in the pasted text.", ok: false)
        } else {
            setStatus("Imported \(subCount) subscription(s), \(plCount) playlist(s) and \(grCount) group(s).", ok: true)
        }
    }

    private func setStatus(_ text: String, ok: Bool) {
        statusLabel.textColor = ok ? UIColor(red: 0.4, green: 0.8, blue: 0.4, alpha: 1)
                                   : UIColor(red: 0.95, green: 0.5, blue: 0.4, alpha: 1)
        statusLabel.text = text
    }

    // MARK: - Reset cache

    // Empty-init + addButton (NOT the variadic otherButtonTitles: convenience init, which
    // crashes on the 5.1.5 runtime). Cancel = index 0, Reset = index 1.
    @objc private func resetTapped() {
        let alert = UIAlertView()
        alert.delegate = self
        alert.tag = 1
        alert.title = "Reset Cache?"
        alert.message = "This clears the cached home feed and downloaded thumbnails. Your subscriptions and playlists are kept."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset")
        alert.cancelButtonIndex = 0
        alert.show()
    }

    @objc private func resetAllTapped() {
        let alert = UIAlertView()
        alert.delegate = self
        alert.tag = 2
        alert.title = "Reset Everything?"
        alert.message = "This erases ALL subscriptions, playlists, groups, watch history, downloads and caches. This cannot be undone."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset All")
        alert.cancelButtonIndex = 0
        alert.show()
    }

    // Cancel = index 0 for both alerts; the confirm button is index 1. Distinguished by tag.
    func alertView(_ alertView: UIAlertView, clickedButtonAt buttonIndex: Int) {
        guard buttonIndex == 1 else { return }
        if alertView.tag == 2 {
            SubscriptionManager.clearAll()
            PlaylistManager.clearAll()
            ChannelGroupManager.clearAll()
            HistoryManager.clear()
            DownloadManager.clearAll()
            HomeVC.clearFeedCache()
            AsyncImageView.purgeCache()
            refreshCacheSize()
            setStatus("Everything reset. Subscriptions, playlists, groups, history, downloads and caches cleared.", ok: true)
        } else {
            HomeVC.clearFeedCache()
            AsyncImageView.purgeCache()
            refreshCacheSize()
            setStatus("Cache cleared. Subscriptions and playlists kept.", ok: true)
        }
    }
}

// Small NSObject closure wrapper so the one-shot revert Timer doesn't retain the VC.
private class SettingsBlockTarget: NSObject {
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}

