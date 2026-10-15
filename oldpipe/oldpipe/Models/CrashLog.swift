import UIKit

// MARK: - CrashLog
// The Swift half of the launch trace. The C half (ios5_launchlog.h) owns the file,
// the rotation and the fatal-signal handlers, because it runs far earlier than any
// Swift can: its first marker is written from libS5's constructor, before the Swift
// runtime has even initialised. This type just appends to the same file once Swift
// is alive, and adds the two things C cannot do — ObjC exception reporting and a
// readable export.
//
// Why not DebugLog next door: that is an in-memory ring buffer, opt-in from Settings
// and exported to the clipboard. All three properties make it useless for a crash
// during launch — the buffer dies with the process, and the toggle and the export
// button both live on a screen the user can never reach.
//
// Two files, rotated by the C side on every launch:
//   oldpipe-launch-previous.log   the run BEFORE this one  <- the crashing run
//   oldpipe-launch.log            this run
// The rotation is the important half: fetching the log means relaunching, and the
// relaunch would otherwise overwrite the evidence.
enum CrashLog {

    private static let dir: String =
        NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
        ?? NSTemporaryDirectory()

    static let currentPath  = dir + "/oldpipe-launch.log"
    static let previousPath = dir + "/oldpipe-launch-previous.log"

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // MARK: Install

    // Called as the very first statement of didFinishLaunchingWithOptions. By the time
    // this runs the file already holds markers 1-3 from the C constructors and the app
    // delegate's init, so an absent marker 4 localises the crash to UIApplicationMain.
    //
    // No signal handlers here: ios5_log_arm() armed them from libS5's constructor, which
    // covers the whole window this function could never see. Re-arming from Swift would
    // only narrow the coverage.
    static func install() {
        NSSetUncaughtExceptionHandler { ex in CrashLog.record(exception: ex) }
        let d = UIDevice.current
        mark("4. didFinishLaunching: entered — \(d.systemName) \(d.systemVersion) \(d.model)")
    }

    // MARK: Breadcrumbs

    // Always on, by design: no toggle. The cost is a handful of writes per launch, and
    // the entire value is that it works on a device we cannot reach.
    static func mark(_ stage: String) {
        append("[\(formatter.string(from: Date()))] \(stage)\n")
    }

    private static func append(_ line: String) {
        let fd = open(currentPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        _ = line.withCString { p in Darwin.write(fd, p, strlen(p)) }
        fsync(fd)                 // the point of the whole type — unflushed == lost
        close(fd)
    }

    // MARK: Fatal handlers

    // ObjC exception: runs in NORMAL context (the runtime is still healthy), so Foundation
    // and allocation are fine here, and callStackSymbols is worth having. This is the one
    // fatal path the C side cannot cover, since it never reaches a signal.
    private static func record(exception ex: NSException) {
        var out = "\n*** UNCAUGHT EXCEPTION ***\n"
        out += "name:   \(ex.name.rawValue)\n"
        out += "reason: \(ex.reason ?? "(none)")\n"
        out += ex.callStackSymbols.joined(separator: "\n")
        out += "\n"
        append(out)
    }

    // MARK: Export

    // Previous run first: after a crash-on-launch the user has necessarily relaunched, so
    // the interesting trace is the PREVIOUS file and it should not be buried below this one.
    static func exportText() -> String {
        var out = "oldpipe launch log\n"
        out += "iOS \(UIDevice.current.systemVersion)\n"
        out += "path: \(dir)\n"
        for (label, path) in [("PREVIOUS RUN", previousPath), ("CURRENT RUN", currentPath)] {
            out += "\n===== \(label) =====\n"
            out += (try? String(contentsOfFile: path, encoding: .utf8)) ?? "(none)\n"
        }
        return out
    }

    static func clear() {
        let fm = FileManager.default
        try? fm.removeItem(atPath: currentPath)
        try? fm.removeItem(atPath: previousPath)
    }
}
