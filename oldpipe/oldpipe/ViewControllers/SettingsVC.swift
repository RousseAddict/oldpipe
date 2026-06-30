import UIKit

// MARK: - SettingsVC
// Export / import the user's config (subscriptions + playlists) as plain JSON text.
// iOS 6 has no usable file-sharing / document infrastructure, so transport is the
// system pasteboard: Export builds a pretty-printed JSON blob into a read-only text
// view (+ Copy button); Import parses pasted JSON and MERGES it into existing data
// (subscriptions de-duplicated by channel id, playlists upserted by playlist id).

class SettingsVC: UIViewController, UIGestureRecognizerDelegate {

    private var scrollView: UIScrollView!
    private var exportView: UITextView!
    private var importView: UITextView!
    private var statusLabel: UILabel!
    private var copyBtn: UIButton?
    private var didSetupUI = false

    private let bg = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
    private let accent = UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 1)
    private let fieldBg = UIColor(white: 0.12, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = bg
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didSetupUI else { return }
        didSetupUI = true
        setupUI()
        exportView.text = buildExportJSON()
    }

    private func setupUI() {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        let navH: CGFloat = 64
        let pad: CGFloat = 16
        let contentW = w - pad * 2

        scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: w, height: h - navH))
        scrollView.backgroundColor = bg
        view.addSubview(scrollView)

        // Tap anywhere outside the import field to dismiss the keyboard. cancelsTouchesInView
        // = false so the tap still reaches the Copy/Paste/Import buttons (iOS 6 button-tap
        // conflict avoided); the delegate ignores taps that land inside importView itself.
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        scrollView.addGestureRecognizer(tap)

        var y: CGFloat = 16

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
        scrollView.addSubview(importView)
        y += 150 + 10

        let paste = makeButton("Paste from Clipboard", at: y, width: contentW, pad: pad, accent: false)
        paste.addTarget(self, action: #selector(pasteTapped), for: .touchUpInside)
        scrollView.addSubview(paste)
        y += 44 + 10

        let importBtn = makeButton("Import", at: y, width: contentW, pad: pad, accent: true)
        importBtn.addTarget(self, action: #selector(importTapped), for: .touchUpInside)
        scrollView.addSubview(importBtn)
        y += 44 + 12

        statusLabel = UILabel(frame: CGRect(x: pad, y: y, width: contentW, height: 40))
        statusLabel.backgroundColor = .clear
        statusLabel.textColor = UIColor(white: 0.55, alpha: 1)
        statusLabel.font = UIFont.systemFont(ofSize: 13)
        statusLabel.numberOfLines = 2
        scrollView.addSubview(statusLabel)
        y += 40

        scrollView.contentSize = CGSize(width: w, height: y + 80)   // +80 covers mini player bar
    }

    // MARK: - Layout helpers

    private func addHeader(_ text: String, at y: CGFloat, width: CGFloat, pad: CGFloat) -> CGFloat {
        let l = UILabel(frame: CGRect(x: pad, y: y, width: width, height: 26))
        l.backgroundColor = .clear
        l.textColor = .white
        l.font = UIFont.boldSystemFont(ofSize: 20)
        l.text = text
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
}

// Small NSObject closure wrapper so the one-shot revert Timer doesn't retain the VC.
private class SettingsBlockTarget: NSObject {
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}
