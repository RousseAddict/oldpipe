import UIKit
import AVFoundation

// VideoPlayerVC is a thin view onto VideoPlayer.shared. It does NOT own the AVPlayer —
// the singleton does, so audio keeps playing when this VC is popped (the mini bar takes
// over). On appear it attaches the shared AVPlayerLayer into its video container; on
// disappear it detaches the layer (does NOT stop playback). Audio session, Now Playing
// metadata, remote-control transport, and resume persistence all live in the singleton.

class VideoPlayerVC: UIViewController, UIActionSheetDelegate, UIAlertViewDelegate {

    private let video: Video
    private var streams: [VideoStream] = []
    private var didRequestStreams = false


    // Add-to-playlist chooser state (index → playlist mapping for the action sheet).
    private var pendingPlaylists: [Playlist] = []

    // Everything below the meta line is laid out by relayout() from contentBelowMetaY:
    // description (below meta) → download button → share row → related videos. The
    // description and related arrive asynchronously (in either order) and the description
    // can expand/collapse, so relayout() repositions the action buttons each time.
    private var contentBelowMetaY: CGFloat = 0
    private var descriptionText = ""
    private var descExpanded = false
    private var descRowViews: [UIView] = []
    private var relatedVideos: [Video] = []
    private var didRequestRelated = false
    private var relatedRowViews: [UIView] = []

    private var sp: VideoPlayer { return VideoPlayer.shared }

    // UI
    private var scrollView: UIScrollView?
    private var thumbView: AsyncImageView?
    private var playBtn: UIButton?
    private var statusLabel: UILabel?
    private var titleLabel: UILabel?
    private var channelLabel: UILabel?
    private var metaLabel: UILabel?
    private var videoContainer: UIView?
    private var downloadBtn: UIButton?
    private var shareBtn: UIButton?
    private var addPlaylistBtn: UIButton?
    private var fsOverlay: UIView?

    // Playback controls (play/pause + scrubber)
    private var controlsView: UIView?
    private var playPauseBtn: UIButton?
    private var scrubber: UISlider?
    private var currentTimeLabel: UILabel?
    private var durationLabel: UILabel?
    private var fsButton: UIButton?
    private var isScrubbing = false
    private var fsAngle: CGFloat = CGFloat(Double.pi / 2)
    private var fsActive = false

    // iOS 7+ view-controller-based status bar control (ignored on iOS 6).
    override var prefersStatusBarHidden: Bool { return fsActive }

    // MARK: - Init

    init(video: Video) {
        self.video = video
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Video"
        view.backgroundColor = UIColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self, selector: #selector(orientationChanged),
            name: UIDevice.orientationDidChangeNotification, object: nil)
        // Re-sync UI + audio session when returning from background / lock screen.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)

        if scrollView == nil { setupUI() }

        // If the singleton is already playing this video (reopened from the mini bar, or
        // returning from a pushed VC), reattach onto the live playback. Otherwise load.
        if sp.isActive(video.id) {
            showActivePlayback()
            // Reopened onto live playback (e.g. from the mini bar) — still fetch the
            // description in the background without disturbing the playing UI.
            if !didRequestStreams { loadStreams(updateStatus: false) }
        } else if !didRequestStreams {
            loadStreams()
        }

        // A download started here may still be running in the manager after we navigated
        // away and back — reattach its progress UI.
        if DownloadManager.isDownloading(video.id) {
            downloadBtn?.isEnabled = false
            downloadBtn?.setTitle("Downloading \(Int(DownloadManager.progress(for: video.id) * 100))%...", for: .normal)
            observeDownload(autoPlay: false)
        }

        // Fetch related videos immediately on open (once per VC instance).
        if !didRequestRelated { loadRelated() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        NotificationCenter.default.removeObserver(self)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        if let t = objc_getAssociatedObject(self, &timerKey) as? Timer { t.invalidate() }
        if let t = objc_getAssociatedObject(self, &progressTimerKey) as? Timer { t.invalidate() }
        if let t = objc_getAssociatedObject(self, &downloadPollKey) as? Timer { t.invalidate() }
        if fsOverlay != nil { exitFullscreen() }
        // Detach the shared layer — do NOT stop. Playback (audio) continues; the mini bar
        // takes over the UI. The layer is reattached on the next appear.
        detachLayer()
    }

    @objc private func appDidBecomeActive() {
        // The audio session can be deactivated by the system in the background; re-arm it
        // and resync the scrubber to the player's real position.
        sp.reactivateSession()
        updateProgress()
    }

    // MARK: - Shared layer attach / detach

    private func attachLayer() {
        guard let container = videoContainer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sp.layer.frame = container.bounds
        sp.layer.videoGravity = AVLayerVideoGravity.resizeAspect
        if let thumbLayer = thumbView?.layer {
            container.layer.insertSublayer(sp.layer, below: thumbLayer)
        } else {
            container.layer.addSublayer(sp.layer)
        }
        CATransaction.commit()
    }

    private func detachLayer() {
        sp.layer.removeFromSuperlayer()
    }

    // Reattach onto already-running playback (from mini bar / returning to the VC).
    private func showActivePlayback() {
        playBtn?.isHidden = true
        statusLabel?.isHidden = true
        thumbView?.isHidden = true
        attachLayer()
        sp.setArtwork(thumbView?.image)
        showControls()
        updateProgress()
    }

    // MARK: - Orientation → fullscreen

    // The app window stays portrait (iOS 6-safe); rotating the device drives the
    // fullscreen overlay's rotation so the video fills the screen in landscape.
    @objc private func orientationChanged() {
        guard sp.isActive(video.id) else { return }   // only while a video is loaded
        switch UIDevice.current.orientation {
        case .landscapeLeft:
            setFullscreen(true, angle: CGFloat(Double.pi / 2))
        case .landscapeRight:
            setFullscreen(true, angle: CGFloat(-Double.pi / 2))
        case .portrait:
            setFullscreen(false, angle: 0)
        default:
            break
        }
    }

    private func setFullscreen(_ on: Bool, angle: CGFloat) {
        if on {
            fsAngle = angle
            if fsOverlay == nil {
                enterFullscreen()
            } else {
                // Already fullscreen — just re-orient to the new landscape side.
                fsOverlay?.transform = CGAffineTransform(rotationAngle: angle)
            }
        } else if fsOverlay != nil {
            exitFullscreen()
        }
    }

    // MARK: - UI Setup

    private func setupUI() {
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height

        let sv = UIScrollView(frame: CGRect(x: 0, y: 0, width: w, height: h - 64))
        sv.backgroundColor = UIColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
        view.addSubview(sv)
        scrollView = sv

        var y: CGFloat = 0

        // Video container (16:9 ratio)
        let videoH = floor(w * 9.0 / 16.0)
        let container = UIView(frame: CGRect(x: 0, y: y, width: w, height: videoH))
        container.backgroundColor = .black
        sv.addSubview(container)
        videoContainer = container
        y += videoH

        // Thumbnail (shown before playback)
        let thumb = AsyncImageView(frame: CGRect(x: 0, y: 0, width: w, height: videoH))
        thumb.contentMode = .scaleAspectFit
        thumb.backgroundColor = .black
        thumb.load(url: video.thumbnailURL)
        container.addSubview(thumb)
        thumbView = thumb

        // Play button overlay
        let btn = UIButton(type: .custom)
        btn.frame = CGRect(x: (w - 64) / 2, y: (videoH - 64) / 2, width: 64, height: 64)
        btn.backgroundColor = UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 0.9)
        btn.layer.cornerRadius = 32
        btn.setTitle(">", for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 28)
        btn.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        container.addSubview(btn)
        playBtn = btn

        // Status label (loading/error messages)
        let sl = UILabel()
        // Translucent black plate so the text stays readable over any thumbnail behind it.
        sl.backgroundColor = UIColor(white: 0, alpha: 0.55)
        sl.textColor = .white
        sl.textAlignment = .center
        sl.font = UIFont.systemFont(ofSize: 13)
        sl.numberOfLines = 2
        sl.isHidden = true
        sl.frame = CGRect(x: 0, y: videoH - 28, width: w, height: 28)
        container.addSubview(sl)
        statusLabel = sl

        buildControls(width: w, videoHeight: videoH, in: container)

        // Title
        let padding: CGFloat = 12
        y += 12
        let titleL = UILabel()
        titleL.backgroundColor = .clear
        titleL.textColor = UIColor(white: 0.95, alpha: 1)
        titleL.font = UIFont.boldSystemFont(ofSize: 16)
        titleL.numberOfLines = 3
        titleL.text = video.title
        let titleH = titleL.sizeThatFits(CGSize(width: w - padding * 2, height: 200)).height
        titleL.frame = CGRect(x: padding, y: y, width: w - padding * 2, height: titleH)
        sv.addSubview(titleL)
        titleLabel = titleL
        y += titleH + 8

        // Channel (tappable → channel page, when we know the channel id)
        let channelL = UILabel()
        channelL.backgroundColor = .clear
        channelL.textColor = video.channelId.isEmpty
            ? UIColor(white: 0.6, alpha: 1)
            : UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 1)
        channelL.font = UIFont.systemFont(ofSize: 14)
        channelL.text = video.channelName
        channelL.frame = CGRect(x: padding, y: y, width: w - padding * 2, height: 20)
        sv.addSubview(channelL)
        channelLabel = channelL
        if !video.channelId.isEmpty {
            let chanBtn = UIButton(type: .custom)
            chanBtn.frame = channelL.frame
            chanBtn.backgroundColor = .clear
            chanBtn.addTarget(self, action: #selector(channelTapped), for: .touchUpInside)
            sv.addSubview(chanBtn)
        }
        y += 24

        // Meta (duration + published + views)
        let meta = [video.durationText, video.publishedText, video.viewCountText].filter { !$0.isEmpty }.joined(separator: " • ")
        if !meta.isEmpty {
            let metaL = UILabel()
            metaL.backgroundColor = .clear
            metaL.textColor = UIColor(white: 0.5, alpha: 1)
            metaL.font = UIFont.systemFont(ofSize: 13)
            metaL.text = meta
            metaL.frame = CGRect(x: padding, y: y, width: w - padding * 2, height: 18)
            sv.addSubview(metaL)
            metaLabel = metaL
            y += 26
        }

        // Everything from here down is positioned by relayout() (description sits directly
        // below the meta line and pushes the buttons + related down when it loads).
        contentBelowMetaY = y

        // Download-for-offline button (frame set in relayout).
        let dl = UIButton(type: .custom)
        dl.layer.cornerRadius = 6
        dl.setTitleColor(.white, for: .normal)
        dl.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
        dl.addTarget(self, action: #selector(downloadTapped), for: .touchUpInside)
        sv.addSubview(dl)
        downloadBtn = dl
        updateDownloadButton()

        // Share + Add-to-playlist row (two equal buttons; frames set in relayout).
        let secondaryBg = UIColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1)

        let share = UIButton(type: .custom)
        share.layer.cornerRadius = 6
        share.backgroundColor = secondaryBg
        share.setTitle("Share", for: .normal)
        share.setTitleColor(.white, for: .normal)
        share.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
        share.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        sv.addSubview(share)
        shareBtn = share

        let addPl = UIButton(type: .custom)
        addPl.layer.cornerRadius = 6
        addPl.backgroundColor = secondaryBg
        addPl.setTitle("+ Playlist", for: .normal)
        addPl.setTitleColor(.white, for: .normal)
        addPl.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
        addPl.addTarget(self, action: #selector(addToPlaylistTapped), for: .touchUpInside)
        sv.addSubview(addPl)
        addPlaylistBtn = addPl

        relayout()
    }

    @objc private func channelTapped() {
        guard !video.channelId.isEmpty else { return }
        let vc = ChannelVC(channelId: video.channelId, name: video.channelName)
        navigationController?.pushViewController(vc, animated: true)
    }

    private func updateDownloadButton() {
        if DownloadManager.isDownloaded(video.id) {
            downloadBtn?.setTitle("Downloaded \u{2713}", for: .normal)
            downloadBtn?.isEnabled = false
            downloadBtn?.backgroundColor = UIColor(red: 0.15, green: 0.4, blue: 0.15, alpha: 1)
        } else {
            downloadBtn?.setTitle("Download for offline", for: .normal)
            downloadBtn?.isEnabled = true
            downloadBtn?.backgroundColor = UIColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1)
        }
    }

    // MARK: - Related videos

    private func loadRelated() {
        didRequestRelated = true
        YoutubeAPI.getRelated(videoId: video.id) { [weak self] vids in
            guard let self = self else { return }
            self.relatedVideos = Array(vids.prefix(12))
            self.relayout()
        }
    }

    @objc private func descToggleTapped() {
        descExpanded = !descExpanded
        relayout()
    }

    // Lay out everything below the meta line: description → download button → share row →
    // related videos. Called from setupUI and whenever async content (description, related)
    // arrives or the description is expanded/collapsed. Repositions the (already-created)
    // action buttons and re-lays the async sections, then sizes the scroll content once.
    private func relayout() {
        guard let sv = scrollView else { return }
        for v in descRowViews { v.removeFromSuperview() }
        descRowViews.removeAll()
        for v in relatedRowViews { v.removeFromSuperview() }
        relatedRowViews.removeAll()

        let w = sv.bounds.width
        let padding: CGFloat = 12
        var y = contentBelowMetaY

        // Description (directly under the meta line).
        y = buildDescriptionSection(startY: y, width: w)

        // Download button.
        downloadBtn?.frame = CGRect(x: padding, y: y, width: w - padding * 2, height: 44)
        y += 44 + 12

        // Share + add-to-playlist row.
        let gap: CGFloat = 10
        let halfW = (w - padding * 2 - gap) / 2
        shareBtn?.frame = CGRect(x: padding, y: y, width: halfW, height: 44)
        addPlaylistBtn?.frame = CGRect(x: padding + halfW + gap, y: y, width: halfW, height: 44)
        y += 44 + 12

        // Related videos.
        y = buildRelatedRows(startY: y, width: w)

        sv.contentSize = CGSize(width: w, height: y + 80)   // +80 clears the mini player bar
    }

    // Collapsible description block. Collapsed to 4 lines; a "Show more"/"Show less"
    // toggle appears only when the text is actually longer than the collapsed cap.
    private func buildDescriptionSection(startY: CGFloat, width w: CGFloat) -> CGFloat {
        guard !descriptionText.isEmpty, let sv = scrollView else { return startY }
        let padding: CGFloat = 12
        let bodyW = w - padding * 2
        var y = startY

        let sep = UIView(frame: CGRect(x: 0, y: y, width: w, height: 0.5))
        sep.backgroundColor = UIColor(white: 0.2, alpha: 1)
        sv.addSubview(sep); descRowViews.append(sep)
        y += 12

        let header = UILabel()
        header.backgroundColor = .clear
        header.textColor = UIColor(white: 0.95, alpha: 1)
        header.font = UIFont.boldSystemFont(ofSize: 16)
        header.text = "Description"
        header.frame = CGRect(x: padding, y: y, width: bodyW, height: 22)
        sv.addSubview(header); descRowViews.append(header)
        y += 30

        let bodyFont = UIFont.systemFont(ofSize: 13)
        // Measure collapsed (4-line) vs full height to decide whether a toggle is needed.
        let collapsedH = heightForText(descriptionText, font: bodyFont, width: bodyW, maxLines: 4)
        let fullH = heightForText(descriptionText, font: bodyFont, width: bodyW, maxLines: 0)
        let truncated = fullH > collapsedH + 1

        let body = UILabel()
        body.backgroundColor = .clear
        body.textColor = UIColor(white: 0.8, alpha: 1)
        body.font = bodyFont
        body.numberOfLines = descExpanded ? 0 : 4
        body.text = descriptionText
        let bodyH = descExpanded ? fullH : collapsedH
        body.frame = CGRect(x: padding, y: y, width: bodyW, height: bodyH)
        sv.addSubview(body); descRowViews.append(body)
        y += bodyH + 4

        if truncated {
            let toggle = UIButton(type: .custom)
            toggle.setTitle(descExpanded ? "Show less" : "Show more", for: .normal)
            toggle.setTitleColor(UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 1), for: .normal)
            toggle.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
            toggle.contentHorizontalAlignment = .left
            toggle.frame = CGRect(x: padding, y: y, width: bodyW, height: 24)
            toggle.addTarget(self, action: #selector(descToggleTapped), for: .touchUpInside)
            sv.addSubview(toggle); descRowViews.append(toggle)
            y += 28
        }
        y += 6
        return y
    }

    private func heightForText(_ text: String, font: UIFont, width: CGFloat, maxLines: Int) -> CGFloat {
        let l = UILabel()
        l.font = font
        l.numberOfLines = maxLines
        l.text = text
        return ceil(l.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height)
    }

    // Related-videos list. Returns the y after the last row (or startY if empty).
    private func buildRelatedRows(startY: CGFloat, width w: CGFloat) -> CGFloat {
        guard !relatedVideos.isEmpty, let sv = scrollView else { return startY }
        let padding: CGFloat = 12
        var y = startY

        let sep = UIView(frame: CGRect(x: 0, y: y, width: w, height: 0.5))
        sep.backgroundColor = UIColor(white: 0.2, alpha: 1)
        sv.addSubview(sep)
        relatedRowViews.append(sep)
        y += 12

        let header = UILabel()
        header.backgroundColor = .clear
        header.textColor = UIColor(white: 0.95, alpha: 1)
        header.font = UIFont.boldSystemFont(ofSize: 16)
        header.text = "Related videos"
        header.frame = CGRect(x: padding, y: y, width: w - padding * 2, height: 22)
        sv.addSubview(header)
        relatedRowViews.append(header)
        y += 30

        for (i, v) in relatedVideos.enumerated() {
            let row = makeRelatedRow(v, index: i, width: w)
            row.frame = CGRect(x: 0, y: y, width: w, height: 80)
            sv.addSubview(row)
            relatedRowViews.append(row)
            y += 80
        }
        return y
    }

    private func makeRelatedRow(_ v: Video, index: Int, width w: CGFloat) -> UIView {
        let padding: CGFloat = 12
        let row = UIView()

        let thumbW: CGFloat = 120
        let thumbH: CGFloat = 68
        let thumb = AsyncImageView(frame: CGRect(x: padding, y: 6, width: thumbW, height: thumbH))
        thumb.backgroundColor = UIColor(white: 0.12, alpha: 1)
        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = 4
        if !v.thumbnailURL.isEmpty { thumb.load(url: v.thumbnailURL) }
        row.addSubview(thumb)

        if !v.durationText.isEmpty {
            let dur = UILabel()
            dur.backgroundColor = UIColor(white: 0, alpha: 0.75)
            dur.textColor = .white
            dur.font = UIFont.boldSystemFont(ofSize: 10)
            dur.textAlignment = .center
            dur.text = " \(v.durationText) "
            let dW = dur.sizeThatFits(CGSize(width: 100, height: 16)).width + 6
            dur.frame = CGRect(x: thumb.frame.maxX - dW - 4, y: thumb.frame.maxY - 18, width: dW, height: 14)
            dur.layer.cornerRadius = 2
            dur.clipsToBounds = true
            row.addSubview(dur)
        }

        let textX = thumbW + padding + 8
        let textW = w - textX - padding

        let titleL = UILabel()
        titleL.backgroundColor = .clear
        titleL.textColor = UIColor(white: 0.95, alpha: 1)
        titleL.font = UIFont.systemFont(ofSize: 13)
        titleL.numberOfLines = 2
        titleL.text = v.title
        titleL.frame = CGRect(x: textX, y: 6, width: textW, height: 34)
        row.addSubview(titleL)

        let subParts = [v.channelName, v.viewCountText, v.publishedText].filter { !$0.isEmpty }
        let subL = UILabel()
        subL.backgroundColor = .clear
        subL.textColor = UIColor(white: 0.5, alpha: 1)
        subL.font = UIFont.systemFont(ofSize: 11)
        subL.numberOfLines = 2
        subL.text = subParts.joined(separator: " • ")
        subL.frame = CGRect(x: textX, y: 42, width: textW, height: 30)
        row.addSubview(subL)

        let tapBtn = UIButton(type: .custom)
        tapBtn.frame = CGRect(x: 0, y: 0, width: w, height: 80)
        tapBtn.backgroundColor = .clear
        tapBtn.tag = index
        tapBtn.addTarget(self, action: #selector(relatedRowTapped(_:)), for: .touchUpInside)
        row.addSubview(tapBtn)

        return row
    }

    @objc private func relatedRowTapped(_ sender: UIButton) {
        let idx = sender.tag
        guard idx >= 0, idx < relatedVideos.count else { return }
        let vc = VideoPlayerVC(video: relatedVideos[idx])
        navigationController?.pushViewController(vc, animated: true)
    }

    // MARK: - Share

    private func shareURL() -> String {
        return "https://www.youtube.com/watch?v=\(video.id)"
    }

    @objc private func shareTapped() {
        // UIActionSheet (NOT UIActivityViewController) — iOS-6-reliable; matches our pattern.
        // Build buttons explicitly (the variadic otherButtonTitles: convenience init crashes
        // on the 5.1.5 runtime — same reason addToPlaylistTapped builds buttons one by one).
        let sheet = UIActionSheet()
        sheet.delegate = self
        sheet.title = shareURL()
        sheet.addButton(withTitle: "Copy Link")
        sheet.addButton(withTitle: "Open in Safari")
        let cancelIdx = sheet.addButton(withTitle: "Cancel")
        sheet.cancelButtonIndex = cancelIdx
        sheet.tag = 1
        sheet.show(in: view)
    }

    // MARK: - Add to playlist

    @objc private func addToPlaylistTapped() {
        pendingPlaylists = PlaylistManager.all()
        // Build buttons explicitly: [playlist…] then "New Playlist…" then "Cancel".
        let sheet = UIActionSheet()
        sheet.delegate = self
        sheet.title = "Add to playlist"
        for pl in pendingPlaylists { sheet.addButton(withTitle: pl.name) }
        sheet.addButton(withTitle: "New Playlist\u{2026}")
        let cancelIdx = sheet.addButton(withTitle: "Cancel")
        sheet.cancelButtonIndex = cancelIdx
        sheet.tag = 2
        sheet.show(in: view)
    }

    private func promptNewPlaylist() {
        let alert = UIAlertView()
        alert.delegate = self
        alert.title = "New Playlist"
        alert.message = "Enter a name"
        alert.alertViewStyle = .plainTextInput
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Create")
        alert.cancelButtonIndex = 0
        alert.show()
    }

    // Briefly flash a button's title to confirm an action, then revert.
    private func flash(_ btn: UIButton?, _ text: String, revertTo: String) {
        btn?.setTitle(text, for: .normal)
        let t = Timer(timeInterval: 1.5, target: BlockTarget { [weak btn] in
            btn?.setTitle(revertTo, for: .normal)
        }, selector: #selector(BlockTarget.fire), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
    }

    // MARK: - UIActionSheetDelegate

    func actionSheet(_ actionSheet: UIActionSheet, clickedButtonAt buttonIndex: Int) {
        if actionSheet.tag == 1 {
            // Compare titles (robust to button-index ordering across iOS versions).
            switch actionSheet.buttonTitle(at: buttonIndex) {
            case "Copy Link":
                UIPasteboard.general.string = shareURL()
                flash(shareBtn, "Copied \u{2713}", revertTo: "Share")
            case "Open in Safari":
                if let u = URL(string: shareURL()) { UIApplication.shared.openURL(u) }
            default:
                break
            }
        } else if actionSheet.tag == 2 {
            if buttonIndex < pendingPlaylists.count {
                let pl = pendingPlaylists[buttonIndex]
                PlaylistManager.add(video: video, to: pl.id)
                flash(addPlaylistBtn, "Added \u{2713}", revertTo: "+ Playlist")
            } else if actionSheet.buttonTitle(at: buttonIndex) == "New Playlist\u{2026}" {
                promptNewPlaylist()
            }
        }
    }

    // MARK: - UIAlertViewDelegate (new-playlist name entry)

    func alertView(_ alertView: UIAlertView, clickedButtonAt buttonIndex: Int) {
        guard buttonIndex == 1 else { return }   // 0 = Cancel, 1 = Create
        let name = (alertView.textField(at: 0)?.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let pl = PlaylistManager.create(name: name)
        PlaylistManager.add(video: video, to: pl.id)
        flash(addPlaylistBtn, "Added \u{2713}", revertTo: "+ Playlist")
    }

    // MARK: - Playback controls UI

    // A 40px control bar pinned to the bottom of the video area: play/pause, elapsed
    // time, scrubber, total time. Hidden until playback begins.
    private func buildControls(width w: CGFloat, videoHeight videoH: CGFloat, in container: UIView) {
        let barH: CGFloat = 40
        let bar = UIView(frame: CGRect(x: 0, y: videoH - barH, width: w, height: barH))
        bar.backgroundColor = UIColor(white: 0, alpha: 0.45)
        bar.isHidden = true
        container.addSubview(bar)
        controlsView = bar

        let pp = UIButton(type: .custom)
        pp.frame = CGRect(x: 0, y: 0, width: 40, height: barH)
        pp.setTitle("||", for: .normal)
        pp.setTitleColor(.white, for: .normal)
        pp.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
        pp.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)
        bar.addSubview(pp)
        playPauseBtn = pp

        let cur = UILabel()
        cur.backgroundColor = .clear
        cur.textColor = .white
        cur.font = UIFont.systemFont(ofSize: 11)
        cur.textAlignment = .center
        cur.text = "0:00"
        bar.addSubview(cur)
        currentTimeLabel = cur

        let dur = UILabel()
        dur.backgroundColor = .clear
        dur.textColor = .white
        dur.font = UIFont.systemFont(ofSize: 11)
        dur.textAlignment = .center
        dur.text = "0:00"
        bar.addSubview(dur)
        durationLabel = dur

        let sl = UISlider()
        sl.minimumValue = 0
        sl.maximumValue = 1
        sl.value = 0
        sl.minimumTrackTintColor = UIColor(red: 0.98, green: 0.27, blue: 0.27, alpha: 1)
        sl.addTarget(self, action: #selector(scrubChanged), for: .valueChanged)
        sl.addTarget(self, action: #selector(scrubTouchDown), for: .touchDown)
        sl.addTarget(self, action: #selector(scrubTouchUp), for: [.touchUpInside, .touchUpOutside])
        bar.addSubview(sl)
        scrubber = sl

        let fs = UIButton(type: .custom)
        fs.setImage(fullscreenIcon(), for: .normal)
        fs.addTarget(self, action: #selector(fullscreenTapped), for: .touchUpInside)
        bar.addSubview(fs)
        fsButton = fs

        layoutControls(width: w)
    }

    // Position the control bar's children for a given bar width (bar frame set by caller).
    // Layout: [play 40][cur 44] ===slider=== [dur 40][fullscreen 36]
    private func layoutControls(width w: CGFloat) {
        let barH: CGFloat = 40
        playPauseBtn?.frame = CGRect(x: 0, y: 0, width: 40, height: barH)
        currentTimeLabel?.frame = CGRect(x: 40, y: 0, width: 44, height: barH)
        fsButton?.frame = CGRect(x: w - 36, y: 0, width: 36, height: barH)
        durationLabel?.frame = CGRect(x: w - 36 - 40, y: 0, width: 40, height: barH)
        scrubber?.frame = CGRect(x: 88, y: 0, width: w - 88 - 36 - 40, height: barH)
    }

    // A simple two-corner-bracket "expand" glyph drawn in code (reliable on iOS 6 fonts).
    private func fullscreenIcon() -> UIImage? {
        let s = CGSize(width: 20, height: 20)
        UIGraphicsBeginImageContextWithOptions(s, false, UIScreen.main.scale)
        guard let ctx = UIGraphicsGetCurrentContext() else { UIGraphicsEndImageContext(); return nil }
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(2)
        let len: CGFloat = 6
        // top-left
        ctx.move(to: CGPoint(x: 2, y: 7)); ctx.addLine(to: CGPoint(x: 2, y: 2)); ctx.addLine(to: CGPoint(x: 7, y: 2))
        // top-right
        ctx.move(to: CGPoint(x: 18 - len, y: 2)); ctx.addLine(to: CGPoint(x: 18, y: 2)); ctx.addLine(to: CGPoint(x: 18, y: 7))
        // bottom-left
        ctx.move(to: CGPoint(x: 2, y: 18 - len)); ctx.addLine(to: CGPoint(x: 2, y: 18)); ctx.addLine(to: CGPoint(x: 7, y: 18))
        // bottom-right
        ctx.move(to: CGPoint(x: 18, y: 18 - len)); ctx.addLine(to: CGPoint(x: 18, y: 18)); ctx.addLine(to: CGPoint(x: 18 - len, y: 18))
        ctx.strokePath()
        let img = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return img
    }

    private func showControls() {
        controlsView?.isHidden = false
        playPauseBtn?.setTitle(sp.isPlaying ? "||" : ">", for: .normal)
        startProgressTimer()
    }

    private func startProgressTimer() {
        if let t = objc_getAssociatedObject(self, &progressTimerKey) as? Timer { t.invalidate() }
        let t = Timer(timeInterval: 0.5, target: BlockTarget { [weak self] in
            self?.updateProgress()
        }, selector: #selector(BlockTarget.fire), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        objc_setAssociatedObject(self, &progressTimerKey, t, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func updateProgress() {
        guard sp.isReady else { return }
        let dur = sp.durationSeconds
        let cur = sp.currentSeconds
        guard dur > 0 else { return }
        durationLabel?.text = timeString(dur)
        if !isScrubbing {
            scrubber?.value = Float(cur / dur)
            currentTimeLabel?.text = timeString(cur)
        }
        // Keep button glyph in sync with actual rate.
        playPauseBtn?.setTitle(sp.isPlaying ? "||" : ">", for: .normal)
    }

    private func timeString(_ seconds: Double) -> String {
        let s = Int(seconds)
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    @objc private func togglePlayPause() {
        sp.togglePlayPause()
        playPauseBtn?.setTitle(sp.isPlaying ? "||" : ">", for: .normal)
    }

    @objc private func scrubTouchDown() { isScrubbing = true }

    @objc private func scrubChanged() {
        let dur = sp.durationSeconds
        guard dur > 0, let v = scrubber?.value else { return }
        currentTimeLabel?.text = timeString(Double(v) * dur)
    }

    @objc private func scrubTouchUp() {
        if let v = scrubber?.value { sp.seek(toFraction: Double(v)) }
        isScrubbing = false
    }

    // MARK: - Stream loading

    // updateStatus == false when called purely to fetch the description while playback
    // is already live (reopened from the mini bar) — leaves the status label untouched.
    private func loadStreams(updateStatus: Bool = true) {
        didRequestStreams = true
        // Already downloaded — no network needed, play offline.
        if DownloadManager.isDownloaded(video.id) {
            if updateStatus {
                statusLabel?.text = "Downloaded \u{2022} tap > to play"
                statusLabel?.isHidden = false
            }
            return
        }

        if updateStatus {
            statusLabel?.text = "Loading..."
            statusLabel?.isHidden = false
        }

        YoutubeAPI.getStreams(videoId: video.id) { [weak self] streams, _, desc in
            guard let self = self else { return }
            self.streams = streams
            if updateStatus {
                self.statusLabel?.text = streams.isEmpty ? "No streams available" : "Tap > to play"
            }
            if !desc.isEmpty {
                self.descriptionText = desc
                self.relayout()
            }
        }
    }

    // MARK: - Stream selection

    private func preferredStream() -> VideoStream? {
        return streams.first { $0.itag == 18 }
            ?? streams.first { $0.mimeType.contains("mp4") && !$0.mimeType.contains("av01") }
            ?? streams.first { $0.mimeType.contains("video") }
            ?? streams.first
    }

    // MARK: - Playback

    @objc private func playTapped() {
        // Offline copy takes priority.
        if DownloadManager.isDownloaded(video.id) {
            playBtn?.isHidden = true
            statusLabel?.isHidden = true
            startPlayback(url: URL(fileURLWithPath: DownloadManager.filePath(for: video.id)), isLocal: true)
            return
        }

        guard let preferred = preferredStream() else {
            statusLabel?.text = "Still loading streams..."
            statusLabel?.isHidden = false
            return
        }

        playBtn?.isHidden = true
        statusLabel?.isHidden = false

        // iOS 6 Secure Transport cannot negotiate GCM ciphers with googlevideo.com, so
        // AVPlayer cannot stream directly — download-then-play via CurlFetcher (OpenSSL).
        // iOS 7+ supports GCM, so try direct streaming with a quick download fallback.
        let iosVersion = (UIDevice.current.systemVersion as NSString).floatValue
        if iosVersion >= 7.0 {
            statusLabel?.text = "Loading stream..."
            tryStream(urlStr: preferred.url, fallbackDownload: preferred.url)
        } else {
            statusLabel?.text = "Downloading..."
            download(url: preferred.url, autoPlay: true)
        }
    }

    @objc private func downloadTapped() {
        guard !DownloadManager.isDownloaded(video.id) else { return }
        guard let preferred = preferredStream() else {
            statusLabel?.text = "Still loading streams..."
            statusLabel?.isHidden = false
            return
        }
        downloadBtn?.isEnabled = false
        downloadBtn?.setTitle("Downloading...", for: .normal)
        download(url: preferred.url, autoPlay: false)
    }

    // Load a URL into the singleton, attach the shared layer, and play once ready.
    private func startPlayback(url: URL, isLocal: Bool) {
        let resume = DownloadManager.isDownloaded(video.id) ? DownloadManager.position(for: video.id) : 0
        sp.load(video: video, url: url, isLocal: isLocal, resume: resume, artwork: thumbView?.image)
        attachLayer()
        pollUntilReady(maxTicks: 40, interval: 0.25, onReady: { [weak self] in
            guard let self = self else { return }
            self.thumbView?.isHidden = true
            self.statusLabel?.isHidden = true
            self.sp.applyResumeAndPlay()
            self.showControls()
        }, onFail: { [weak self] in
            guard let self = self else { return }
            self.statusLabel?.text = "Playback failed"
            self.statusLabel?.isHidden = false
            self.playBtn?.isHidden = false
        })
    }

    // iOS 7+ direct streaming with a quick download-then-play fallback.
    private func tryStream(urlStr: String, fallbackDownload: String) {
        guard let nsurl = URL(string: urlStr) else {
            statusLabel?.text = "Invalid stream URL"
            statusLabel?.isHidden = false
            playBtn?.isHidden = false
            return
        }
        sp.load(video: video, url: nsurl, isLocal: false, resume: 0, artwork: thumbView?.image)
        attachLayer()
        pollUntilReady(maxTicks: 8, interval: 0.5, onReady: { [weak self] in
            guard let self = self else { return }
            self.thumbView?.isHidden = true
            self.statusLabel?.isHidden = true
            self.sp.applyResumeAndPlay()
            self.showControls()
        }, onFail: { [weak self] in
            guard let self = self else { return }
            self.detachLayer()
            self.statusLabel?.text = "Downloading..."
            self.statusLabel?.isHidden = false
            self.download(url: fallbackDownload, autoPlay: true)
        })
    }

    // Poll the singleton's item status; fire onReady when ready, onFail on failure/timeout.
    private func pollUntilReady(maxTicks: Int, interval: TimeInterval,
                                onReady: @escaping () -> Void, onFail: @escaping () -> Void) {
        if let t = objc_getAssociatedObject(self, &timerKey) as? Timer { t.invalidate() }
        var count = 0
        let timer = Timer(timeInterval: interval, target: BlockTarget { [weak self] in
            guard let self = self else { return }
            count += 1
            if self.sp.isReady {
                if let t = objc_getAssociatedObject(self, &timerKey) as? Timer { t.invalidate() }
                onReady()
            } else if self.sp.isFailed || count > maxTicks {
                if let t = objc_getAssociatedObject(self, &timerKey) as? Timer { t.invalidate() }
                onFail()
            }
        }, selector: #selector(BlockTarget.fire), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        objc_setAssociatedObject(self, &timerKey, timer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // Hand the transfer to DownloadManager (which owns the completion), then poll for UI.
    // Because the manager — not this VC — holds the curl completion, the download keeps
    // running and registers as complete even after this VC is popped.
    private func download(url: String, autoPlay: Bool) {
        DownloadManager.startDownload(video, url: url)
        observeDownload(autoPlay: autoPlay)
    }

    // VC-owned poll timer that mirrors the manager-owned download's state into the UI.
    // Safe to lose (it's torn down on disappear) — the transfer itself lives in the manager.
    private func observeDownload(autoPlay: Bool) {
        if let t = objc_getAssociatedObject(self, &downloadPollKey) as? Timer { t.invalidate() }
        let t = Timer(timeInterval: 0.5, target: BlockTarget { [weak self] in
            guard let self = self else { return }
            if DownloadManager.isDownloading(self.video.id) {
                let pct = Int(DownloadManager.progress(for: self.video.id) * 100)
                self.statusLabel?.text = "Downloading \(pct)%..."
                self.statusLabel?.isHidden = false
                if !autoPlay { self.downloadBtn?.setTitle("Downloading \(pct)%...", for: .normal) }
                return
            }
            // Transfer finished (success or failure) — stop polling and resolve the UI.
            if let t = objc_getAssociatedObject(self, &downloadPollKey) as? Timer { t.invalidate() }
            if DownloadManager.isDownloaded(self.video.id) {
                self.updateDownloadButton()
                if autoPlay && !self.sp.isActive(self.video.id) {
                    self.statusLabel?.isHidden = true
                    self.thumbView?.isHidden = true
                    self.startPlayback(url: URL(fileURLWithPath: DownloadManager.filePath(for: self.video.id)), isLocal: true)
                } else if !autoPlay {
                    self.statusLabel?.text = "Saved for offline"
                    self.statusLabel?.isHidden = false
                }
            } else {
                self.statusLabel?.text = "Download failed"
                self.statusLabel?.isHidden = false
                self.playBtn?.isHidden = false
                self.updateDownloadButton()
            }
        }, selector: #selector(BlockTarget.fire), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        objc_setAssociatedObject(self, &downloadPollKey, t, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // MARK: - Fullscreen

    @objc private func fullscreenTapped() {
        guard sp.isActive(video.id) else {
            statusLabel?.text = "Start playback first"
            statusLabel?.isHidden = false
            return
        }
        if fsOverlay == nil {
            // Match the current device orientation if it's already landscape.
            let o = UIDevice.current.orientation
            let angle: CGFloat = (o == .landscapeRight) ? CGFloat(-Double.pi / 2) : CGFloat(Double.pi / 2)
            setFullscreen(true, angle: angle)
        } else {
            setFullscreen(false, angle: 0)
        }
    }

    private func enterFullscreen() {
        guard sp.isActive(video.id), let window = view.window else { return }
        let pLayer = sp.layer

        // The app is portrait-locked, so UIScreen.main.bounds is always the portrait
        // (320x568) frame. The overlay is sized to landscape (dims swapped) and rotated
        // to fill the screen — this is what makes the controls span the full width.
        let screen = UIScreen.main.bounds
        let overlay = UIView()
        overlay.backgroundColor = .black
        overlay.bounds = CGRect(x: 0, y: 0, width: screen.height, height: screen.width)
        overlay.center = CGPoint(x: screen.midX, y: screen.midY)
        overlay.transform = CGAffineTransform(rotationAngle: fsAngle)
        window.addSubview(overlay)
        fsOverlay = overlay

        // Hide the system status bar (the portrait clock at the top would otherwise
        // float over the rotated video — it can't rotate while the app is portrait-locked).
        setFSStatusBar(hidden: true)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pLayer.frame = overlay.bounds
        pLayer.videoGravity = AVLayerVideoGravity.resizeAspect
        overlay.layer.addSublayer(pLayer)
        CATransaction.commit()

        // Move the controls bar into the (rotated) overlay so it's usable in fullscreen.
        if let bar = controlsView, !bar.isHidden {
            let barH: CGFloat = 40
            bar.frame = CGRect(x: 0, y: overlay.bounds.height - barH, width: overlay.bounds.width, height: barH)
            overlay.addSubview(bar)
            layoutControls(width: overlay.bounds.width)
        }
    }

    private func setFSStatusBar(hidden: Bool) {
        fsActive = hidden
        let v = (UIDevice.current.systemVersion as NSString).floatValue
        if v >= 7.0 { setNeedsStatusBarAppearanceUpdate() }   // iOS 7+ only — crashes on iOS 6
        UIApplication.shared.setStatusBarHidden(hidden, with: .fade)
    }

    private func exitFullscreen() {
        guard let overlay = fsOverlay else { return }
        setFSStatusBar(hidden: false)
        let pLayer = sp.layer
        if let container = videoContainer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pLayer.frame = container.bounds
            if let thumbLayer = thumbView?.layer {
                container.layer.insertSublayer(pLayer, below: thumbLayer)
            } else {
                container.layer.addSublayer(pLayer)
            }
            CATransaction.commit()
        }
        // Restore the controls bar back into the video container.
        if let bar = controlsView, let container = videoContainer {
            let w = container.bounds.width
            let barH: CGFloat = 40
            bar.frame = CGRect(x: 0, y: container.bounds.height - barH, width: w, height: barH)
            container.addSubview(bar)
            layoutControls(width: w)
        }
        overlay.removeFromSuperview()
        fsOverlay = nil
    }
}

// MARK: - Timer helper (avoids retain cycles with closures on iOS 6)

private var timerKey = "timerKey"
private var progressTimerKey = "progressTimerKey"
private var downloadPollKey = "downloadPollKey"

private class BlockTarget: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}
