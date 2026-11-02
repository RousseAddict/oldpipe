import UIKit
import AVFoundation

// MARK: - FFPlayerPOCVC
// Proof of concept for replacing AVPlayer: plays one video through ffplayer.c — FFmpeg's own
// demuxers and software H.264/AAC decoders, an AudioQueue for the sound, atempo for speed —
// fed the very URL AVPlayer would get from StreamResolver (a local file, the StreamProxy MP4
// route, or the transmuxed HLS playlist). Reached only through the iOS 5 test hook:
//   oldpipe://ffplay/id/<videoId>?itag=135&script=1&dump=1
//   oldpipe://ffplay/history/<n>      oldpipe://ffplay/file/<name in Documents>
// `script` runs a fixed speed/seek/pause sequence and logs the effective speed of every
// phase to Documents/ffpoc.log, so the whole thing can be checked with nobody at the screen.

final class FFPlayerPOCVC: UIViewController {

    enum Source {
        case video(Video, itag: Int?)
        case file(String)
    }

    private let source: Source
    private let options: [String: String]
    private var player: OpaquePointer?
    private var link: CADisplayLink?
    private var ticker: Timer?
    private var didSetupUI = false

    private let videoView = UIView()
    private let infoLabel = UILabel()
    private let playButton = UIButton(type: .custom)
    private var speedButtons: [UIButton] = []
    private static let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    private var lastState: Int32 = -1
    private var framesShown = 0

    // Scripted run: (seconds after playback starts, action, argument).
    private static let script: [(Double, String, Double)] = [
        (4, "snap", 0), (6, "speed", 1.5), (12, "speed", 2.0), (18, "speed", 0.5),
        (24, "speed", 1.0), (27, "seek", 60), (31, "snap", 1), (32, "pause", 0),
        (34, "play", 0), (38, "seek", 10), (42, "end", 0),
    ]
    private var scriptStart: Double = 0
    private var scriptIndex = 0
    private var phaseWall: Double = 0
    private var phasePos: Double = 0
    // Each phase is measured from one tick AFTER its action: by then a seek has landed and the
    // half second of audio already stretched at the old speed has played out.
    private var phaseResetPending = false

    static let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]

    init(source: Source, options: [String: String]) {
        self.source = source
        self.options = options
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Backstop for a controller dropped without being popped (another test URL pushed over it):
    // the display link and timer hold only weak references, so this still runs.
    deinit { teardown() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "FFmpeg player (POC)"
        view.backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
        ffp_set_log_file(FFPlayerPOCVC.docs + "/ffpoc.log")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didSetupUI else { return }
        didSetupUI = true
        setupUI()
        startSource()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent { teardown() }
    }

    // MARK: - UI

    private func setupUI() {
        let w = UIScreen.main.bounds.width
        videoView.frame = CGRect(x: 0, y: 0, width: w, height: floor(w * 9 / 16))
        videoView.backgroundColor = .black
        videoView.layer.contentsGravity = CALayerContentsGravity.resizeAspect
        view.addSubview(videoView)

        var y = videoView.frame.maxY + 10
        playButton.frame = CGRect(x: 8, y: y, width: 60, height: 36)
        playButton.setImage(UIImage(named: "play"), for: .normal)
        playButton.backgroundColor = UIColor(white: 0.2, alpha: 1)
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        view.addSubview(playButton)
        for (i, (title, delta)) in [("-10s", -10.0), ("+10s", 10.0)].enumerated() {
            let b = makeButton(title, frame: CGRect(x: 76 + CGFloat(i) * 68, y: y, width: 60, height: 36))
            b.tag = Int(delta)
            b.addTarget(self, action: #selector(skipTapped(_:)), for: .touchUpInside)
        }

        y += 46
        let bw = (w - 16 - 5 * 4) / 6
        for (i, s) in FFPlayerPOCVC.speeds.enumerated() {
            let b = makeButton(String(format: "%gx", s), frame: CGRect(x: 8 + CGFloat(i) * (bw + 4), y: y, width: bw, height: 36))
            b.tag = i
            b.addTarget(self, action: #selector(speedTapped(_:)), for: .touchUpInside)
            speedButtons.append(b)
        }
        highlightSpeed(1.0)

        y += 46
        infoLabel.frame = CGRect(x: 8, y: y, width: w - 16, height: UIScreen.main.bounds.height - y - 64 - 60)
        infoLabel.backgroundColor = .clear
        infoLabel.textColor = UIColor(white: 0.75, alpha: 1)
        infoLabel.font = UIFont.systemFont(ofSize: 11)
        infoLabel.numberOfLines = 0
        infoLabel.text = "Resolving…"
        view.addSubview(infoLabel)
    }

    private func makeButton(_ title: String, frame: CGRect) -> UIButton {
        let b = UIButton(type: .custom)
        b.frame = frame
        b.setTitle(title, for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
        b.backgroundColor = UIColor(white: 0.2, alpha: 1)
        view.addSubview(b)
        return b
    }

    private func highlightSpeed(_ s: Double) {
        for (i, b) in speedButtons.enumerated() {
            b.backgroundColor = FFPlayerPOCVC.speeds[i] == s ? Theme.accent : UIColor(white: 0.2, alpha: 1)
        }
    }

    // MARK: - Source

    private func startSource() {
        switch source {
        case .file(let name):
            start(FFPlayerPOCVC.docs + "/" + name)
        case .video(let video, let itag):
            // One player at a time: AVPlayer must give up the audio session and the proxy route.
            VideoPlayer.shared.stop()
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            VideoPlayer.shared.reactivateSession()
            log("resolving \(video.id) itag=\(itag.map { String($0) } ?? "default")")
            StreamResolver.resolve(video, preferredItag: itag) { [weak self] resolved in
                guard let self = self, self.didSetupUI else { return }
                guard let r = resolved else {
                    self.log("resolve FAILED")
                    self.infoLabel.text = "Could not resolve a stream."
                    return
                }
                self.start(r.url.isFileURL ? r.url.path : r.url.absoluteString)
            }
        }
    }

    private func start(_ url: String) {
        log("POC open \(url) options=\(options)")
        let p = ffp_create()
        if options["dump"] == "1" { ffp_set_dump_file(p, FFPlayerPOCVC.docs + "/ffpoc-audio.pcm") }
        if options["mute"] == "1" { ffp_set_volume(p, 0) }
        if options["noaudio"] == "1" { ffp_set_video_only(p, 1) }
        if options["stretch"] == "atempo" { ffp_set_atempo(p, 1) }
        player = p
        ffp_open(p, url)
        ffp_play(p)

        let l = CADisplayLink(target: TickTarget { [weak self] in self?.frameTick() }, selector: #selector(TickTarget.fire))
        l.add(to: RunLoop.main, forMode: .common)
        link = l
        let t = Timer(timeInterval: 1.0, target: TickTarget { [weak self] in self?.secondTick() },
                      selector: #selector(TickTarget.fire), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func teardown() {
        link?.invalidate(); link = nil
        ticker?.invalidate(); ticker = nil
        if let p = player { ffp_destroy(p) }
        player = nil
    }

    // MARK: - Ticks

    private func frameTick() {
        guard let p = player, let img = ffp_copy_frame(p) else { return }
        videoView.layer.contents = img
        framesShown += 1
    }

    private func secondTick() {
        guard let p = player else { return }
        let state = ffp_state(p)
        if state != lastState {
            lastState = state
            log("state \(state)")
            if Int(state) == FFP_PLAYING, options["script"] == "1", scriptStart == 0 {
                scriptStart = CFAbsoluteTimeGetCurrent()
                phaseWall = scriptStart
                phasePos = ffp_position(p)
                log("SCRIPT start")
            }
        }
        playButton.setImage(UIImage(named: Int(state) == FFP_PLAYING ? "pause" : "play"), for: .normal)
        var buf = [CChar](repeating: 0, count: 600)
        ffp_stats_line(p, &buf, Int32(buf.count))
        let line = String(cString: buf)
        ffp_log_line(line)
        if Int(state) == FFP_FAILED {
            infoLabel.text = "FAILED: " + String(cString: ffp_error(p))
        } else {
            infoLabel.text = line.replacingOccurrences(of: " | ", with: "\n")
        }
        if scriptStart > 0 {
            if phaseResetPending {
                phaseResetPending = false
                phaseWall = CFAbsoluteTimeGetCurrent()
                phasePos = ffp_position(p)
            }
            runScript(p)
        }
    }

    private func runScript(_ p: OpaquePointer) {
        let t = CFAbsoluteTimeGetCurrent() - scriptStart
        while scriptIndex < FFPlayerPOCVC.script.count, t >= FFPlayerPOCVC.script[scriptIndex].0 {
            let (_, action, arg) = FFPlayerPOCVC.script[scriptIndex]
            scriptIndex += 1
            if action == "snap" { snapshot(arg == 0 ? "playing" : "after-seek"); continue }
            let pos = ffp_position(p), now = CFAbsoluteTimeGetCurrent()
            log(String(format: "PHASE speed=%.2f: media %.2fs over %.2fs wall -> effective %.2fx",
                       ffp_speed(p), pos - phasePos, now - phaseWall, (pos - phasePos) / (now - phaseWall)))
            switch action {
            case "speed": ffp_set_speed(p, arg); highlightSpeed(arg)
            case "seek":  ffp_seek(p, arg)
            case "pause": ffp_pause(p)
            case "play":  ffp_play(p)
            default:
                snapshot("end")
                log("SCRIPT DONE frames shown on screen: \(framesShown)")
                scriptStart = 0
                scriptIndex = FFPlayerPOCVC.script.count
                return
            }
            log("SCRIPT \(action) \(arg)")
            phaseResetPending = true
        }
    }

    // The window, nav bar included, as the user would see it — written next to the log.
    private func snapshot(_ name: String) {
        guard let layer = view.window?.layer else { return }
        UIGraphicsBeginImageContextWithOptions(layer.bounds.size, true, 1)
        if let ctx = UIGraphicsGetCurrentContext() { layer.render(in: ctx) }
        let img = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        let path = FFPlayerPOCVC.docs + "/ffpoc-\(name).png"
        if let data = img?.pngData() { (data as NSData).write(toFile: path, atomically: true) }
        log("snapshot \(path)")
    }

    private func log(_ s: String) { ffp_log_line("[POC] " + s) }

    // MARK: - Controls

    @objc private func playTapped() {
        guard let p = player else { return }
        if Int(ffp_state(p)) == FFP_PLAYING { ffp_pause(p) } else { ffp_play(p) }
    }

    @objc private func skipTapped(_ b: UIButton) {
        guard let p = player else { return }
        ffp_seek(p, ffp_position(p) + Double(b.tag))
    }

    @objc private func speedTapped(_ b: UIButton) {
        guard let p = player else { return }
        let s = FFPlayerPOCVC.speeds[b.tag]
        ffp_set_speed(p, s)
        highlightSpeed(s)
    }
}

// Timer / CADisplayLink target that does not retain the controller (both retain their target).
private final class TickTarget: NSObject {
    let block: () -> Void
    init(_ b: @escaping () -> Void) { block = b }
    @objc func fire() { block() }
}

// MARK: - PlayerScript
// FFPlayerPOCVC's timed run, but driven through VideoPlayer.shared: it measures the real video
// page with whichever engine Settings picked, so the same numbers come out for AVPlayer and
// FFmpeg. Started by oldpipe://player/script once a video is playing.
final class PlayerScript: NSObject {
    static let shared = PlayerScript()

    private static let steps: [(Double, String, Double)] = [
        (4, "snap", 0), (6, "speed", 1.5), (12, "speed", 2.0), (18, "speed", 0.5),
        (24, "speed", 1.0), (27, "seek", 60), (31, "snap", 1), (32, "pause", 0),
        (34, "play", 0), (38, "seek", 10), (42, "end", 0),
    ]
    private var timer: Timer?
    private var started: Double = 0
    private var index = 0
    private var phaseWall: Double = 0
    private var phasePos: Double = 0
    private var resetPending = false

    func start() {
        timer?.invalidate()
        let sp = VideoPlayer.shared
        started = CFAbsoluteTimeGetCurrent()
        index = 0
        phaseWall = started
        phasePos = sp.currentSeconds
        resetPending = false
        log("start engine=" + (AppSettings.ffmpegPlayer ? "FFmpeg" : "AVPlayer")
            + " video=" + (sp.currentVideo?.id ?? "none"))
        let t = Timer(timeInterval: 1.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func tick() {
        let sp = VideoPlayer.shared
        if resetPending {
            resetPending = false
            phaseWall = CFAbsoluteTimeGetCurrent()
            phasePos = sp.currentSeconds
        }
        let t = CFAbsoluteTimeGetCurrent() - started
        while index < PlayerScript.steps.count, t >= PlayerScript.steps[index].0 {
            let (_, action, arg) = PlayerScript.steps[index]
            index += 1
            if action == "snap" { snapshot(arg == 0 ? "page-playing" : "page-after-seek"); continue }
            let pos = sp.currentSeconds, now = CFAbsoluteTimeGetCurrent()
            log(String(format: "PHASE speed=%.2f: media %.2fs over %.2fs wall -> effective %.2fx",
                       Double(sp.playbackRate), pos - phasePos, now - phaseWall, (pos - phasePos) / (now - phaseWall)))
            switch action {
            case "speed": sp.setPlaybackRate(Float(arg))
            case "seek":  sp.seek(toSeconds: arg)
            case "pause": sp.pause()
            case "play":  sp.play()
            default:
                snapshot("page-end")
                log("DONE")
                timer?.invalidate(); timer = nil
                return
            }
            log(action + String(format: " %.2f", arg))
            resetPending = true
        }
    }

    private func snapshot(_ name: String) {
        guard let layer = UIApplication.shared.keyWindow?.layer else { return }
        UIGraphicsBeginImageContextWithOptions(layer.bounds.size, true, 1)
        if let ctx = UIGraphicsGetCurrentContext() { layer.render(in: ctx) }
        let img = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        let path = FFPlayerPOCVC.docs + "/ffpoc-\(name).png"
        if let data = img?.pngData() { (data as NSData).write(toFile: path, atomically: true) }
        log("snapshot " + path)
    }

    private func log(_ s: String) { ffp_log_line("[SCRIPT] " + s) }
}
