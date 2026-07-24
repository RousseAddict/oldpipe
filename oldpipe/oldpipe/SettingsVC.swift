import UIKit

// MARK: - SettingsVC
// Export / import the user's config (subscriptions + playlists) as plain JSON text.
// iOS 6 has no usable file-sharing / document infrastructure, so transport is the
// system pasteboard: Export builds a pretty-printed JSON blob into a read-only text
// view (+ Copy button); Import parses pasted JSON and MERGES it into existing data
// (subscriptions de-duplicated by channel id, playlists upserted by playlist id).

class SettingsVC: UIViewController, UIGestureRecognizerDelegate, UIAlertViewDelegate, UIActionSheetDelegate {

    private var scrollView: UIScrollView!
    private var exportView: UITextView!
    private var importView: UITextView!
    private var statusLabel: UILabel!
    private var cacheSizeLabel: UILabel!
    private var copyBtn: UIButton?
    private var qualityBtn: UIButton?
    private var copyDebugBtn: UIButton?
    private var debugCountLabel: UILabel?
    private var didSetupUI = false
    private var loadingSpinner: UIActivityIndicatorView?

    private let bg = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
    private let accent = UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 1)
    private let fieldBg = UIColor(white: 0.12, alpha: 1)

    // The two slow bits of loading Settings — serializing every subscription/playlist to JSON
    // and scanning the on-disk thumbnail cache to sum its size — run here off the main thread
    // so the screen shows a spinner instead of freezing.
    private static let loadQueue = DispatchQueue(label: "com.oldpipe.settings.load")

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
            DispatchQueue.main.async {
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
        y = addSubtitle("Show a Shorts tab on the Home screen with short videos from your subscribed channels.",
                        at: y, width: contentW, pad: pad)

        let rowH: CGFloat = 44
        // Create the switch FIRST so we can size the label to stop before it. On iOS 6 a
        // UISwitch is ~79pt wide (wider than the ~51pt of later OSes), so a fixed 60pt gutter
        // let the (long) label text run under the switch. Anchor the switch right, then give
        // the label exactly the space to its left.
        let sw = UISwitch()
        let swW = max(sw.bounds.width, 51)
        sw.frame = CGRect(x: w - pad - swW, y: y + (rowH - sw.bounds.height) / 2,
                          width: swW, height: sw.bounds.height)
        sw.onTintColor = accent
        sw.isOn = AppSettings.shortsOnHome
        // Right-anchored so it stays pinned to the trailing edge when the iPad form widens.
        sw.autoresizingMask = iPadFlexLeft
        sw.addTarget(self, action: #selector(shortsSwitchChanged(_:)), for: .valueChanged)
        scrollView.addSubview(sw)

        let toggleLabel = UILabel(frame: CGRect(x: pad, y: y, width: sw.frame.origin.x - pad - 10, height: rowH))
        toggleLabel.backgroundColor = .clear
        toggleLabel.textColor = .white
        toggleLabel.font = UIFont.systemFont(ofSize: 16)
        toggleLabel.adjustsFontSizeToFitWidth = true
        toggleLabel.minimumScaleFactor = 0.8
        toggleLabel.text = "Enable Shorts on Home Screen"
        toggleLabel.autoresizingMask = iPadFlexWidth
        scrollView.addSubview(toggleLabel)
        y += rowH + 12

        y = addSubtitle("Automatically use this quality for playback instead of picking each time (falls back to a lower tier if the exact quality isn't available for a video).",
                        at: y, width: contentW, pad: pad)

        let qBtn = makeButton("Default Quality: \(AppSettings.defaultQualityLabel())", at: y, width: contentW, pad: pad, accent: false)
        qBtn.addTarget(self, action: #selector(qualityTapped), for: .touchUpInside)
        scrollView.addSubview(qBtn)
        qualityBtn = qBtn
        y += 44 + 12

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
        // For "video won't play from Home" style reports: when enabled, DebugLog records
        // breadcrumbs through the whole playback pipeline (tap -> stream lookup -> proxy ->
        // player readiness), which otherwise fails silently on iOS 6. Copy button pulls the
        // trail into the pasteboard so it can be sent back to us. Off by default.
        y = addHeader("Debug", at: y, width: contentW, pad: pad)
        y = addSubtitle("If you're having trouble playing videos, turn this on, reproduce the issue, then tap Copy Debug Log and send it to us.",
                        at: y, width: contentW, pad: pad)

        let debugRowH: CGFloat = 44
        let dsw = UISwitch()
        let dswW = max(dsw.bounds.width, 51)
        dsw.frame = CGRect(x: w - pad - dswW, y: y + (debugRowH - dsw.bounds.height) / 2,
                           width: dswW, height: dsw.bounds.height)
        dsw.onTintColor = accent
        dsw.isOn = AppSettings.debugLoggingEnabled
        dsw.autoresizingMask = iPadFlexLeft
        dsw.addTarget(self, action: #selector(debugSwitchChanged(_:)), for: .valueChanged)
        scrollView.addSubview(dsw)

        let debugToggleLabel = UILabel(frame: CGRect(x: pad, y: y, width: dsw.frame.origin.x - pad - 10, height: debugRowH))
        debugToggleLabel.backgroundColor = .clear
        debugToggleLabel.textColor = .white
        debugToggleLabel.font = UIFont.systemFont(ofSize: 16)
        debugToggleLabel.adjustsFontSizeToFitWidth = true
        debugToggleLabel.minimumScaleFactor = 0.8
        debugToggleLabel.text = "Enable Debug Logging"
        debugToggleLabel.autoresizingMask = iPadFlexWidth
        scrollView.addSubview(debugToggleLabel)
        y += debugRowH + 12

        let dCountLabel = UILabel(frame: CGRect(x: pad, y: y, width: contentW, height: 18))
        dCountLabel.backgroundColor = .clear
        dCountLabel.textColor = UIColor(white: 0.55, alpha: 1)
        dCountLabel.font = UIFont.systemFont(ofSize: 12)
        dCountLabel.autoresizingMask = iPadFlexWidth
        dCountLabel.text = "\(DebugLog.count()) log entr\(DebugLog.count() == 1 ? "y" : "ies")"
        scrollView.addSubview(dCountLabel)
        debugCountLabel = dCountLabel
        y += 18 + 8

        let copyDebug = makeButton("Copy Debug Log", at: y, width: contentW, pad: pad, accent: false)
        copyDebug.addTarget(self, action: #selector(copyDebugTapped), for: .touchUpInside)
        scrollView.addSubview(copyDebug)
        copyDebugBtn = copyDebug
        y += 44 + 10

        let clearDebug = makeButton("Clear Debug Log", at: y, width: contentW, pad: pad, accent: false)
        clearDebug.addTarget(self, action: #selector(clearDebugTapped), for: .touchUpInside)
        scrollView.addSubview(clearDebug)
        y += 44

        scrollView.contentSize = CGSize(width: w, height: y + 80)   // +80 covers mini player bar
    }

    // MARK: - Preferences

    @objc private func shortsSwitchChanged(_ sender: UISwitch) {
        AppSettings.shortsOnHome = sender.isOn
    }

    // MARK: - Debug

    @objc private func debugSwitchChanged(_ sender: UISwitch) {
        AppSettings.debugLoggingEnabled = sender.isOn
    }

    @objc private func copyDebugTapped() {
        UIPasteboard.general.string = DebugLog.exportText()
        flash(copyDebugBtn, "Copied \u{2713}", revertTo: "Copy Debug Log")
    }

    @objc private func clearDebugTapped() {
        DebugLog.clear()
        debugCountLabel?.text = "0 log entries"
    }

    // Empty-init + addButton (NOT the variadic otherButtonTitles: convenience init, which
    // crashes on the 5.1.5 runtime).
    @objc private func qualityTapped() {
        let sheet = UIActionSheet()
        sheet.delegate = self
        sheet.tag = 10
        sheet.title = "Default Video Quality"
        sheet.addButton(withTitle: "Auto (360p)")
        sheet.addButton(withTitle: "480p")
        sheet.addButton(withTitle: "720p")
        sheet.addButton(withTitle: "1080p")
        sheet.addButton(withTitle: "Cancel")
        sheet.cancelButtonIndex = 4
        sheet.show(in: view)
    }

    func actionSheet(_ actionSheet: UIActionSheet, clickedButtonAt buttonIndex: Int) {
        guard actionSheet.tag == 10 else { return }
        let values = ["auto", "480", "720", "1080"]
        guard buttonIndex >= 0, buttonIndex < values.count else { return }
        AppSettings.defaultQuality = values[buttonIndex]
        qualityBtn?.setTitle("Default Quality: \(AppSettings.defaultQualityLabel())", for: .normal)
    }

    // MARK: - Cache size

    private func refreshCacheSize() {
        cacheSizeLabel.text = "Calculating cache size\u{2026}"
        SettingsVC.loadQueue.async { [weak self] in
            let bytes = AsyncImageView.diskCacheSize()
            DispatchQueue.main.async {
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
        b.backgroundColor = isAccent ? accent : UIColor(white: 0.20, alpha: 1)
        b.layer.cornerRadius = 8
        b.autoresizingMask = iPadFlexWidth
        return b
    }

    // MARK: - Export

    private func buildExportJSON() -> String {
        let payload: [String: Any] = [
            "version": 1,
            "subscriptions": SubscriptionManager.all().map { $0.toDict() },
            "playlists": PlaylistManager.all().map { $0.toDict() }
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
            for d in subs {
                if let c = Channel.from(dict: d) {
                    SubscriptionManager.subscribe(c)
                    subCount += 1
                }
            }
        }

        var plCount = 0
        if let pls = dict["playlists"] as? [[String: Any]] {
            let parsed = pls.compactMap { Playlist.from(dict: $0) }
            PlaylistManager.merge(parsed)
            plCount = parsed.count
        }

        if subCount == 0 && plCount == 0 {
            setStatus("No subscriptions or playlists found in the pasted text.", ok: false)
        } else {
            setStatus("Imported \(subCount) subscription(s) and \(plCount) playlist(s).", ok: true)
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
        alert.message = "This erases ALL subscriptions, playlists, watch history, downloads and caches. This cannot be undone."
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
            HistoryManager.clear()
            DownloadManager.clearAll()
            HomeVC.clearFeedCache()
            AsyncImageView.purgeCache()
            refreshCacheSize()
            setStatus("Everything reset. Subscriptions, playlists, history, downloads and caches cleared.", ok: true)
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

