import Foundation

// MARK: - Dispatch for iOS 5
//
// Swift's Dispatch overlay cannot run on iOS 5. DispatchQueue is the imported
// Objective-C class OS_dispatch_queue, and dispatch objects only became
// Objective-C objects in iOS 6; before that they are plain C structs. The
// device's own dyld shared cache settles it — dispatch_queue_create appears 58
// times in 5.1.1, OS_dispatch_queue not once. So creating a queue, or just
// touching DispatchQueue.main, messages a class that does not exist and dies
// inside libobjc. GCD itself is entirely fine; only the overlay is missing.
//
// LegacyQueue/LegacySemaphore call the C API through the shims in
// ios5_dispatch.c. Their signatures deliberately mirror DispatchQueue and
// DispatchSemaphore so the call sites read the same on every target, and the
// typealiases at the bottom pick the real thing everywhere except iOS 5.

#if IOS5_TARGET

final class LegacyQueue {

    // Mirrors DispatchQueue.Attributes closely enough that `.concurrent` at a
    // call site resolves against either type without the source changing.
    struct Attributes: OptionSet {
        let rawValue: Int
        init(rawValue: Int) { self.rawValue = rawValue }
        static let concurrent = Attributes(rawValue: 1)
    }

    private let raw: UnsafeMutableRawPointer

    private init(raw: UnsafeMutableRawPointer) { self.raw = raw }

    init(label: String, attributes: Attributes = []) {
        raw = label.withCString { ios5_q_create($0, attributes.contains(.concurrent) ? 1 : 0) }
    }

    static let main = LegacyQueue(raw: ios5_q_main())

    // The closure is boxed and passed as the context pointer dispatch_async_f
    // takes. passRetained balances the release inside the trampoline, so the
    // closure stays alive exactly until it has run.
    func async(execute work: @escaping () -> Void) {
        let box = Unmanaged.passRetained(Box(work)).toOpaque()
        ios5_q_async(raw, { ctx in
            guard let ctx = ctx else { return }
            let box = Unmanaged<Box>.fromOpaque(ctx)
            box.takeUnretainedValue().work()
            box.release()
        }, box)
    }

    // dispatch_sync_f blocks, so the closure outlives the call and needs no
    // retain. Deliberately NOT rethrows: `rethrows` may only throw errors the
    // compiler can trace back to the parameter, which it cannot through a C
    // function pointer. None of the call sites throw, and a non-throwing
    // closure satisfies DispatchQueue.sync on the other targets just as well.
    func sync<T>(execute work: () -> T) -> T {
        var result: T!
        withoutActuallyEscaping(work) { escaping in
            var holder = SyncBox { result = escaping() }
            withUnsafeMutablePointer(to: &holder) { p in
                ios5_q_sync(raw, { ctx in
                    guard let ctx = ctx else { return }
                    ctx.assumingMemoryBound(to: SyncBox.self).pointee.run()
                }, UnsafeMutableRawPointer(p))
            }
        }
        return result
    }

    private final class Box {
        let work: () -> Void
        init(_ work: @escaping () -> Void) { self.work = work }
    }

    private struct SyncBox {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }
}

final class LegacySemaphore {
    private let raw: UnsafeMutableRawPointer
    init(value: Int) { raw = ios5_sem_create(value) }
    func wait() { ios5_sem_wait(raw) }
    func signal() { ios5_sem_signal(raw) }
    func waitFor(seconds: Double) -> Bool { ios5_sem_wait_timeout(raw, seconds) == 1 }
}

typealias AppQueue = LegacyQueue
typealias AppSemaphore = LegacySemaphore

#else

typealias AppQueue = DispatchQueue
typealias AppSemaphore = DispatchSemaphore

extension DispatchSemaphore {
    // One spelling for the timed wait on every target, so the two call sites
    // that need it do not have to be written twice.
    func waitFor(seconds: Double) -> Bool {
        wait(timeout: .now() + seconds) == .success
    }
}

#endif
