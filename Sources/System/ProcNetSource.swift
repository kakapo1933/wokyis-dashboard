// ProcNetSource.swift — per-app traffic for the network view's side column (`net.proc`): a `nettop` child per 2 s
// window, its CSV parser, pid → app name, and the monitor that runs it only while the column is on screen.
//
// * Child: /usr/bin/nettop -P -d -x -n -L 2 -s 2 -J bytes_in,bytes_out. It exits after one 2 s window and prints two
//   CSV blocks: block 1 = totals of the flows open at start (ignored), block 2 = bytes moved during the window.
//   Why this shape (all measured on macOS 27, not assumed):
//     - Subtracting two one-shot snapshots (-L 1) does not work: nettop only lists OPEN flows, so a process total drops
//       when a connection closes and a connection that opens and closes between two snapshots is never seen (6 curl
//       runs, 1.52 MB: 0 bytes seen). nettop's own delta over the same window reported 1.56 MB.
//     - stdin must be a pipe that stays open and silent. With /dev/null nettop's key-press source fires for ever
//       (> 1 core for the whole window); with the pipe one run costs ≈ 0.01 s CPU.
//     - -n: without it every sample waits ≈ 5 s for reverse DNS.
// * Names: nettop truncates the process name to 15 characters ("com.apple.WebKi"), so the name comes from the pid:
//   proc_pidpath → the OUTERMOST .app of the path ("…/Slack.app/…/Slack Helper.app/…" → "Slack"); an XPC service
//   outside any .app (com.apple.WebKit.Networking) → the app responsible for it (Safari) via the private
//   responsibility_get_pid_responsible_for_pid (dlsym, never linked; missing → the executable name); anything else →
//   the executable name without "com.apple.". A process that already exited keeps nettop's token.
//   Rows are summed per name (an app's helpers are one row), idle names dropped, busiest (rx + tx) first.
// * ProcNetMonitor: runs back to back while active (the child paces itself); a failure (spawn, rc ≠ 0, no second
//   block, 6 s watchdog, injected `fail net.proc`) is delivered as .failed and retried after one window.
//   ERR (event) on failure onset / token change, RECOVER (event) when it clears; `NETP` line per window at sample level.
//   setActive(false) / stop() terminate a running child. `onUpdate` is called on MAIN, never while inactive.
// Owner: sampler agent.
import Darwin
import Foundation

enum ProcNetParser {
    struct Row: Equatable, Sendable { let token: String; let pid: pid_t; let bytesIn: UInt64; let bytesOut: UInt64 }

    /// Rows of the LAST block; nil unless the text holds ≥ `minBlocks` blocks whose header names both columns.
    /// A block starts at a header line (empty process column: ",bytes_in,bytes_out,"); the columns are located by
    /// name because nettop documents that the -J order may change.
    static func lastBlock(_ text: String, minBlocks: Int = 2) -> [Row]? {
        var blocks = 0
        var cols: (n: Int, i: Int, o: Int)?
        var rows: [Row] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            if line.hasPrefix(",") {
                guard let i = f.firstIndex(of: "bytes_in"), let o = f.firstIndex(of: "bytes_out") else { return nil }
                blocks += 1; cols = (f.count, i, o); rows.removeAll(keepingCapacity: true)
                continue
            }
            guard let c = cols, f.count >= c.n else { continue }
            let extra = f.count - c.n                      // a "," inside the process name
            let name = f[0...extra].joined(separator: ",")
            guard let dot = name.lastIndex(of: "."), let pid = pid_t(name[name.index(after: dot)...]), pid > 0,
                  let bi = UInt64(f[c.i + extra]), let bo = UInt64(f[c.o + extra]) else { continue }
            rows.append(Row(token: String(name[..<dot]), pid: pid, bytesIn: bi, bytesOut: bo))
        }
        return blocks >= minBlocks ? rows : nil
    }
}

enum ProcNames {
    /// The naming rule (pure; `responsiblePath` is only asked for an XPC service outside any .app).
    static func display(path: String?, token: String, responsiblePath: () -> String?) -> String {
        guard let path, !path.isEmpty else { return token }
        if let a = appName(path) { return a }
        if path.contains(".xpc/"), let r = responsiblePath(), let a = appName(r) { return a }
        let exe = (path as NSString).lastPathComponent
        return exe.hasPrefix("com.apple.") ? String(exe.dropFirst("com.apple.".count)) : exe
    }

    /// Outermost bundle of an executable path: "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/…" → "Slack".
    static func appName(_ path: String) -> String? {
        for c in path.split(separator: "/") where c.hasSuffix(".app") && c.count > 4 { return String(c.dropLast(4)) }
        return nil
    }

    static func path(_ pid: pid_t) -> String? {
        var b = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &b, UInt32(b.count)) > 0 ? String(cString: b) : nil
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsible: ResponsibleFn? = {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid").map { unsafeBitCast($0, to: ResponsibleFn.self) }
    }()
    static func responsiblePath(_ pid: pid_t) -> String? {
        guard let f = responsible else { return nil }
        let r = f(pid)
        return r > 0 && r != pid ? path(r) : nil
    }

    static func live(pid: pid_t, token: String) -> String {
        display(path: path(pid), token: token) { responsiblePath(pid) }
    }
}

/// One window's rows → per-app rates. Names are cached per (pid, token) and looked up only for rows with traffic.
struct ProcNetAggregator {
    var resolve: (pid_t, String) -> String = { ProcNames.live(pid: $0, token: $1) }
    private var names: [pid_t: (token: String, name: String)] = [:]

    init() {}
    init(resolve: @escaping (pid_t, String) -> String) { self.resolve = resolve }

    mutating func traffic(_ rows: [ProcNetParser.Row], seconds: Double) -> [ProcTraffic] {
        var sum: [String: (rx: UInt64, tx: UInt64)] = [:]
        var seen: [pid_t: (token: String, name: String)] = [:]
        for r in rows {
            let cached = names[r.pid].flatMap { $0.token == r.token ? $0.name : nil }
            guard r.bytesIn > 0 || r.bytesOut > 0 else {
                if let cached { seen[r.pid] = (r.token, cached) }
                continue
            }
            let n = cached ?? resolve(r.pid, r.token)
            seen[r.pid] = (r.token, n)
            let s = sum[n] ?? (0, 0)
            sum[n] = (s.rx &+ r.bytesIn, s.tx &+ r.bytesOut)
        }
        names = seen
        return sum.map { ProcTraffic(name: $0.key, rx: Double($0.value.rx) / seconds, tx: Double($0.value.tx) / seconds) }
            .sorted { a, b in a.rx + a.tx != b.rx + b.tx ? a.rx + a.tx > b.rx + b.tx : a.name < b.name }
    }
}

final class ProcNetMonitor: @unchecked Sendable {
    static let path = "/usr/bin/nettop"
    static let windowSeconds = 2
    static let arguments = ["-P", "-d", "-x", "-n", "-L", "2", "-s", "\(windowSeconds)", "-J", "bytes_in,bytes_out"]
    static let watchdogSeconds: Double = 6

    let injector: Injector
    let log: EventLog
    let onUpdate: @Sendable (Reading<[ProcTraffic]>) -> Void
    let queue = DispatchQueue(label: "wokyis.netproc", qos: .utility)
    // --- queue-only state ---
    private var active = false
    private var runID: UInt64 = 0
    private var inFlight = false
    private var timedOut = false
    private var retryPending = false
    private var agg = ProcNetAggregator()
    private var failing: (token: String, since: Date, n: Int)?
    // --- guarded by `lock` ---
    private let lock = NSLock()
    private var process: Process?
    private var delivering = false

    /// `onUpdate` is called on MAIN, only between setActive(true) and setActive(false) / stop().
    init(injector: Injector, log: EventLog, onUpdate: @escaping @Sendable (Reading<[ProcTraffic]>) -> Void) {
        self.injector = injector; self.log = log; self.onUpdate = onUpdate
    }

    /// pid of the running child (nil when none). Thread-safe.
    var childPID: pid_t? { lock.lock(); defer { lock.unlock() }; return process.flatMap { $0.isRunning ? $0.processIdentifier : nil } }

    /// Idempotent. Off → the running child is terminated and its result dropped.
    func setActive(_ on: Bool) {
        lock.lock(); delivering = on; lock.unlock()
        queue.async { [self] in
            guard on != active else { return }
            active = on
            if on { run() } else { abandon() }
        }
    }

    /// Terminates a running child; after return no further onUpdate calls are made. Must not be called on `queue`.
    func stop() {
        lock.lock(); delivering = false; lock.unlock()
        queue.sync { active = false; abandon() }
    }

    // MARK: runs (queue)

    private func abandon() {
        runID &+= 1; inFlight = false
        lock.lock(); let p = process; process = nil; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    private func run() {
        guard active, !inFlight else { return }
        do { try injector.check(.netProc) } catch {
            fail((error as? SourceError) ?? .parse("\(error)"))
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.path); p.arguments = Self.arguments
        let out = Pipe(), keepOpen = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = keepOpen            // never written, closed only after the child exited (see header)
        // Not waitUntilExit(): it waits on the calling thread's run loop, and on a GCD worker nothing is bound to wake
        // that loop — measured: the 4th run never returned (sample: 846/846 in -[NSConcreteTask waitUntilExit]).
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch {
            try? out.fileHandleForReading.close(); try? out.fileHandleForWriting.close()
            fail(BTProfilerSource.spawnError(error))
            return
        }
        try? out.fileHandleForWriting.close()   // the parent's copy, or EOF never arrives
        runID &+= 1
        let id = runID
        inFlight = true; timedOut = false
        lock.lock(); process = p; lock.unlock()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.runID == id, self.inFlight else { return }
            self.timedOut = true
            if p.isRunning { p.terminate() }
        }
        queue.asyncAfter(deadline: .now() + Self.watchdogSeconds, execute: watchdog)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = out.fileHandleForReading.readDataToEndOfFile()   // drains while the child runs: the pipe never fills
            exited.wait()
            try? keepOpen.fileHandleForWriting.close()
            let rc = p.terminationStatus
            self?.queue.async {
                watchdog.cancel()
                self?.finish(id, data, rc)
            }
        }
    }

    private func finish(_ id: UInt64, _ data: Data, _ rc: Int32) {
        guard id == runID else { return }       // abandoned (setActive(false) / stop)
        inFlight = false
        lock.lock(); process = nil; lock.unlock()
        guard active else { return }
        if timedOut { fail(.timeout); return }
        if rc != 0 { fail(.subprocess(rc)); return }
        guard let rows = ProcNetParser.lastBlock(String(decoding: data, as: UTF8.self)) else { fail(.parse("blocks")); return }
        let list = agg.traffic(rows, seconds: Double(Self.windowSeconds))
        let now = Date()
        if let f = failing {
            failing = nil
            log.event("RECOVER", "src=\(SourceID.netProc.rawValue) failed_s=\(String(format: "%.1f", now.timeIntervalSince(f.since))) n=\(f.n)", at: now)
        }
        if log.level == .sample { log.line("NETP", Self.body(list, rows: rows.count), at: now) }
        deliver(.value(list))
        run()
    }

    /// `NETP procs=41 active=3 top="Safari":65000/1900,"Claude":1550/1225` (bytes/s down/up, rounded; top 5).
    static func body(_ list: [ProcTraffic], rows: Int) -> String {
        func n(_ v: Double) -> String { String(Int64(v.rounded(.toNearestOrAwayFromZero))) }
        let top = list.prefix(5).map { "\(EventLog.q($0.name)):\(n($0.rx))/\(n($0.tx))" }.joined(separator: ",")
        return "procs=\(rows) active=\(list.count) top=\(top.isEmpty ? "-" : top)"
    }

    private func fail(_ e: SourceError) {
        let token = e.logToken, now = Date()
        if var f = failing, f.token == token {
            f.n += 1; failing = f
        } else {
            failing = (token, failing?.since ?? now, (failing?.n ?? 0) + 1)
            log.event("ERR", "src=\(SourceID.netProc.rawValue) err=\(token)", at: now)
        }
        deliver(.failed(err: token))
        guard !retryPending else { return }
        retryPending = true
        queue.asyncAfter(deadline: .now() + .seconds(Self.windowSeconds)) { [weak self] in
            self?.retryPending = false
            self?.run()
        }
    }

    private func deliver(_ r: Reading<[ProcTraffic]>) {
        let cb = onUpdate
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let ok = self.delivering; self.lock.unlock()
            if ok { cb(r) }
        }
    }
}

// MARK: - Self test (`--selftest`; pure: literal nettop output, synthetic paths — no child process)

enum ProcNetSelfTest {
    static func run() -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        typealias Row = ProcNetParser.Row
        // two blocks: only the second (the delta) counts; a "." and a "," inside the name; malformed rows are skipped
        let two = """
        ,bytes_in,bytes_out,
        mDNSResponder.492,93577372,21280468,
        com.apple.WebKi.51412,9098059030,232353625,
        ,bytes_in,bytes_out,
        mDNSResponder.492,2439,1426,
        com.apple.WebKi.51412,130000,3800,
        Slack Helper.84108,0,0,
        Foo, Inc.77,10,20,
        nopid,1,2,
        bad.12,x,2,

        """
        let rows = ProcNetParser.lastBlock(two)
        out.append(SelfTestCase("netproc.parse.last_block", rows == [Row(token: "mDNSResponder", pid: 492, bytesIn: 2439, bytesOut: 1426),
                                                                     Row(token: "com.apple.WebKi", pid: 51412, bytesIn: 130_000, bytesOut: 3800),
                                                                     Row(token: "Slack Helper", pid: 84108, bytesIn: 0, bytesOut: 0),
                                                                     Row(token: "Foo, Inc", pid: 77, bytesIn: 10, bytesOut: 20)],
                                "\(rows?.count ?? -1) rows"))
        // one block only (the child was cut short) / no header / a header without the columns → nil; columns by name
        let one = ",bytes_in,bytes_out,\nmDNSResponder.492,2439,1426,\n"
        let swapped = ",bytes_out,bytes_in,\na.1,5,6,\n,bytes_out,bytes_in,\na.1,7,8,\n"
        out.append(SelfTestCase("netproc.parse.guards", ProcNetParser.lastBlock(one) == nil && ProcNetParser.lastBlock("") == nil
                                && ProcNetParser.lastBlock(",rx,tx,\n,rx,tx,\n") == nil && ProcNetParser.lastBlock(one, minBlocks: 1)?.count == 1
                                && ProcNetParser.lastBlock(swapped) == [Row(token: "a", pid: 1, bytesIn: 8, bytesOut: 7)]))
        // names: outermost .app; XPC service → responsible app; daemon → executable; com.apple. stripped; exited → token
        let slack = "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper"
        let webkit = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking"
        let safari = "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari"
        var asked = 0
        func name(_ p: String?, _ t: String = "tok", _ r: String? = nil) -> String { ProcNames.display(path: p, token: t) { asked += 1; return r } }
        let n1 = name(slack), n2 = name("/usr/sbin/mDNSResponder"), askedBeforeXPC = asked
        let n3 = name(webkit, "com.apple.WebKi", safari), n4 = name(webkit, "com.apple.WebKi", nil), n5 = name(nil, "curl"), n6 = name(webkit, "x", "/usr/libexec/foo")
        out.append(SelfTestCase("netproc.names", n1 == "Slack" && n2 == "mDNSResponder" && askedBeforeXPC == 0 && n3 == "Safari"
                                && n4 == "WebKit.Networking" && n5 == "curl" && n6 == "WebKit.Networking" && ProcNames.appName("/a/.app/x") == nil,
                                [n1, n2, n3, n4, n5, n6].joined(separator: "|")))
        // aggregation: helpers of one app are one row, idle rows dropped, busiest first (ties by name), bytes / window;
        // a name is resolved once per (pid, token) and only for rows with traffic
        var calls: [pid_t] = []
        var agg = ProcNetAggregator { pid, _ in calls.append(pid); return [1: "Safari", 2: "Safari", 3: "Claude", 4: "Zed", 5: "Idle"][pid] ?? "?" }
        let a = agg.traffic([Row(token: "a", pid: 1, bytesIn: 1000, bytesOut: 200), Row(token: "a", pid: 2, bytesIn: 3000, bytesOut: 0),
                             Row(token: "c", pid: 3, bytesIn: 100, bytesOut: 100), Row(token: "z", pid: 4, bytesIn: 0, bytesOut: 200),
                             Row(token: "i", pid: 5, bytesIn: 0, bytesOut: 0)], seconds: 2)
        let b = agg.traffic([Row(token: "a", pid: 1, bytesIn: 2, bytesOut: 0), Row(token: "other", pid: 3, bytesIn: 4, bytesOut: 0)], seconds: 2)
        out.append(SelfTestCase("netproc.aggregate", a == [ProcTraffic(name: "Safari", rx: 2000, tx: 100), ProcTraffic(name: "Claude", rx: 50, tx: 50),
                                                           ProcTraffic(name: "Zed", rx: 0, tx: 100)]
                                && b == [ProcTraffic(name: "Claude", rx: 2, tx: 0), ProcTraffic(name: "Safari", rx: 1, tx: 0)] && calls == [1, 2, 3, 4, 3],
                                "calls=\(calls)"))
        // the child's contract (header of this file)
        let args = ProcNetMonitor.arguments
        out.append(SelfTestCase("netproc.child_args", args.contains("-n") && args.contains("-d") && args.contains("-P")
                                && args.firstIndex(of: "-L").map { args[$0 + 1] } == "2"
                                && ProcNetMonitor.body(a, rows: 5) == "procs=5 active=3 top=\"Safari\":2000/100,\"Claude\":50/50,\"Zed\":0/100"
                                && ProcNetMonitor.body([], rows: 0) == "procs=0 active=0 top=-"))
        return out
    }
}
