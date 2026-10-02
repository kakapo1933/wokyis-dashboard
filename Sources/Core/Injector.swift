// Injector.swift — fault / simulation injection from <run-dir>/control.json (spec §11).
//
// * ctlQ watches the run directory (DISPATCH_SOURCE vnode on the directory fd) AND stats control.json every 1 s;
//   the file is (re)parsed only when (inode, size, mtime) changed.
// * The parsed state is an immutable `Snapshot` swapped under an os_unfair_lock; readers (memQ, batQ, spQ, main)
//   take the snapshot and never block on ctlQ.
// * Rules: `version` must be 1; `expires` is required (ISO 8601) whenever anything is injected; expires more than
//   900 s in the future is clamped to now+900 (`WARN ctl_expires_clamped`); past expiry → cleared + `CTL expired`.
//   Unparsable file / version≠1 / unknown or disallowed id / bad pressure → cleared + `CTL invalid reason=…`.
//   `{}` or a missing file → cleared. Allowed ids: every SourceID raw value plus "mem.mib:<name>" (fail only);
//   hang: bat.sp only; garbage: bat.sp, bat.iops, cpu.load, cpu.tasks, net.if (v2, spec §9.2).
// * v2: the on-screen badge is localized and collapsed by whole items (L10n.badge, from `badgeParts`); `badge` (zh, never
//   collapsed) stays for CTL / scripts/status.sh.
// Owner: core.
import Foundation
import os

enum InjectMode: Sendable { case none, hang, garbage }

final class Injector: @unchecked Sendable {
    struct Snapshot: Sendable, Equatable {
        var fail: Set<String> = []                  // SourceID raw values and "mem.mib:<name>"
        var hang: Set<SourceID> = []
        var garbage: Set<SourceID> = []
        var pressure: PressureOverride? = nil
        var expires: Date? = nil
        var isEmpty: Bool { fail.isEmpty && hang.isEmpty && garbage.isEmpty && pressure == nil }
        static let empty = Snapshot()
    }
    struct PressureOverride: Sendable, Equatable { let level: PressureLevel; let percent: Int }

    enum Outcome: Equatable, Sendable {
        case cleared(String)            // "missing" | "empty"
        case active(clamped: Bool)
        case invalid(String)
        case expired
    }

    static let maxLifetime: TimeInterval = 900
    let runDir: URL
    var controlURL: URL { runDir.appendingPathComponent("control.json") }
    private let log: EventLog?
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var snap = Snapshot.empty            // guarded by lock
    private var generationValue: UInt64 = 0     // guarded by lock; +1 on every change
    private let ctlQ = DispatchQueue(label: "wokyis.ctl", qos: .utility)
    private var dirSource: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var lastStat: (ino: UInt64, size: Int64, mtime: Double)? = nil   // ctlQ only; nil = file absent
    private var seenOnce = false                                            // ctlQ only

    init(runDir: URL, log: EventLog?) {
        self.runDir = runDir; self.log = log
        lock = .allocate(capacity: 1); lock.initialize(to: os_unfair_lock())
    }
    deinit { dirSource?.cancel(); timer?.cancel(); lock.deinitialize(count: 1); lock.deallocate() }

    // MARK: reader API (any thread)

    /// Current effective snapshot (expired → none, even before ctlQ notices).
    func snapshot(now: Date = Date()) -> Snapshot {
        os_unfair_lock_lock(lock); let s = snap; os_unfair_lock_unlock(lock)
        if let e = s.expires, now >= e { return .empty }
        return s
    }
    /// Increments on every state change (Store uses it to force a full redraw when the sim frame toggles).
    var generation: UInt64 { os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }; return generationValue }

    /// Throw `.injected(id)` when `id` is in `fail`. Call as the FIRST line of every source read.
    func check(_ id: SourceID) throws {
        if snapshot().fail.contains(id.rawValue) { throw SourceError.injected(id.rawValue) }
    }
    /// Throw `.injected("mem.mib:<name>")` when that single MIB is in `fail`.
    func checkMIB(_ name: String) throws {
        let key = "mem.mib:" + name
        if snapshot().fail.contains(key) { throw SourceError.injected(key) }
    }
    /// Sources that accept `garbage` (spec §9.2): the battery parsers and the three SystemSampler sources.
    static let garbageIDs: Set<SourceID> = [.batSP, .batIOPS, .cpuLoad, .cpuTasks, .netIF]
    /// Sources that accept `hang`.
    static let hangIDs: Set<SourceID> = [.batSP]

    /// hang only for bat.sp; garbage for `garbageIDs`; hang wins over garbage.
    func mode(_ id: SourceID) -> InjectMode {
        let s = snapshot()
        if Injector.hangIDs.contains(id) && s.hang.contains(id) { return .hang }
        if Injector.garbageIDs.contains(id) && s.garbage.contains(id) { return .garbage }
        return .none
    }
    var pressureOverride: (level: PressureLevel, percent: Int)? {
        guard let p = snapshot().pressure else { return nil }
        return (p.level, p.percent)
    }
    var active: Bool { !snapshot().isEmpty }
    /// nil = no injection in effect. Otherwise "模擬中：<名稱>、<名稱> <動作>；…" (spec §7.4).
    var badge: String? { Injector.badge(for: snapshot()) }

    /// The pieces of the on-screen badge (spec §4): each list in SourceID order ("mem.mib:<name>" after the SourceIDs);
    /// nil = nothing injected. StateBuilder/Store turn it into the localized, collapsed text with L10n.badge.
    static func badgeParts(_ s: Snapshot) -> BadgeParts? {
        guard !s.isEmpty else { return nil }
        let order = SourceID.allCases.map(\.rawValue)
        func ordered(_ keys: [String]) -> [String] {
            keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
        }
        return BadgeParts(fail: ordered(Array(s.fail)), hang: ordered(s.hang.map(\.rawValue)), garbage: ordered(s.garbage.map(\.rawValue)),
                          pressureLevel: s.pressure?.level, pressurePercent: s.pressure?.percent ?? 0)
    }
    var badgeParts: BadgeParts? { Injector.badgeParts(snapshot()) }

    static func badge(for s: Snapshot) -> String? {
        guard !s.isEmpty else { return nil }
        func name(_ key: String) -> String {
            if let id = SourceID(rawValue: key) { return id.badgeName }
            if key.hasPrefix("mem.mib:") { return "MIB " + key.dropFirst("mem.mib:".count).uppercased() }
            return key.uppercased()
        }
        func ordered(_ keys: [String]) -> [String] {
            let order = SourceID.allCases.map(\.rawValue)
            return keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
        }
        var parts: [String] = []
        if !s.fail.isEmpty { parts.append(ordered(Array(s.fail)).map(name).joined(separator: "、") + " 讀取失敗") }
        if !s.hang.isEmpty { parts.append(ordered(s.hang.map(\.rawValue)).map(name).joined(separator: "、") + " 逾時") }
        if !s.garbage.isEmpty { parts.append(ordered(s.garbage.map(\.rawValue)).map(name).joined(separator: "、") + " 格式錯誤") }
        if let p = s.pressure { parts.append("壓力 \(p.level.word) \(p.percent)%") }
        return "模擬中：" + parts.joined(separator: "；")
    }

    /// One-line description for `CTL state="…"` and scripts/status.sh.
    static func describe(_ s: Snapshot) -> String {
        guard !s.isEmpty else { return "none" }
        var t: [String] = []
        if !s.fail.isEmpty { t.append("fail=" + s.fail.sorted().joined(separator: ",")) }
        if !s.hang.isEmpty { t.append("hang=" + s.hang.map(\.rawValue).sorted().joined(separator: ",")) }
        if !s.garbage.isEmpty { t.append("garbage=" + s.garbage.map(\.rawValue).sorted().joined(separator: ",")) }
        if let p = s.pressure { t.append("pressure=\(p.level.rawValue)/\(p.percent)") }
        if let e = s.expires { t.append("expires=" + EventLog.timestamp(e)) }
        return t.joined(separator: " ")
    }

    // MARK: watching (ctlQ)

    /// Begin watching; performs the first read synchronously so injections present at launch apply to the first sample.
    func start() {
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        ctlQ.sync { self.poll(now: Date()) }
        let fd = open(runDir.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend, .attrib, .link], queue: ctlQ)
            src.setEventHandler { [weak self] in self?.poll(now: Date()) }
            src.setCancelHandler { close(fd) }
            src.resume(); dirSource = src
        } else {
            log?.event("WARN", "ctl_watch_failed errno=\(errno) dir=\(EventLog.q(runDir.path))")
        }
        let t = DispatchSource.makeTimerSource(queue: ctlQ)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.poll(now: Date()) }
        t.resume(); timer = t
    }
    func stop() { ctlQ.sync { dirSource?.cancel(); dirSource = nil; timer?.cancel(); timer = nil } }

    private func poll(now: Date) {
        // expiry is checked every poll, independent of file changes
        os_unfair_lock_lock(lock); let cur = snap; os_unfair_lock_unlock(lock)
        if let e = cur.expires, now >= e, !cur.isEmpty {
            install(.empty); log?.event("CTL", "expired sim=0")
        }
        var st = stat()
        let exists = stat(controlURL.path, &st) == 0
        let key: (ino: UInt64, size: Int64, mtime: Double)? = exists
            ? (UInt64(st.st_ino), Int64(st.st_size), Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9) : nil
        if seenOnce, key?.ino == lastStat?.ino, key?.size == lastStat?.size, key?.mtime == lastStat?.mtime { return }
        seenOnce = true; lastStat = key
        let data = exists ? (try? Data(contentsOf: controlURL)) : nil
        if exists && data == nil { _ = apply(nil, now: now, reasonIfNil: "unreadable"); return }
        _ = apply(data, now: now)
    }

    // MARK: parsing (pure-ish; used by the watcher and by the self test)

    /// Parse `data` (nil = file absent), install the resulting snapshot and log the outcome.
    @discardableResult
    func apply(_ data: Data?, now: Date, reasonIfNil: String? = nil) -> Outcome {
        let (s, outcome) = Injector.parse(data, now: now, reasonIfNil: reasonIfNil)
        install(s)
        switch outcome {
        case .cleared(let why): log?.event("CTL", "state=\"none\" why=\(why) sim=0")
        case .invalid(let r): log?.event("CTL", "invalid reason=\(EventLog.q(r)) sim=0")
        case .expired: log?.event("CTL", "expired sim=0")
        case .active(let clamped):
            if clamped { log?.event("WARN", "ctl_expires_clamped max_s=\(Int(Injector.maxLifetime)) sim=1") }
            log?.event("CTL", "state=\(EventLog.q(Injector.describe(s))) sim=1")
        }
        return outcome
    }

    private func install(_ s: Snapshot) {
        os_unfair_lock_lock(lock)
        if s != snap { snap = s; generationValue &+= 1 }
        os_unfair_lock_unlock(lock)
    }

    static func parse(_ data: Data?, now: Date, reasonIfNil: String? = nil) -> (Snapshot, Outcome) {
        guard let data else {
            if let r = reasonIfNil { return (.empty, .invalid(r)) }
            return (.empty, .cleared("missing"))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data), let d = obj as? [String: Any] else {
            return (.empty, .invalid("not_json_object"))
        }
        if d.isEmpty { return (.empty, .cleared("empty")) }
        guard let v = d["version"] as? NSNumber, CFGetTypeID(v) != CFBooleanGetTypeID(), v.intValue == 1, v.doubleValue == 1 else {
            return (.empty, .invalid("version"))
        }
        let known: Set<String> = ["version", "expires", "fail", "hang", "garbage", "pressure"]
        if let extra = d.keys.first(where: { !known.contains($0) }) { return (.empty, .invalid("unknown_key:\(extra)")) }
        var s = Snapshot()
        func strings(_ k: String) -> [String]?? {   // nil = key absent; .some(nil) = wrong type
            guard let raw = d[k] else { return nil }
            guard let a = raw as? [Any] else { return .some(nil) }
            var out: [String] = []
            for x in a { guard let str = x as? String else { return .some(nil) }; out.append(str) }
            return .some(out)
        }
        if let f = strings("fail") {
            guard let f else { return (.empty, .invalid("fail_type")) }
            for id in f {
                if SourceID(rawValue: id) != nil { s.fail.insert(id); continue }
                if id.hasPrefix("mem.mib:"), id.count > "mem.mib:".count, !id.contains(" ") { s.fail.insert(id); continue }
                return (.empty, .invalid("unknown_id:\(id)"))
            }
        }
        if let h = strings("hang") {
            guard let h else { return (.empty, .invalid("hang_type")) }
            for id in h {
                guard id == SourceID.batSP.rawValue else { return (.empty, .invalid("hang_not_allowed:\(id)")) }
                s.hang.insert(.batSP)
            }
        }
        if let g = strings("garbage") {
            guard let g else { return (.empty, .invalid("garbage_type")) }
            for id in g {
                guard let sid = SourceID(rawValue: id), Injector.garbageIDs.contains(sid) else { return (.empty, .invalid("garbage_not_allowed:\(id)")) }
                s.garbage.insert(sid)
            }
        }
        if let p = d["pressure"] {
            guard let pd = p as? [String: Any], let l = pd["level"] as? NSNumber, let pc = pd["percent"] as? NSNumber,
                  [1, 2, 4].contains(l.intValue), l.doubleValue == Double(l.intValue), pc.doubleValue.isFinite else {
                return (.empty, .invalid("pressure"))
            }
            let pct = Int(pc.doubleValue.rounded())
            guard (0...100).contains(pct) else { return (.empty, .invalid("pressure_percent_range")) }
            s.pressure = PressureOverride(level: PressureLevel(kernel: l.intValue), percent: pct)
        }
        if s.isEmpty {   // only version/expires → nothing injected
            return (.empty, .cleared("empty"))
        }
        guard let es = d["expires"] as? String else { return (.empty, .invalid("expires_missing")) }
        guard let e = parseISO(es) else { return (.empty, .invalid("expires_format")) }
        if e <= now { return (.empty, .expired) }
        var clamped = false
        if e.timeIntervalSince(now) > maxLifetime { s.expires = now.addingTimeInterval(maxLifetime); clamped = true } else { s.expires = e }
        return (s, .active(clamped: clamped))
    }

    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// Source lists + pressure of the active injection (Injector.badgeParts). Localized by `text(_:view:fits:)`.
struct BadgeParts: Equatable, Sendable {
    var fail: [String] = [], hang: [String] = [], garbage: [String] = []
    var pressureLevel: PressureLevel? = nil
    var pressurePercent = 0
    func text(_ lang: Lang, view: ViewKind, fits: ((String) -> Bool)?) -> String? {
        L10n.badge(fail: fail, hang: hang, garbage: garbage, pressure: pressureLevel.map { ($0, pressurePercent) }, lang, view: view, fits: fits)
    }
}

// MARK: - self test

enum InjectorSelfTest {
    static func run() -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        let now = Date()
        func iso(_ d: Date) -> String { EventLog.timestamp(d) }
        func j(_ s: String) -> Data { Data(s.utf8) }
        let inj = Injector(runDir: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wokyis-selftest-unused"), log: nil)

        // valid, full
        let full = j("""
        {"version":1,"expires":"\(iso(now.addingTimeInterval(300)))","fail":["mem.swap","bat.hid","mem.mib:vm.page_wired_count"],
         "hang":["bat.sp"],"garbage":["bat.sp","bat.iops"],"pressure":{"level":2,"percent":71}}
        """)
        let o1 = inj.apply(full, now: now)
        var threwSwap = false; do { try inj.check(.memSwap) } catch SourceError.injected(let id) { threwSwap = id == "mem.swap" } catch {}
        var threwPhys = false; do { try inj.check(.memPhysical) } catch { threwPhys = true }
        var threwMIB = false; do { try inj.checkMIB("vm.page_wired_count") } catch SourceError.injected(let id) { threwMIB = id == "mem.mib:vm.page_wired_count" } catch {}
        var threwOtherMIB = false; do { try inj.checkMIB("vm.page_free_count") } catch { threwOtherMIB = true }
        out.append(SelfTestCase("injector.valid", o1 == .active(clamped: false) && threwSwap && !threwPhys && threwMIB && !threwOtherMIB))
        out.append(SelfTestCase("injector.modes", inj.mode(.batSP) == .hang && inj.mode(.batIOPS) == .garbage && inj.mode(.batHID) == .none
                                && inj.mode(.memSwap) == .none))
        let po = inj.pressureOverride
        out.append(SelfTestCase("injector.pressure", po?.level == .warning && po?.percent == 71))
        let b = inj.badge ?? ""
        out.append(SelfTestCase("injector.badge", b.hasPrefix("模擬中：交換檔、HID、MIB VM.PAGE_WIRED_COUNT 讀取失敗") && b.contains("藍牙連線 逾時")
                                && b.contains("AIRPODS 電量、藍牙連線 格式錯誤") && b.hasSuffix("壓力 警告 71%"), b))
        let g0 = inj.generation
        // clear
        let o2 = inj.apply(j("{}"), now: now)
        out.append(SelfTestCase("injector.clear", o2 == .cleared("empty") && inj.badge == nil && !inj.active && inj.pressureOverride == nil
                                && inj.generation == g0 &+ 1))
        // clamp
        let o3 = inj.apply(j("{\"version\":1,\"expires\":\"\(iso(now.addingTimeInterval(7200)))\",\"fail\":[\"mem.vm\"]}"), now: now)
        let exp = inj.snapshot(now: now).expires
        out.append(SelfTestCase("injector.clamp", o3 == .active(clamped: true) && exp != nil && abs(exp!.timeIntervalSince(now) - 900) < 0.01))
        // effective expiry without the watcher
        out.append(SelfTestCase("injector.expiry_effective", inj.snapshot(now: now.addingTimeInterval(901)).isEmpty
                                && !inj.snapshot(now: now.addingTimeInterval(899)).isEmpty))
        // already expired
        let o4 = inj.apply(j("{\"version\":1,\"expires\":\"\(iso(now.addingTimeInterval(-1)))\",\"fail\":[\"mem.vm\"]}"), now: now)
        out.append(SelfTestCase("injector.expired", o4 == .expired && !inj.active))
        // invalid cases → cleared
        _ = inj.apply(full, now: now)
        let invalids: [(String, String, String)] = [
            ("json", "{not json", "not_json_object"),
            ("version2", "{\"version\":2,\"expires\":\"\(iso(now.addingTimeInterval(60)))\",\"fail\":[\"mem.vm\"]}", "version"),
            ("noexpires", "{\"version\":1,\"fail\":[\"mem.vm\"]}", "expires_missing"),
            ("badexpires", "{\"version\":1,\"expires\":\"tomorrow\",\"fail\":[\"mem.vm\"]}", "expires_format"),
            ("unknownid", "{\"version\":1,\"expires\":\"\(iso(now.addingTimeInterval(60)))\",\"fail\":[\"mem.bogus\"]}", "unknown_id:mem.bogus"),
            ("hangmem", "{\"version\":1,\"expires\":\"\(iso(now.addingTimeInterval(60)))\",\"hang\":[\"mem.swap\"]}", "hang_not_allowed:mem.swap"),
            ("garbagehid", "{\"version\":1,\"expires\":\"\(iso(now.addingTimeInterval(60)))\",\"garbage\":[\"bat.hid\"]}", "garbage_not_allowed:bat.hid"),
            ("pressurelevel", "{\"version\":1,\"expires\":\"\(iso(now.addingTimeInterval(60)))\",\"pressure\":{\"level\":3,\"percent\":50}}", "pressure"),
            ("pressurepct", "{\"version\":1,\"expires\":\"\(iso(now.addingTimeInterval(60)))\",\"pressure\":{\"level\":4,\"percent\":150}}", "pressure_percent_range"),
            ("failtype", "{\"version\":1,\"expires\":\"\(iso(now.addingTimeInterval(60)))\",\"fail\":\"mem.vm\"}", "fail_type"),
            ("extrakey", "{\"version\":1,\"expires\":\"\(iso(now.addingTimeInterval(60)))\",\"fial\":[\"mem.vm\"]}", "unknown_key:fial"),
            ("array", "[1,2]", "not_json_object"),
        ]
        for (name, text, reason) in invalids {
            _ = inj.apply(full, now: now)
            let o = inj.apply(j(text), now: now)
            out.append(SelfTestCase("injector.invalid.\(name)", o == .invalid(reason) && !inj.active, "\(o)"))
        }
        let o5 = inj.apply(nil, now: now)
        out.append(SelfTestCase("injector.missing_file", o5 == .cleared("missing") && !inj.active))

        // v2 (spec §9.2, §10.1 injector.new_ids): fail accepts the three new ids; garbage cpu.load / cpu.tasks / net.if;
        // hang stays bat.sp only
        let exp60 = iso(now.addingTimeInterval(60))
        let oF = inj.apply(j("{\"version\":1,\"expires\":\"\(exp60)\",\"fail\":[\"cpu.load\",\"cpu.tasks\",\"net.if\"]}"), now: now)
        var thr = 0
        for id in [SourceID.cpuLoad, .cpuTasks, .netIF] { do { try inj.check(id) } catch { thr += 1 } }
        let oG = inj.apply(j("{\"version\":1,\"expires\":\"\(exp60)\",\"garbage\":[\"cpu.load\",\"cpu.tasks\",\"net.if\"]}"), now: now)
        let modesOK = inj.mode(.cpuLoad) == .garbage && inj.mode(.cpuTasks) == .garbage && inj.mode(.netIF) == .garbage && inj.mode(.batSP) == .none
        let oH = inj.apply(j("{\"version\":1,\"expires\":\"\(exp60)\",\"hang\":[\"cpu.load\"]}"), now: now)
        let oGH = inj.apply(j("{\"version\":1,\"expires\":\"\(exp60)\",\"garbage\":[\"bat.hid\"]}"), now: now)
        out.append(SelfTestCase("injector.new_ids", oF == .active(clamped: false) && thr == 3 && oG == .active(clamped: false) && modesOK
                                && oH == .invalid("hang_not_allowed:cpu.load") && oGH == .invalid("garbage_not_allowed:bat.hid"),
                                "fail=\(oF) thrown=\(thr) garbage=\(oG) modes=\(modesOK) hang=\(oH)"))
        // badge parts: SourceID order per list, mem.mib after the ids; localized + view priority via L10n.badge
        let parts = Injector.badgeParts(Injector.parse(j("""
        {"version":1,"expires":"\(exp60)","fail":["net.if","mem.mib:vm.x","bat.hid","mem.swap"],"garbage":["cpu.tasks"],"pressure":{"level":4,"percent":92}}
        """), now: now).0)
        let zhCPU = parts?.text(.zh, view: .cpu, fits: nil) ?? ""
        let enNet = parts?.text(.en, view: .network, fits: nil) ?? ""
        out.append(SelfTestCase("injector.badge_parts", parts?.fail == ["mem.swap", "bat.hid", "net.if", "mem.mib:vm.x"] && parts?.garbage == ["cpu.tasks"]
                                && parts?.pressureLevel == .critical && parts?.pressurePercent == 92
                                && zhCPU.hasPrefix("模擬中：HID、交換檔") && zhCPU.contains("執行緒與程序 格式錯誤")
                                && enNet.hasPrefix("SIM: NET COUNTERS, HID") && enNet.hasSuffix("PRESSURE CRITICAL 92%")
                                && Injector.badgeParts(.empty) == nil, "\(zhCPU) | \(enNet)"))
        return out
    }

    /// Live watcher check: writes control.json atomically in `dir` (a temp dir owned by the caller) and waits for the
    /// vnode/stat watcher to pick it up; then clears it. Returns latency in ms per step.
    static func runLive(dir: URL) -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        let inj = Injector(runDir: dir, log: nil)
        inj.start()
        defer { inj.stop() }
        func atomicWrite(_ s: String) {
            let tmp = dir.appendingPathComponent(".control.json.tmp")
            try? Data(s.utf8).write(to: tmp)
            _ = rename(tmp.path, dir.appendingPathComponent("control.json").path)
        }
        func wait(_ cond: () -> Bool, max: Double = 3.0) -> Double? {
            let t0 = Date()
            while Date().timeIntervalSince(t0) < max { if cond() { return Date().timeIntervalSince(t0) * 1000 }; usleep(10_000) }
            return nil
        }
        atomicWrite("{\"version\":1,\"expires\":\"\(EventLog.timestamp(Date().addingTimeInterval(60)))\",\"fail\":[\"bat.hid\"]}")
        let t1 = wait { inj.active }
        out.append(SelfTestCase("injector.live.activate", t1 != nil, t1.map { String(format: "%.0f ms", $0) } ?? "timeout"))
        atomicWrite("{}")
        let t2 = wait { !inj.active }
        out.append(SelfTestCase("injector.live.clear", t2 != nil, t2.map { String(format: "%.0f ms", $0) } ?? "timeout"))
        // expiry while the file stays in place: 1.2 s lifetime
        atomicWrite("{\"version\":1,\"expires\":\"\(EventLog.timestamp(Date().addingTimeInterval(1.2)))\",\"pressure\":{\"level\":4,\"percent\":92}}")
        let t3 = wait { inj.active }
        let t4 = wait({ !inj.active }, max: 3.5)
        out.append(SelfTestCase("injector.live.expire", t3 != nil && t4 != nil, "activate \(t3.map { String(format: "%.0f ms", $0) } ?? "timeout"), expire after \(t4.map { String(format: "%.0f ms", $0) } ?? "timeout")"))
        return out
    }
}
