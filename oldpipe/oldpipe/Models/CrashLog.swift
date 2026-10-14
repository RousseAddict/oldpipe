import UIKit

// MARK: - CrashLog
// A crash-PROOF launch trace, which is a different job from DebugLog next door.
//
// DebugLog is an in-memory ring buffer, opt-in from Settings, exported to the clipboard.
// All three of those properties make it useless for a crash during launch: the buffer dies
// with the process, the toggle lives on a screen the user can never reach, and so does the
// export button. This type instead writes every line straight to a file and fsync()s before
// returning, so the LAST line written survives the process being killed — and that last line
// is precisely the answer to "how far did it get?".
//
// Two files, rotated on every launch:
//   oldpipe-crash-previous.log   the run BEFORE this one  <- the crashing run, after a relaunch
//   oldpipe-crash-current.log    this run
// The rotation is the important half. Once the user relaunches to go fetch the log, the
// crashing run is already history, so it has to have been moved somewhere safe first.
//
// Names are deliberately long and unique so a jailbroken user can find them with a Filza
// filename search instead of having to guess the app's container UUID.
enum CrashLog {

    private static let dir: String =
        NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
        ?? NSTemporaryDirectory()

    static let currentPath  = dir + "/oldpipe-crash-current.log"
    static let previousPath = dir + "/oldpipe-crash-previous.log"

    // Cached as C strings at install() time. The signal handler below must not allocate (see
    // there), and touching a Swift String from a signal context would do exactly that.
    private static var cPath: UnsafeMutablePointer<CChar>?
    private static var scratch: UnsafeMutablePointer<CChar>?

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // MARK: Install

    // Call as the very first statement of didFinishLaunchingWithOptions. Anything that crashes
    // before this point leaves NO current-log file at all — which is itself a useful verdict:
    // it means we died in dyld, in the entry stub, or in Swift runtime init, i.e. before any
    // of our own code ran.
    static func install() {
        rotate()
        cPath = strdup(currentPath)
        scratch = UnsafeMutablePointer<CChar>.allocate(capacity: 64)

        NSSetUncaughtExceptionHandler { ex in CrashLog.record(exception: ex) }
        for s in [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP] {
            signal(s, CrashLog.signalHandler)
        }

        let d = UIDevice.current
        mark("=== launch \(d.systemName) \(d.systemVersion) \(d.model) ===")
    }

    private static func rotate() {
        let fm = FileManager.default
        try? fm.removeItem(atPath: previousPath)
        if fm.fileExists(atPath: currentPath) {
            try? fm.moveItem(atPath: currentPath, toPath: previousPath)
        }
    }

    // MARK: Breadcrumbs

    // Always on — there is no toggle, by design. The cost is a handful of writes per launch
    // and the whole value proposition is that it works on a device we cannot reach.
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

    // ObjC exception: this runs in NORMAL context (the runtime is still healthy), so Foundation
    // and allocation are fine here, and callStackSymbols is worth having.
    private static func record(exception ex: NSException) {
        var out = "\n*** UNCAUGHT EXCEPTION ***\n"
        out += "name:   \(ex.name.rawValue)\n"
        out += "reason: \(ex.reason ?? "(none)")\n"
        out += ex.callStackSymbols.joined(separator: "\n")
        out += "\n"
        append(out)
    }

    // Fatal signal: this runs on a process that may have a corrupt heap, so the handler must
    // not allocate — a malloc here would deadlock and we would record nothing at all. Hence the
    // preallocated path/scratch buffers, the hand-rolled integer formatting, and raw write().
    // No backtrace() call either: adding a new libSystem import to an iOS 5 build is precisely
    // the class of bug being hunted, and the breadcrumb trail already localises the crash.
    private static let signalHandler: @convention(c) (Int32) -> Void = { sig in
        if let p = CrashLog.cPath, let buf = CrashLog.scratch {
            let fd = open(p, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            if fd >= 0 {
                let prefix: StaticString = "\n*** FATAL SIGNAL "
                _ = prefix.withUTF8Buffer { b in Darwin.write(fd, b.baseAddress, b.count) }

                var n = Int(sig), i = 0
                if n == 0 { buf[0] = 48; i = 1 }
                while n > 0 { buf[i] = CChar(48 + n % 10); n /= 10; i += 1 }
                var j = 0
                while j < i / 2 { let t = buf[j]; buf[j] = buf[i - 1 - j]; buf[i - 1 - j] = t; j += 1 }
                _ = Darwin.write(fd, buf, i)

                let suffix: StaticString = " ***\n"
                _ = suffix.withUTF8Buffer { b in Darwin.write(fd, b.baseAddress, b.count) }
                fsync(fd)
                close(fd)
            }
        }
        // Restore the default disposition and re-raise so the OS still produces its own crash
        // report for anyone who CAN read /var/mobile/Library/Logs/CrashReporter.
        signal(sig, SIG_DFL)
        raise(sig)
    }

    // MARK: Export

    // Previous run first: after a crash-on-launch the user has necessarily relaunched, so the
    // interesting trace is the PREVIOUS file and it should not be buried below this run's.
    static func exportText() -> String {
        var out = "oldpipe crash log\n"
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
