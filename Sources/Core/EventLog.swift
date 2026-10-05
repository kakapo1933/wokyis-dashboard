// EventLog.swift — the single log writer (spec §12 + lead decision D4).
//
// * One serial queue (logQ) owns the file descriptor; every line is ONE write(2) (no user-space buffering,
//   a crash loses no completed line).
// * File: <dir>/panel-YYYYMMDD-HHMMSS.log, rotated at 64 MB to …-001.log, …-002.log. Retention: panel-*.log and
//   stdout-*.log (scripts/start.sh) last modified more than `retentionDays` ago (default 30; 0 = keep all) are deleted
//   at start and at most once per hour (`LOG event=pruned`); the files of this run and anything else are never touched.
//   Size cap: after that, while this app's logs (same two name patterns) total more than `maxBytes` (default 200 MB;
//   0 = no cap) the oldest are deleted — earlier rotations of THIS run included, only the file being written is kept
//   (`LOG event=pruned … over_mb=`). The age rule alone is no bound: a busier log level or a run that lasts for months
//   (its own rotations are never "earlier runs") grows without limit.
//   <dir>/current.log is a relative symlink to the file being written (replaced atomically with rename(2)).
// * Levels (D4):  sample  = every line as given.
//                 summary = MEM, CPU and NET each decimated to one line per `summarySeconds` (by the line's own
//                           timestamp), DSP dropped, AUD at most one per 60 s, every other kind kept.
// * `accepts(kind, at:)` (v2, spec §9.1): would a line of this kind be written now? Callers ask BEFORE composing an
//   expensive line (PanelView's DSP, the SystemSampler's CPU / NET). Lock-protected read of the decimation state.
// * stdout: `event()` lines (except MEM/DSP/AUD/BAT/CPU/NET) and `summary()` (SUM, at most one per `summarySeconds`).
//   stdout is written from its own queue (outQ) AFTER the file write, with a bounded backlog: a stdout that stops
//   draining (paused terminal, pager) never blocks logQ, the file or any q.sync caller; lines beyond the backlog are
//   dropped from stdout only (file line `WARN stdout_blocked dropped_total=N`, at most once per 60 s).
// * Throttles (MEM/AUD decimation, SUM) pass and restart when the wall clock stepped backwards.
// * `logs/` larger than 1 GB (after pruning) → `WARN log_dir_mb=…` at start and at most once per hour.
// Owner: core.
import Foundation

final class EventLog: @unchecked Sendable {
    let dir: URL
    let level: LogLevel
    let summarySeconds: Double
    let rotateBytes: Int
    let echoStdout: Bool
    let retentionDays: Double
    let maxBytes: Int64
    static let dirWarnBytes: Int64 = 1 << 30
    static let fileOnlyKinds: Set<String> = ["MEM", "DSP", "AUD", "BAT", "CPU", "NET"]
    /// Kinds decimated to one line per `summarySeconds` at summary level.
    static let decimatedKinds: Set<String> = ["MEM", "CPU", "NET"]
    static let stdoutBacklogMax = 512
    let stdoutFD: Int32

    /// Set once at start-up (before other threads log): returns true while any injection is active →
    /// every line without an explicit `sim=` token gets ` sim=1` appended (spec §11).
    var simActive: @Sendable () -> Bool = { false }

    private let q = DispatchQueue(label: "wokyis.log", qos: .utility)
    private let outQ = DispatchQueue(label: "wokyis.log.stdout", qos: .utility)
    private let outLock = NSLock()
    private var outPending = 0        // outLock
    private var stdoutDropped = 0     // logQ
    private var lastDropWarn: Date?   // logQ
    // --- logQ-only state ---
    private var fd: Int32 = -1
    private let base: String          // panel-YYYYMMDD-HHMMSS
    private var rotation = 0
    private var fileBytes = 0
    private var totalBytes: Int64 = 0
    private let lastLock = NSLock()
    private var lastKept: [String: Date] = [:]   // lastLock: last written line per decimated kind (MEM / CPU / NET / AUD)
    private var lastSum: Date?
    private var lastDirCheck: Date?
    private var writeErrorReported = false
    private let linkCurrent: Bool
    private var counts: [String: Int] = [:]
    private var dropped: [String: Int] = [:]

    /// `linkCurrent` false: never touch current.log (a launch refused because another panel runs keeps that panel's link).
    init(dir: URL, level: LogLevel = .summary, summarySeconds: Double = 10, rotateBytes: Int = 64 << 20,
         echoStdout: Bool = true, stdoutFD: Int32 = 1, now: Date = Date(), linkCurrent: Bool = true, retentionDays: Double = 30,
         maxBytes: Int64 = 200 << 20) throws {
        self.retentionDays = retentionDays; self.maxBytes = maxBytes
        self.dir = dir; self.level = level; self.summarySeconds = summarySeconds; self.stdoutFD = stdoutFD
        self.linkCurrent = linkCurrent
        self.rotateBytes = max(1024, rotateBytes); self.echoStdout = echoStdout
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        base = "panel-" + EventLog.compactStamp(now)
        try q.sync { try openFile() }
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    // MARK: public API (any thread)

    /// File only (subject to the level filter).
    func line(_ kind: String, _ body: String, at: Date = Date()) {
        let text = compose(kind, body, at)
        q.async { self.write(kind: kind, text: text, at: at, stdout: false) }
    }

    /// File + stdout (MEM/DSP/AUD/BAT are never echoed to stdout).
    func event(_ kind: String, _ body: String, at: Date = Date()) {
        let text = compose(kind, body, at)
        q.async { self.write(kind: kind, text: text, at: at, stdout: !EventLog.fileOnlyKinds.contains(kind)) }
    }

    /// stdout only: "HH:MM:SS SUM <s>", at most one per `summarySeconds` (callers may call at 1 Hz).
    func summary(_ s: String, at: Date = Date()) {
        let text = EventLog.hms(at) + " SUM " + s + "\n"
        q.async {
            if EventLog.throttled(at, self.lastSum, self.summarySeconds) { return }
            self.lastSum = at
            if self.echoStdout { self.echo(text, at: at) }
        }
    }

    /// Drain the queue and fsync the file (call before exit). Waits at most `timeout` s (never hangs the caller);
    /// returns false when the queue did not drain in time. stdout lines still queued on outQ are not waited for.
    @discardableResult
    func flushSync(timeout: Double = 2) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        q.async { if self.fd >= 0 { _ = fsync(self.fd) }; sem.signal() }
        return sem.wait(timeout: .now() + timeout) == .success
    }

    /// stdout lines queued but not yet written (tests).
    var stdoutPending: Int { outLock.lock(); defer { outLock.unlock() }; return outPending }

    /// Path of the file currently being written.
    var currentFile: URL { q.sync { dir.appendingPathComponent(fileName(rotation)) } }
    /// (lines written per kind, lines dropped by the level filter per kind, total bytes written by this process).
    func stats() -> (written: [String: Int], dropped: [String: Int], bytes: Int64) { q.sync { (counts, dropped, totalBytes) } }

    // MARK: formatting helpers (thread-safe, no DateFormatter)

    /// Local ISO 8601 with milliseconds and colon offset: 2026-10-01T05:07:13.250+08:00
    static func timestamp(_ d: Date) -> String {
        let (t, ms) = split(d)
        var tt = t; var tmv = tm(); localtime_r(&tt, &tmv)
        let off = tmv.tm_gmtoff, sign = off < 0 ? "-" : "+", a = abs(off)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03d", Int(tmv.tm_year) + 1900, Int(tmv.tm_mon) + 1, Int(tmv.tm_mday),
                      Int(tmv.tm_hour), Int(tmv.tm_min), Int(tmv.tm_sec), ms)
            + sign + String(format: "%02d:%02d", a / 3600, (a % 3600) / 60)
    }
    /// HH:MM:SS local.
    static func hms(_ d: Date) -> String {
        var tt = split(d).0; var tmv = tm(); localtime_r(&tt, &tmv)
        return String(format: "%02d:%02d:%02d", Int(tmv.tm_hour), Int(tmv.tm_min), Int(tmv.tm_sec))
    }
    /// YYYYMMDD-HHMMSS local (file names).
    static func compactStamp(_ d: Date) -> String {
        var tt = split(d).0; var tmv = tm(); localtime_r(&tt, &tmv)
        return String(format: "%04d%02d%02d-%02d%02d%02d", Int(tmv.tm_year) + 1900, Int(tmv.tm_mon) + 1, Int(tmv.tm_mday),
                      Int(tmv.tm_hour), Int(tmv.tm_min), Int(tmv.tm_sec))
    }
    private static func split(_ d: Date) -> (time_t, Int) {
        let s = d.timeIntervalSince1970, f = floor(s)
        return (time_t(f), min(999, max(0, Int((s - f) * 1000))))
    }
    /// Quote a free-text value for a log token: "…" with inner quotes replaced.
    static func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ") + "\"" }

    // MARK: logQ internals

    private func compose(_ kind: String, _ body: String, _ at: Date) -> String {
        var b = body
        if simActive() && !(b.hasPrefix("sim=") || b.contains(" sim=")) { b += b.isEmpty ? "sim=1" : " sim=1" }
        return EventLog.timestamp(at) + " " + kind + (b.isEmpty ? "" : " " + b) + "\n"
    }

    /// true = suppress: less than `every` s since `last`. A negative interval (wall clock stepped back) passes, so the
    /// caller restarts the throttle on the new timeline instead of going silent until the clock catches up.
    static func throttled(_ at: Date, _ last: Date?, _ every: Double) -> Bool {
        guard let l = last else { return false }
        let d = at.timeIntervalSince(l)
        return d >= 0 && d < every - 0.05
    }

    /// Decimation period of a kind at summary level (nil = always kept; DSP is handled separately: always dropped).
    private func period(_ kind: String) -> Double? {
        if EventLog.decimatedKinds.contains(kind) { return summarySeconds }
        return kind == "AUD" ? 60 : nil
    }

    /// true = a `line(kind, …, at:)` issued now would be written (level filter + decimation). Any thread; never blocks
    /// on logQ. The answer can be stale by one line when two threads race on the same kind (harmless: the line is then
    /// dropped by the level filter on logQ).
    func accepts(_ kind: String, at: Date = Date()) -> Bool {
        guard level == .summary else { return true }
        if kind == "DSP" { return false }
        guard let p = period(kind) else { return true }
        lastLock.lock(); let l = lastKept[kind]; lastLock.unlock()
        return !EventLog.throttled(at, l, p)
    }

    private func passesLevel(_ kind: String, _ at: Date) -> Bool {
        guard level == .summary else { return true }
        if kind == "DSP" { return false }
        guard let p = period(kind) else { return true }
        lastLock.lock(); defer { lastLock.unlock() }
        if EventLog.throttled(at, lastKept[kind], p) { return false }
        lastKept[kind] = at; return true
    }

    private func write(kind: String, text: String, at: Date, stdout: Bool) {
        defer { if stdout && echoStdout { echo(text, at: at) } }   // file first, then stdout (never blocks logQ)
        guard passesLevel(kind, at) else { dropped[kind, default: 0] += 1; return }
        writeFile(kind, text)
        if lastDirCheck == nil || abs(at.timeIntervalSince(lastDirCheck!)) >= 3600 { lastDirCheck = at; checkDirSize(at) }
    }

    private func writeFile(_ kind: String, _ text: String) {
        let n = text.utf8.count
        if fileBytes > 0 && fileBytes + n > rotateBytes { rotate() }
        if fd >= 0 {
            if EventLog.writeAll(fd, text) { fileBytes += n; totalBytes += Int64(n); counts[kind, default: 0] += 1 }
            else if !writeErrorReported {
                writeErrorReported = true
                EventLog.writeAll(2, "EventLog: write failed errno=\(errno) on \(fileName(rotation))\n")
            }
        }
    }

    /// Queue one stdout line on outQ (logQ only). Backlog full → drop it (stdout only) and note it in the file.
    private func echo(_ text: String, at: Date) {
        outLock.lock()
        let ok = outPending < EventLog.stdoutBacklogMax
        if ok { outPending += 1 }
        outLock.unlock()
        guard ok else {
            stdoutDropped += 1
            if lastDropWarn == nil || abs(at.timeIntervalSince(lastDropWarn!)) >= 60 {
                lastDropWarn = at
                writeFile("WARN", EventLog.timestamp(at) + " WARN stdout_blocked dropped_total=\(stdoutDropped) backlog=\(EventLog.stdoutBacklogMax)\n")
            }
            return
        }
        let fd = stdoutFD
        outQ.async {
            EventLog.writeAll(fd, text)
            self.outLock.lock(); self.outPending -= 1; self.outLock.unlock()
        }
    }

    private func fileName(_ r: Int) -> String { r == 0 ? base + ".log" : base + String(format: "-%03d.log", r) }

    private func openFile() throws {
        let path = dir.appendingPathComponent(fileName(rotation)).path
        let f = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard f >= 0 else { throw SourceError.errno(errno, "open \(path)") }
        fd = f
        var st = stat(); fileBytes = fstat(f, &st) == 0 ? Int(st.st_size) : 0
        if linkCurrent { updateSymlink() }
    }

    private func rotate() {
        if fd >= 0 { _ = fsync(fd); Darwin.close(fd); fd = -1 }
        rotation += 1
        do { try openFile() } catch { EventLog.writeAll(2, "EventLog: rotation failed: \(error)\n") }
    }

    /// current.log → relative symlink. Never replaces a non-symlink file of that name.
    private func updateSymlink() {
        let link = dir.appendingPathComponent("current.log").path
        var st = stat()
        if lstat(link, &st) == 0 && (st.st_mode & S_IFMT) != S_IFLNK {
            EventLog.writeAll(2, "EventLog: \(link) exists and is not a symlink; leaving it untouched\n"); return
        }
        let tmp = dir.appendingPathComponent(".current.log.\(getpid())").path
        _ = unlink(tmp)   // our own temp name only
        if symlink(fileName(rotation), tmp) == 0 { if rename(tmp, link) != 0 { _ = unlink(tmp) } }
    }

    /// Log files of earlier runs older than `days` (by modification time): panel-YYYYMMDD-HHMMSS[-NNN].log and
    /// stdout-YYYYMMDD-HHMMSS.log only, never a name in `keep` (this run's files). days <= 0 → none.
    static func expired(_ files: [(name: String, modified: Date)], now: Date, days: Double, keep: Set<String>) -> [String] {
        guard days > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-days * 86_400)
        return files.filter { f in !keep.contains(f.name) && f.modified < cutoff && isLogName(f.name) }.map(\.name).sorted()
    }

    /// The only names retention ever deletes: panel-YYYYMMDD-HHMMSS[-NNN].log and stdout-YYYYMMDD-HHMMSS.log.
    static func isLogName(_ name: String) -> Bool {
        name.range(of: #"^(panel-\d{8}-\d{6}(-\d{3})?|stdout-\d{8}-\d{6})\.log$"#, options: .regularExpression) != nil
    }

    /// Size cap: the oldest log files (by modification time, then name) to delete so that this app's logs total at most
    /// `maxBytes`. Files in `keep` (the one being written) count towards the total but are never returned, so the total
    /// can stay above the cap only by what `keep` holds. maxBytes <= 0 → none.
    static func overCap(_ files: [(name: String, modified: Date, size: Int)], maxBytes: Int64, keep: Set<String>) -> [String] {
        guard maxBytes > 0 else { return [] }
        let logs = files.filter { isLogName($0.name) }
        var total = logs.reduce(Int64(0)) { $0 + Int64($1.size) }
        var out: [String] = []
        for f in logs.sorted(by: { ($0.modified, $0.name) < ($1.modified, $1.name) }) where !keep.contains(f.name) {
            if total <= maxBytes { break }
            out.append(f.name); total -= Int64(f.size)
        }
        return out
    }

    private func prune(_ at: Date) {
        guard retentionDays > 0 || maxBytes > 0,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey])
        else { return }
        var files: [(name: String, modified: Date, size: Int)] = []
        for u in items {
            guard let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]),
                  v.isRegularFile == true, let m = v.contentModificationDate else { continue }
            files.append((u.lastPathComponent, m, v.fileSize ?? 0))
        }
        /// unlink `names`; returns (files removed, their bytes) and drops them from `files`
        func remove(_ names: [String]) -> (Int, Int) {
            var removed = 0, bytes = 0
            for name in names where unlink(dir.appendingPathComponent(name).path) == 0 {
                removed += 1; bytes += files.first { $0.name == name }?.size ?? 0
                files.removeAll { $0.name == name }
            }
            return (removed, bytes)
        }
        let (n1, b1) = remove(EventLog.expired(files.map { ($0.name, $0.modified) }, now: at, days: retentionDays, keep: Set((0...rotation).map(fileName))))
        if n1 > 0 { writeFile("LOG", EventLog.timestamp(at) + " LOG event=pruned files=\(n1) mb=\(b1 >> 20) older_than_days=\(Int(retentionDays))\n") }
        let (n2, b2) = remove(EventLog.overCap(files, maxBytes: maxBytes, keep: [fileName(rotation)]))
        if n2 > 0 { writeFile("LOG", EventLog.timestamp(at) + " LOG event=pruned files=\(n2) mb=\(b2 >> 20) over_mb=\(maxBytes >> 20)\n") }
    }

    private func checkDirSize(_ at: Date) {
        prune(at)
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return }
        var total: Int64 = 0
        for u in items {
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            total += Int64(v.fileSize ?? 0)
        }
        guard total > EventLog.dirWarnBytes else { return }
        let text = EventLog.timestamp(at) + " WARN log_dir_mb=\(total >> 20)\n"
        writeFile("WARN", text)
        if echoStdout { echo(text, at: at) }
    }

    /// write(2) until done; retries EINTR/partial writes. Returns false on error.
    @discardableResult
    static func writeAll(_ fd: Int32, _ s: String) -> Bool {
        var ok = true
        var bytes = Array(s.utf8)
        bytes.withUnsafeMutableBytes { raw in
            guard var p = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let w = Darwin.write(fd, p, left)
                if w < 0 { if errno == EINTR { continue }; ok = false; return }
                left -= w; p += w
            }
        }
        return ok
    }
}

// MARK: - self test (writes only inside `dir`, a temp directory owned by the caller)

enum EventLogSelfTest {
    /// panel-…-HHMMSS.log → 0, panel-…-HHMMSS-007.log → 7 (lexical order would put "-001" before ".log").
    static func rotationIndex(_ name: String) -> Int {
        let stem = name.replacingOccurrences(of: ".log", with: "")
        let parts = stem.split(separator: "-")
        if parts.count == 4, let n = Int(parts[3]) { return n }
        return 0
    }
    static func run(dir: URL) -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        let t0 = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        // 1. timestamp format
        let ts = EventLog.timestamp(t0.addingTimeInterval(0.25))
        let tsOK = ts.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.250[+-]\d{2}:\d{2}$"#, options: .regularExpression) != nil
        out.append(SelfTestCase("eventlog.timestamp", tsOK, ts))

        // 2. sample level + rotation (4 KB) + symlink + no deletion + ordering
        let d1 = dir.appendingPathComponent("sample")
        do {
            let log = try EventLog(dir: d1, level: .sample, summarySeconds: 10, rotateBytes: 4096, echoStdout: false, now: t0)
            let first = log.currentFile
            for i in 0..<200 { log.line("MEM", String(format: "seq=%05d pad=%@", i, String(repeating: "x", count: 60)), at: t0.addingTimeInterval(Double(i) * 0.25)) }
            for i in 0..<20 { log.line("DSP", "seq=\(i)") }
            log.flushSync()
            let last = log.currentFile
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: d1.path)) ?? []).filter { $0.hasSuffix(".log") && $0 != "current.log" }
                .sorted { rotationIndex($0) < rotationIndex($1) }
            var lines: [String] = []
            var maxSize = 0
            for f in files {
                let data = (try? Data(contentsOf: d1.appendingPathComponent(f))) ?? Data()
                maxSize = max(maxSize, data.count)
                let s = String(decoding: data, as: UTF8.self)
                if !s.isEmpty && !s.hasSuffix("\n") { lines.append("<<partial>>") }
                lines += s.split(separator: "\n").map(String.init)
            }
            let mem = lines.filter { $0.contains(" MEM ") }
            let seqs = mem.compactMap { l -> Int? in
                guard let r = l.range(of: "seq=") else { return nil }
                return Int(l[r.upperBound...].prefix(5))
            }
            let link = (try? FileManager.default.destinationOfSymbolicLink(atPath: d1.appendingPathComponent("current.log").path)) ?? ""
            out.append(SelfTestCase("eventlog.sample.all_lines", mem.count == 200 && lines.filter { $0.contains(" DSP ") }.count == 20
                                    && !lines.contains("<<partial>>"), "mem=\(mem.count) files=\(files.count)"))
            out.append(SelfTestCase("eventlog.sample.order", seqs == Array(0..<200)))
            out.append(SelfTestCase("eventlog.rotation", files.count >= 5 && maxSize <= 4096 && files.contains(first.lastPathComponent)
                                    && files.contains(where: { $0.hasSuffix("-001.log") }), "files=\(files.count) max=\(maxSize)"))
            out.append(SelfTestCase("eventlog.symlink", link == last.lastPathComponent && link != first.lastPathComponent, link))
            let st = log.stats()
            out.append(SelfTestCase("eventlog.stats", st.written["MEM"] == 200 && st.written["DSP"] == 20 && st.dropped.isEmpty))
        } catch { out.append(SelfTestCase("eventlog.sample", false, "\(error)")) }

        // 3. summary level decimation (D4)
        let d2 = dir.appendingPathComponent("summary")
        do {
            let log = try EventLog(dir: d2, level: .summary, summarySeconds: 10, echoStdout: false, now: t0)
            for i in 0..<120 { log.line("MEM", "seq=\(i)", at: t0.addingTimeInterval(Double(i) * 0.25)) }      // 30 s @ 4 Hz
            for i in 0..<50 { log.line("DSP", "seq=\(i)", at: t0.addingTimeInterval(Double(i) * 0.25)) }
            for i in 0..<27 { log.line("AUD", "k=\(i)", at: t0.addingTimeInterval(Double(i) * 5)) }              // 130 s @ 0.2 Hz
            for i in 0..<5 { log.line("BAT", "k=\(i)", at: t0.addingTimeInterval(Double(i))) }
            log.event("ERR", "src=mem.swap err=injected sim=1", at: t0)
            log.event("CTL", "expired", at: t0)
            log.flushSync()
            let s = String(decoding: (try? Data(contentsOf: log.currentFile)) ?? Data(), as: UTF8.self)
            let ls = s.split(separator: "\n").map(String.init)
            let mem = ls.filter { $0.contains(" MEM ") }.map { $0.components(separatedBy: " MEM ")[1] }
            let aud = ls.filter { $0.contains(" AUD ") }.map { $0.components(separatedBy: " AUD ")[1] }
            out.append(SelfTestCase("eventlog.summary.mem", mem == ["seq=0", "seq=40", "seq=80"], mem.joined(separator: ",")))
            out.append(SelfTestCase("eventlog.summary.dsp", !ls.contains { $0.contains(" DSP ") }))
            out.append(SelfTestCase("eventlog.summary.aud", aud == ["k=0", "k=12", "k=24"], aud.joined(separator: ",")))
            out.append(SelfTestCase("eventlog.summary.events", ls.filter { $0.contains(" BAT ") }.count == 5
                                    && ls.contains { $0.contains(" ERR src=mem.swap") } && ls.contains { $0.contains(" CTL expired") }))
        } catch { out.append(SelfTestCase("eventlog.summary", false, "\(error)")) }

        // 3b. wall clock stepped back: throttles pass and restart instead of going silent
        let d2b = dir.appendingPathComponent("clockstep")
        do {
            let log = try EventLog(dir: d2b, level: .summary, summarySeconds: 10, echoStdout: false, now: t0)
            log.line("MEM", "seq=0", at: t0)
            log.line("MEM", "seq=1", at: t0.addingTimeInterval(-60))    // clock stepped back 60 s
            log.line("MEM", "seq=2", at: t0.addingTimeInterval(-55))    // throttled on the new timeline
            log.line("MEM", "seq=3", at: t0.addingTimeInterval(-50))
            log.flushSync()
            let s = String(decoding: (try? Data(contentsOf: log.currentFile)) ?? Data(), as: UTF8.self)
            let mem = s.split(separator: "\n").filter { $0.contains(" MEM ") }.map { String($0.split(separator: " ").last ?? "") }
            out.append(SelfTestCase("eventlog.clock_step_back", mem == ["seq=0", "seq=1", "seq=3"], mem.joined(separator: ",")))
        } catch { out.append(SelfTestCase("eventlog.clock_step_back", false, "\(error)")) }

        // 3c. stdout that stops draining never blocks the file or flushSync (bounded backlog, drops counted)
        var pfd: [Int32] = [-1, -1]
        if pipe(&pfd) == 0 {
            let (r, w) = (pfd[0], pfd[1])
            _ = fcntl(w, F_SETFL, fcntl(w, F_GETFL) | O_NONBLOCK)
            let chunk = [UInt8](repeating: 0x2E, count: 4096)
            while chunk.withUnsafeBytes({ Darwin.write(w, $0.baseAddress, 4096) }) > 0 {}      // fill the pipe
            _ = fcntl(w, F_SETFL, fcntl(w, F_GETFL) & ~O_NONBLOCK)                             // blocking again, like a tty
            var pendingLeft = 0
            do {
                let log = try EventLog(dir: dir.appendingPathComponent("stdout"), level: .sample, echoStdout: true, stdoutFD: w, now: t0)
                let n = EventLog.stdoutBacklogMax + 100
                let start = Date()
                for i in 0..<n { log.event("WIN", "k=\(i)", at: t0) }
                let flushed = log.flushSync(timeout: 3)
                let took = Date().timeIntervalSince(start)
                let s = String(decoding: (try? Data(contentsOf: log.currentFile)) ?? Data(), as: UTF8.self)
                let win = s.split(separator: "\n").filter { $0.contains(" WIN ") }.count
                let warn = s.contains(" WARN stdout_blocked dropped_total=")
                out.append(SelfTestCase("eventlog.stdout_blocked", flushed && took < 2 && win == n && warn,
                                        String(format: "flushed=%d took=%.2fs file_lines=%d/%d warn=%d", flushed ? 1 : 0, took, win, n, warn ? 1 : 0)))
                // drain the pipe so the stdout queue finishes, then close both ends
                _ = fcntl(r, F_SETFL, fcntl(r, F_GETFL) | O_NONBLOCK)
                var buf = [UInt8](repeating: 0, count: 65536)
                let end = Date().addingTimeInterval(5)
                while Date() < end {
                    _ = buf.withUnsafeMutableBytes { Darwin.read(r, $0.baseAddress, 65536) }
                    if log.stdoutPending == 0 { break }
                    usleep(2000)
                }
                pendingLeft = log.stdoutPending
                out.append(SelfTestCase("eventlog.stdout_drained", pendingLeft == 0, "pending=\(pendingLeft)"))
            } catch { out.append(SelfTestCase("eventlog.stdout_blocked", false, "\(error)")) }
            if pendingLeft == 0 { Darwin.close(w) }   // never close an fd a queued write may still use (fd reuse)
            Darwin.close(r)
        } else { out.append(SelfTestCase("eventlog.stdout_blocked", false, "pipe errno=\(errno)")) }

        // 3d. v2 CPU / NET (spec §9.1, eventlog.cpu_net): summary level decimates each kind on its own clock, sample keeps
        //     every line, neither is ever echoed to stdout; accepts() predicts the filter (DSP false at summary)
        let d2c = dir.appendingPathComponent("cpunet")
        var pfd2: [Int32] = [-1, -1]
        if pipe(&pfd2) == 0 {
            _ = fcntl(pfd2[0], F_SETFL, fcntl(pfd2[0], F_GETFL) | O_NONBLOCK)
            do {
                let sum = try EventLog(dir: d2c.appendingPathComponent("summary"), level: .summary, summarySeconds: 10, echoStdout: true, stdoutFD: pfd2[1], now: t0)
                var acc: [Bool] = []
                for i in 0..<30 {
                    let at = t0.addingTimeInterval(Double(i))
                    acc.append(sum.accepts("CPU", at: at))
                    sum.event("CPU", "seq=\(i)", at: at)
                    sum.flushSync()                                     // accepts() must see the previous line
                    sum.line("NET", "seq=\(i)", at: at.addingTimeInterval(0.5))
                }
                let dspAcc = sum.accepts("DSP"), winAcc = sum.accepts("WIN")
                sum.flushSync()
                let s = String(decoding: (try? Data(contentsOf: sum.currentFile)) ?? Data(), as: UTF8.self)
                let cpu = s.split(separator: "\n").filter { $0.contains(" CPU ") }.map { String($0.split(separator: " ").last ?? "") }
                let net = s.split(separator: "\n").filter { $0.contains(" NET ") }.map { String($0.split(separator: " ").last ?? "") }
                let sample = try EventLog(dir: d2c.appendingPathComponent("sample"), level: .sample, echoStdout: true, stdoutFD: pfd2[1], now: t0)
                for i in 0..<30 { sample.event("CPU", "seq=\(i)", at: t0.addingTimeInterval(Double(i))); sample.line("NET", "seq=\(i)", at: t0.addingTimeInterval(Double(i))) }
                let sampleAcc = sample.accepts("CPU") && sample.accepts("DSP")
                sample.flushSync()
                usleep(50_000)
                let s2 = String(decoding: (try? Data(contentsOf: sample.currentFile)) ?? Data(), as: UTF8.self)
                var buf = [UInt8](repeating: 0, count: 65536)
                let n = buf.withUnsafeMutableBytes { Darwin.read(pfd2[0], $0.baseAddress, 65536) }
                let echoed = n > 0 ? String(decoding: buf.prefix(n), as: UTF8.self) : ""
                let accExpect = (0..<30).map { $0 % 10 == 0 }
                out.append(SelfTestCase("eventlog.cpu_net", cpu == ["seq=0", "seq=10", "seq=20"] && net == ["seq=0", "seq=10", "seq=20"]
                                        && acc == accExpect && !dspAcc && winAcc && sampleAcc
                                        && s2.components(separatedBy: " CPU ").count - 1 == 30 && s2.components(separatedBy: " NET ").count - 1 == 30
                                        && !echoed.contains(" CPU ") && !echoed.contains(" NET "),
                                        "cpu=\(cpu) net=\(net) acc_ok=\(acc == accExpect) dsp=\(dspAcc) echoed=\(echoed.count)"))
            } catch { out.append(SelfTestCase("eventlog.cpu_net", false, "\(error)")) }
            Darwin.close(pfd2[0]); Darwin.close(pfd2[1])
        } else { out.append(SelfTestCase("eventlog.cpu_net", false, "pipe errno=\(errno)")) }

        // 4. sim=1 auto-append
        let d3 = dir.appendingPathComponent("sim")
        do {
            let log = try EventLog(dir: d3, level: .sample, echoStdout: false, now: t0)
            log.simActive = { true }
            log.line("BAT", "dev=x pct=1")
            log.line("BAT", "dev=y pct=2 sim=0")
            log.flushSync()
            let s = String(decoding: (try? Data(contentsOf: log.currentFile)) ?? Data(), as: UTF8.self)
            out.append(SelfTestCase("eventlog.sim_tag", s.contains("dev=x pct=1 sim=1\n") && s.contains("dev=y pct=2 sim=0\n") && !s.contains("sim=0 sim=1")))
        } catch { out.append(SelfTestCase("eventlog.sim", false, "\(error)")) }
        // retention: only this app's log names, older than the cutoff, never this run's files
        let day = 86_400.0
        let fs: [(name: String, modified: Date)] = [("panel-20260801-120000.log", t0.addingTimeInterval(-40 * day)),
            ("panel-20260801-120000-001.log", t0.addingTimeInterval(-31 * day)), ("stdout-20260801-120000.log", t0.addingTimeInterval(-35 * day)),
            ("panel-20260920-120000.log", t0.addingTimeInterval(-12 * day)), ("current.log", t0.addingTimeInterval(-90 * day)),
            ("notes.txt", t0.addingTimeInterval(-90 * day)), ("panel-old.log", t0.addingTimeInterval(-90 * day)),
            ("panel-20260701-000000.log", t0.addingTimeInterval(-60 * day))]
        let ex = EventLog.expired(fs, now: t0, days: 30, keep: ["panel-20260701-000000.log"])
        out.append(SelfTestCase("eventlog.retention", ex == ["panel-20260801-120000-001.log", "panel-20260801-120000.log", "stdout-20260801-120000.log"]
                                && EventLog.expired(fs, now: t0, days: 0, keep: []).isEmpty, "\(ex)"))
        // size cap: oldest log names first until the total fits; other files are neither counted nor deleted; the kept
        // file counts but stays; already under the cap / cap 0 → nothing
        let mb = 1 << 20
        let cs: [(name: String, modified: Date, size: Int)] = [
            ("panel-20260901-000000.log", t0.addingTimeInterval(-9 * day), 64 * mb), ("panel-20260901-000000-001.log", t0.addingTimeInterval(-6 * day), 64 * mb),
            ("stdout-20260901-000000.log", t0.addingTimeInterval(-8 * day), 1 * mb), ("panel-20260901-000000-002.log", t0.addingTimeInterval(-3 * day), 64 * mb),
            ("panel-20260901-000000-003.log", t0, 40 * mb), ("notes.txt", t0.addingTimeInterval(-90 * day), 900 * mb)]
        let live: Set<String> = ["panel-20260901-000000-003.log"]
        let c200 = EventLog.overCap(cs, maxBytes: Int64(200 * mb), keep: live), c50 = EventLog.overCap(cs, maxBytes: Int64(50 * mb), keep: live)
        out.append(SelfTestCase("eventlog.size_cap", c200 == ["panel-20260901-000000.log"]
                                && c50 == ["panel-20260901-000000.log", "stdout-20260901-000000.log", "panel-20260901-000000-001.log", "panel-20260901-000000-002.log"]
                                && EventLog.overCap(cs, maxBytes: Int64(233 * mb), keep: live).isEmpty && EventLog.overCap(cs, maxBytes: 0, keep: []).isEmpty,
                                "\(c200) | \(c50.count)"))
        // live: a real directory — the age rule (the 40-day file) and then the cap (7500 B of logs > 5000: the oldest
        // 3000 B file goes, 4500 fit) both run at start; this run's file and foreign files stay
        do {
            let d3 = dir.appendingPathComponent("cap")
            try FileManager.default.createDirectory(at: d3, withIntermediateDirectories: true)
            func put(_ n: String, _ bytes: Int, ageDays: Double) throws {
                let u = d3.appendingPathComponent(n)
                try Data(count: bytes).write(to: u)
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ageDays * day)], ofItemAtPath: u.path)
            }
            try put("panel-20260101-000000.log", 1000, ageDays: 40); try put("panel-20260901-000000.log", 3000, ageDays: 5)
            try put("panel-20260902-000000.log", 3000, ageDays: 4); try put("stdout-20260903-000000.log", 1500, ageDays: 3)
            try put("notes.txt", 50_000, ageDays: 90)
            let log = try EventLog(dir: d3, level: .sample, echoStdout: false, retentionDays: 30, maxBytes: 5000)
            log.line("X", "first line triggers the start-up check"); log.flushSync()
            let left = Set(try FileManager.default.contentsOfDirectory(atPath: d3.path))
            let s = String(decoding: (try? Data(contentsOf: log.currentFile)) ?? Data(), as: UTF8.self)
            out.append(SelfTestCase("eventlog.size_cap_live", left == ["notes.txt", "panel-20260902-000000.log", "stdout-20260903-000000.log", "current.log", log.currentFile.lastPathComponent]
                                    && s.contains(" LOG event=pruned files=1 mb=0 older_than_days=30\n") && s.contains(" LOG event=pruned files=1 mb=0 over_mb=0\n"),
                                    "\(left.sorted())"))
        } catch { out.append(SelfTestCase("eventlog.size_cap_live", false, "\(error)")) }
        return out
    }
}
