// Signals.swift — DispatchSource signal handling (spec §10): INT/TERM/HUP → graceful, second SIGINT → exit(130),
// USR1 → snapshot, USR2 → (re)enter full screen. Handlers run on `queue` (main by default).
// Owner: app agent (initial version by the skeleton step; used by Headless too).
import Foundation

final class Signals {
    private let queue: DispatchQueue
    private let handler: (Int32) -> Void
    private var sources: [DispatchSourceSignal] = []
    private var interrupts = 0

    init(queue: DispatchQueue = .main, handler: @escaping (Int32) -> Void) {
        self.queue = queue; self.handler = handler
    }

    /// Signals that were NOT installed because they were inherited as ignored (SIGHUP under `nohup`).
    private(set) var inheritedIgnored: [Int32] = []

    /// Ignore the default action for `sigs` and deliver them to `handler`. A second SIGINT exits immediately with 130.
    /// SIGHUP inherited as SIG_IGN (nohup, `start.sh --bg`) stays ignored: kqueue signal sources fire even for ignored
    /// signals, so installing a source would silently defeat nohup.
    func install(_ sigs: [Int32]) {
        for s in sigs {
            if s == SIGHUP && Signals.isIgnored(s) { inheritedIgnored.append(s); continue }
            signal(s, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: s, queue: queue)
            src.setEventHandler { [weak self, unowned src] in
                guard let self else { return }
                if s == SIGINT {
                    self.interrupts += max(1, Int(src.data))   // signals delivered together are coalesced
                    if self.interrupts >= 2 { _exit(130) }
                }
                self.handler(s)
            }
            src.resume()
            sources.append(src)
        }
    }

    /// Current disposition is SIG_IGN (read without changing it).
    static func isIgnored(_ s: Int32) -> Bool {
        var old = sigaction()
        guard sigaction(s, nil, &old) == 0 else { return false }
        return unsafeBitCast(old.__sigaction_u.__sa_handler, to: Int.self) == 1   // SIG_IGN == (void (*)(int))1
    }

    func cancel() { sources.forEach { $0.cancel() }; sources = [] }

    static func name(_ s: Int32) -> String {
        switch s {
        case SIGINT: "SIGINT"; case SIGTERM: "SIGTERM"; case SIGHUP: "SIGHUP"
        case SIGUSR1: "SIGUSR1"; case SIGUSR2: "SIGUSR2"; default: "SIG\(s)"
        }
    }
}
