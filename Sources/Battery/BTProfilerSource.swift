// BTProfilerSource.swift — `system_profiler -json -timeout 10 SPBluetoothDataType` child process, async read,
// 12 s watchdog (TERM, +1 s KILL), hang/garbage injection (spec §6.3, §11). Owner: battery agent.
//
// - At most one child in flight; `poll` while one is running completes immediately with nothing (see `inFlight`).
// - stdout is drained by a `readabilityHandler` into a buffer on `queue` (the pipe can never fill up); the result is
//   produced once the child has terminated AND stdout reached EOF (or 0.5 s after termination, in case a grandchild
//   still holds the pipe).
// - watchdog: 12 s after spawn → terminate() (SIGTERM); 1 s later still alive → kill(SIGKILL). Result = .timeout.
// - injection: `fail bat.sp` → .injected before spawning; `hang bat.sp` → the child is `/bin/sleep 3600` and is killed
//   by the same watchdog; `garbage bat.sp` → the real child runs but "{not json" is fed to the real parser.
// - A spawn failure (`--sp-path /nonexistent/...`) is a real .errno failure.
// - Debug/evidence hook: env WOKYIS_SP_DUMP_DIR=<dir> → the raw stdout of every successful run is written to
//   <dir>/sp-last.json (and the first one also to <dir>/sp-first.json). Off unless the variable is set.
import Foundation

final class BTProfilerSource: @unchecked Sendable {
    let path: String
    let queue: DispatchQueue
    let injector: Injector
    static let arguments = ["-json", "-timeout", "10", "SPBluetoothDataType"]
    static let watchdogSeconds: Double = 12
    static let killGraceSeconds: Double = 1

    // guarded by `lock` (read from other threads: childPID, inFlight, cancel)
    private let lock = NSLock()
    private var process: Process?
    private var running = false
    // queue-only state of the current run
    private var buffer = Data()
    private var gotEOF = false
    private var terminated = false
    private var timedOut = false
    private var finished = true
    private var started = Date()
    private var completion: (@Sendable (Result<[BTDevice], SourceError>, Int) -> Void)?
    private var watchdog: DispatchSourceTimer?
    private var killTimer: DispatchSourceTimer?
    private var eofGrace: DispatchWorkItem?
    private var garbage = false
    private var readHandle: FileHandle?
    private var runID: UInt64 = 0
    private var dumpedFirst = false
    private let dumpDir: String? = ProcessInfo.processInfo.environment["WOKYIS_SP_DUMP_DIR"]

    private let onQueueKey = DispatchSpecificKey<UInt8>()

    init(path: String, queue: DispatchQueue, injector: Injector) {
        self.path = path; self.queue = queue; self.injector = injector
        queue.setSpecific(key: onQueueKey, value: 1)
    }

    /// true while a child is running (the monitor never starts a second one).
    var inFlight: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Runs one poll; `completion` is called once on `queue` with the result and the elapsed ms.
    /// If a child is already in flight the call is ignored (completion is NOT called) — callers check `inFlight`.
    func poll(completion: @escaping @Sendable (Result<[BTDevice], SourceError>, _ ms: Int) -> Void) {
        if DispatchQueue.getSpecific(key: onQueueKey) != nil { startRun(completion) } else { queue.async { self.startRun(completion) } }
    }

    private func startRun(_ done: @escaping @Sendable (Result<[BTDevice], SourceError>, Int) -> Void) {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()
        runID &+= 1
        started = Date()
        do { try injector.check(.batSP) } catch let e as SourceError { finishNow(done, .failure(e)); return }
        catch { finishNow(done, .failure(.parse("\(error)"))); return }

        let mode = injector.mode(.batSP)
        garbage = (mode == .garbage)
        let p = Process()
        if mode == .hang {
            p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["3600"]
        } else {
            p.executableURL = URL(fileURLWithPath: path); p.arguments = Self.arguments
        }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        buffer = Data(); gotEOF = false; terminated = false; timedOut = false; finished = false
        completion = done
        let id = runID
        let q = queue
        readHandle = out.fileHandleForReading
        out.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData          // empty = EOF
            if chunk.isEmpty { fh.readabilityHandler = nil }
            q.async {
                guard let self, self.runID == id, !self.finished else { return }
                if chunk.isEmpty {
                    self.gotEOF = true
                    self.tryFinish()
                } else {
                    self.buffer.append(chunk)
                }
            }
        }
        p.terminationHandler = { [weak self] _ in
            q.async {
                guard let self, self.runID == id, !self.finished else { return }
                self.terminated = true
                if self.gotEOF { self.tryFinish(); return }
                // a grandchild may still hold the write end: do not wait for EOF forever
                let w = DispatchWorkItem { [weak self] in
                    guard let self, self.runID == id, !self.finished else { return }
                    self.gotEOF = true; self.tryFinish()
                }
                self.eofGrace = w
                q.asyncAfter(deadline: .now() + 0.5, execute: w)
            }
        }
        do {
            try p.run()
        } catch {
            readHandle = nil
            out.fileHandleForReading.readabilityHandler = nil
            try? out.fileHandleForReading.close()
            try? out.fileHandleForWriting.close()
            finishNow(done, .failure(Self.spawnError(error)))
            return
        }
        // parent's copy of the write end must be closed or EOF never arrives (Process closes it, be explicit anyway)
        try? out.fileHandleForWriting.close()
        lock.lock(); process = p; lock.unlock()

        let wd = DispatchSource.makeTimerSource(queue: queue)
        wd.schedule(deadline: .now() + Self.watchdogSeconds)
        wd.setEventHandler { [weak self] in
            guard let self, self.runID == id, !self.finished else { return }
            self.timedOut = true
            if p.isRunning { p.terminate() }
            let k = DispatchSource.makeTimerSource(queue: q)
            k.schedule(deadline: .now() + Self.killGraceSeconds)
            k.setEventHandler { [weak self] in
                guard let self, self.runID == id, !self.finished else { return }
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
            k.resume(); self.killTimer = k
        }
        wd.resume(); watchdog = wd
    }

    /// queue only
    private func tryFinish() {
        guard !finished, terminated, gotEOF else { return }
        finished = true
        watchdog?.cancel(); watchdog = nil
        killTimer?.cancel(); killTimer = nil
        eofGrace?.cancel(); eofGrace = nil
        if let h = readHandle { h.readabilityHandler = nil; try? h.close(); readHandle = nil }
        lock.lock(); let p = process; lock.unlock()
        let result: Result<[BTDevice], SourceError>
        if timedOut {
            result = .failure(.timeout)
        } else if let p, p.terminationReason == .uncaughtSignal {
            result = .failure(.subprocess(128 + p.terminationStatus))
        } else if let p, p.terminationStatus != 0 {
            result = .failure(.subprocess(p.terminationStatus))
        } else {
            let data = garbage ? Data("{not json".utf8) : buffer
            do {
                let devs = try Self.parse(data)
                if !garbage { dump(data) }
                result = .success(devs)
            } catch let e as SourceError { result = .failure(e) } catch { result = .failure(.parse("\(error)")) }
        }
        let done = completion; completion = nil
        buffer = Data()
        lock.lock(); process = nil; running = false; lock.unlock()
        done?(result, Int(Date().timeIntervalSince(started) * 1000))
    }

    /// queue only: completes a run that never spawned a child.
    private func finishNow(_ done: @Sendable (Result<[BTDevice], SourceError>, Int) -> Void, _ r: Result<[BTDevice], SourceError>) {
        finished = true
        completion = nil
        lock.lock(); process = nil; running = false; lock.unlock()
        done(r, Int(Date().timeIntervalSince(started) * 1000))
    }

    private func dump(_ data: Data) {
        guard let dir = dumpDir, !dir.isEmpty else { return }
        let d = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? data.write(to: d.appendingPathComponent("sp-last.json"), options: .atomic)
        if !dumpedFirst { dumpedFirst = true; try? data.write(to: d.appendingPathComponent("sp-first.json"), options: .atomic) }
    }

    static func spawnError(_ error: Error) -> SourceError {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return .errno(Int32(ns.code), ns.localizedDescription) }
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError, u.domain == NSPOSIXErrorDomain {
            return .errno(Int32(u.code), u.localizedDescription)
        }
        if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileNoSuchFileError || ns.code == NSFileReadNoSuchFileError) {
            return .errno(ENOENT, ns.localizedDescription)
        }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError { return .errno(EACCES, ns.localizedDescription) }
        return .errno(-1, ns.localizedDescription)
    }

    /// Kill a running child (SIGTERM, then SIGKILL after 1 s) and wait (≤ 3 s) until it is gone; used at shutdown.
    /// Safe to call from any thread except `queue` itself.
    func cancel() {
        lock.lock(); let p = process; lock.unlock()
        guard let p, p.isRunning else { return }
        p.terminate()
        let t0 = Date()
        while p.isRunning && Date().timeIntervalSince(t0) < Self.killGraceSeconds { usleep(20_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        while p.isRunning && Date().timeIntervalSince(t0) < 3 { usleep(20_000) }
    }

    /// pid of the running child, if any (for stop checks / HEALTH).
    var childPID: pid_t? {
        lock.lock(); defer { lock.unlock() }
        guard let p = process, p.isRunning else { return nil }
        return p.processIdentifier
    }

    // MARK: parser (pure; used by the selftest with tools/fixtures/sp_sample.json)

    /// Parses `system_profiler -json SPBluetoothDataType`. Throws .parse on anything that is not the expected shape.
    /// A controller without `device_connected` / `device_not_connected` keys is valid (nothing paired / connected).
    static func parse(_ data: Data) throws -> [BTDevice] {
        guard !data.isEmpty else { throw SourceError.parse("empty output") }
        let obj: Any
        do { obj = try JSONSerialization.jsonObject(with: data) } catch { throw SourceError.parse("json: \(error.localizedDescription)") }
        guard let root = obj as? [String: Any] else { throw SourceError.parse("root is not an object") }
        guard let ctrls = root["SPBluetoothDataType"] as? [Any] else { throw SourceError.parse("no SPBluetoothDataType array") }
        var out: [BTDevice] = []
        for c in ctrls {
            guard let ctrl = c as? [String: Any] else { throw SourceError.parse("controller entry is not an object") }
            for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
                guard let raw = ctrl[key] else { continue }
                guard let list = raw as? [Any] else { throw SourceError.parse("\(key) is not an array") }
                for entry in list {
                    guard let e = entry as? [String: Any] else { throw SourceError.parse("\(key) entry is not an object") }
                    for name in e.keys.sorted() {
                        guard let props = e[name] as? [String: Any] else { throw SourceError.parse("\(key) device is not an object") }
                        var levels: [String: Int] = [:]
                        for (k, lk) in [("device_batteryLevelMain", "Main"), ("device_batteryLevelLeft", "Left"),
                                        ("device_batteryLevelRight", "Right"), ("device_batteryLevelCase", "Case")] {
                            if let v = props[k], let n = percent(v) { levels[lk] = n }
                        }
                        out.append(BTDevice(name: name, address: normalizeAddress(props["device_address"] as? String ?? ""),
                                            minorType: props["device_minorType"] as? String,
                                            productID: props["device_productID"] as? String,
                                            connected: connected, levels: levels))
                    }
                }
            }
        }
        return out
    }

    /// "100%" / "48 %" / 48 → 48 (0…100), else nil.
    static func percent(_ v: Any) -> Int? {
        if let n = v as? Int { return (0...100).contains(n) ? n : nil }
        guard let s = v as? String else { return nil }
        let digits = s.trimmingCharacters(in: .whitespaces).prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let n = Int(digits), (0...100).contains(n) else { return nil }
        return n
    }
}

/// "02-11-22-33-44-01" / "02:11:22:33:44:01" → "02:11:22:33:44:01". Anything else (UUIDs) is only lower-cased.
func normalizeAddress(_ s: String) -> String {
    let t = s.trimmingCharacters(in: .whitespaces).lowercased()
    let parts = t.split(whereSeparator: { $0 == "-" || $0 == ":" })
    if parts.count == 6 && parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) { return parts.joined(separator: ":") }
    return t
}

/// "0x2024" / "0x029a" / 8228 → "0x2024" (4 upper-case hex digits); nil when unparseable.
func normalizeProductID(_ v: Any?) -> String? {
    if let n = v as? Int { return String(format: "0x%04X", n) }
    guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
    let hex = s.hasPrefix("0x") ? String(s.dropFirst(2)) : s
    guard let n = Int(hex, radix: 16) else { return nil }
    return String(format: "0x%04X", n)
}
