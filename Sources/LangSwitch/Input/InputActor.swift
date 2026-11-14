import Foundation

/// A serial executor backed by one dedicated thread and its run loop.
///
/// The keyboard event tap must not share a thread with the interface: every key press on the Mac waits
/// for the tap's callback, so a busy main thread would become typing lag in every application. The tap's
/// run-loop source lives on this thread, and everything that touches typing state runs here too.
final class RunLoopExecutor: SerialExecutor, @unchecked Sendable {
    // Written once by the thread before `ready` is signalled, read-only afterwards.
    private nonisolated(unsafe) var runLoop: CFRunLoop?
    private nonisolated(unsafe) var thread: Thread?
    private let ready = DispatchSemaphore(value: 0)

    init(name: String) {
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            // A run loop without sources returns immediately; the port keeps it alive.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            while true { CFRunLoopRun() }
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        ready.wait()
    }

    var cfRunLoop: CFRunLoop { runLoop! }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            job.runSynchronously(on: asUnownedSerialExecutor())
        }
        CFRunLoopWakeUp(runLoop)
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor { UnownedSerialExecutor(ordinary: self) }

    func checkIsolated() {
        precondition(Thread.current === thread, "expected the input thread")
    }
}

/// Isolation domain of everything that sees key presses.
@globalActor
actor InputActor {
    static let shared = InputActor()
    static let executor = RunLoopExecutor(name: "LangSwitch.Input")

    nonisolated var unownedExecutor: UnownedSerialExecutor { Self.executor.asUnownedSerialExecutor() }

    /// Runs `operation` synchronously when already on the input thread; traps otherwise.
    ///
    /// The event tap callback is a C function invoked on the input thread's run loop. This is the
    /// documented synchronous boundary into the actor, the same shape as `MainActor.assumeIsolated`.
    static func assumeIsolated<T: Sendable>(_ operation: @InputActor () throws -> T) rethrows -> T {
        executor.checkIsolated()
        return try withoutActuallyEscaping(operation) { isolated in
            try unsafeBitCast(isolated, to: (() throws -> T).self)()
        }
    }
}
