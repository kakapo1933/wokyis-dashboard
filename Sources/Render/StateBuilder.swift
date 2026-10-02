// StateBuilder.swift — Store → PanelState pieces, per-region change keys (per view, v2 spec §6.3), CPU / network display
// strings (v2 spec §5.2–§5.3), paging helpers and the DSP battery / view strings (spec §2, §5.6, §6.6, §7.3 regions,
// §7.4, §12 DSP). Pure functions (no AppKit), so --selftest can cover them.
// Owner: app agent.
import Foundation

enum StateBuilder {
    /// A state with every memory value failed ("—"), unknown pressure, no history, no devices.
    static func placeholder(now: Date) -> PanelState {
        PanelState(memory: blankMemory, history: [], now: now.timeIntervalSince1970, historyCoverage: 0, devices: [],
                   clock: EventLog.hms(now))
    }

    static let blankMemory = MemoryDisplay(physical: .failed, used: .failed, cached: .failed, swap: .failed, app: .failed,
                                           wired: .failed, compressed: .failed, pressurePercent: nil, pressureLevel: nil)

    /// The seven values + pressure of one sample. A field whose string is nil (read failed in THIS sample) → "—".
    static func memory(_ m: MemSample) -> MemoryDisplay {
        func shown(_ f: Field) -> Shown {
            if let v = m.strings[f], let t = v { return .text(t) }
            return .failed
        }
        return MemoryDisplay(physical: shown(.physical), used: shown(.used), cached: shown(.cached), swap: shown(.swap),
                             app: shown(.app), wired: shown(.wired), compressed: shown(.compressed),
                             pressurePercent: m.pressure?.pct, pressureLevel: m.pressure?.level,
                             pressureSimulated: m.simulated)
    }

    static func key(_ v: Shown) -> String { if case .text(let t) = v { return t }; return "—" }

    /// Left axis label exactly as the renderer draws it in Chinese (coverage < 600 s → "收集中 N/10 分鐘").
    static func axisLabel(_ coverage: Double) -> String { L10n.axisLeft(coverage: coverage, .zh) }

    /// One string per region of the ACTIVE view + the shared regions; a region is redrawn when its key changes.
    /// `.chrome` = view | language | battery column | simulation frame: when it changes the whole view is redrawn
    /// (view switch, language, battery column, frame on/off). `.graph` has no key: it is dirtied by the first arrival of
    /// the active view's source in a new wall second, or by the 1 Hz tick when that source missed the second (spec §6.2).
    /// Samples of a hidden view change no key (no dirty). History is never read here (spec §6.3).
    static func regionKeys(_ s: PanelState) -> [Region: String] {
        var k: [Region: String] = [
            .chrome: "\(s.view.token)|\(s.lang.rawValue)|\(s.batteryVisible ? 1 : 0)|\(s.simulationBadge == nil ? "plain" : "sim")",
            .clock: s.clock + (s.sampleStale ? "|stale" : ""),
            .sim: s.simulationBadge ?? "",
        ]
        if s.batteryVisible {
            let pages = PanelRenderer.pages(s.devices).count
            k[.battery] = deviceSignature(s.devices) + "#p\(min(s.batteryPage, max(0, pages - 1)))/\(pages)"
        }
        switch s.view {
        case .memory:
            let m = s.memory
            k[.used] = key(m.used)
            k[.pressure] = "\(m.pressurePercent.map(String.init) ?? "—")|\(m.pressurePercent == nil ? 0 : (m.pressureLevel?.rawValue ?? 0))"
            k[.axis] = L10n.axisLeft(coverage: s.historyCoverage, s.lang)
            k[.sec0] = key(m.physical); k[.sec1] = key(m.cached); k[.sec2] = key(m.swap)
            k[.sec3] = key(m.app); k[.sec4] = key(m.wired); k[.sec5] = key(m.compressed)
        case .cpu:
            let c = s.cpu
            k[.cpuSys] = key(c.system); k[.cpuUser] = key(c.user); k[.cpuIdle] = key(c.idle)
            k[.cpuThreads] = key(c.threads); k[.cpuProcs] = key(c.processes)
            k[.axis] = L10n.axisLeft(coverage: s.sysCoverage, s.lang)
        case .network:
            let n = s.net
            k[.netDown] = key(n.download); k[.netUp] = key(n.upload); k[.netPktIn] = key(n.packetsIn); k[.netPktOut] = key(n.packetsOut)
            k[.netPktInS] = key(n.packetsInRate); k[.netPktOutS] = key(n.packetsOutRate); k[.netRecv] = key(n.received); k[.netSent] = key(n.sent)
            k[.axis] = L10n.axisLeft(coverage: s.sysCoverage, s.lang)
        }
        return k
    }

    /// DSP view tokens (spec §9.1): "view=mem lang=zh batv=1".
    static func dspTokens(_ s: PanelState) -> String {
        "view=\(s.view.token) lang=\(s.lang.rawValue) batv=\(s.batteryVisible ? 1 : 0)"
    }

    /// The active view shows no value at all (every value "—"): DSP ` blank=1`.
    static func isBlank(_ s: PanelState) -> Bool {
        switch s.view {
        case .memory: return s.memory.used == .failed && s.memory.physical == .failed && s.memory.pressurePercent == nil
        case .cpu: return s.cpu.system == .failed && s.cpu.user == .failed && s.cpu.idle == .failed && s.cpu.threads == .failed && s.cpu.processes == .failed
        case .network: return s.net.download == .failed && s.net.upload == .failed && s.net.packetsIn == .failed && s.net.received == .failed
        }
    }

    // MARK: v2 CPU / network display strings (spec §5.2, §5.3) — computed once per SysSample / language change (Store).
    // The formatting itself is the sampler's SysFormat (Sources/System/SystemSampler.swift: AM paddedPercent,
    // integerFormatter, speed, fileSizeFormatter); these are the spec §6.3 entry points.

    /// CPU footer values of one reading (nil = "—"). threads nil (pset failed, procs from the fallback) → "—".
    static func cpu(_ r: CPUReading?, tasks: TaskCounts?) -> CPUDisplay { SysFormat.cpu(r, tasks: tasks) }

    /// Network footer values of one reading (nil = all "—"); rates nil (baseline just set) → "—" for the four rates.
    static func net(_ r: NetReading?, lang: Lang) -> NetDisplay { SysFormat.net(r, lang) }

    /// Everything the battery column draws for a device list.
    static func deviceSignature(_ ds: [DeviceGroup]) -> String {
        ds.map { g in
            "\(g.kind.rawValue):\(g.ownerTag ?? ""):\(g.presence.rawValue):" + g.cells.map { c in
                switch c.state {
                case .ok(let p, let ch): return "\(c.label)=\(p)\(ch ? "c" : "")"
                case .failed: return "\(c.label)=F"
                case .unavailable: return "\(c.label)=U"
                case .stale: return "\(c.label)=S"
                }
            }.joined(separator: ",")
        }.joined(separator: ";")
    }

    /// DSP `bat="kb:100 tp:85 L:100 R:97 C:48c"` — only the devices on the displayed page, in drawing order.
    /// Tokens: N (ok), Nc (charging), F (failed "—"), U (unavailable dim "—"), S (sp stale, grey "—"), off (離線).
    /// HID prefixes kb/tp/ms/hid; with an owner tag (two devices of one kind) `kb[ALEX]:100`; tagged AirPods groups
    /// get a `pods[TAG]` token before their cells. A nearby AirPods group (grey numbers + 「附近」) always gets a
    /// `pods~` / `pods[TAG]~` token before its cells: `pods~ L:97 R:99 C:U`.
    static func dspBattery(_ s: PanelState) -> String {
        if s.devices.isEmpty { return "none" }
        let pages = PanelRenderer.pages(s.devices)
        let page = pages[min(s.batteryPage, pages.count - 1)]
        func tok(_ c: CellState) -> String {
            switch c {
            case .ok(let p, let ch): return "\(p)" + (ch ? "c" : "")
            case .failed: return "F"
            case .unavailable: return "U"
            case .stale: return "S"
            }
        }
        var out: [String] = []
        for b in page {
            switch b {
            case .hid(let d):
                let pre: String
                switch d.kind { case .keyboard: pre = "kb"; case .trackpad: pre = "tp"; case .mouse: pre = "ms"; default: pre = "hid" }
                out.append("\(pre)\(d.ownerTag.map { "[\($0)]" } ?? ""):" + (d.connected ? (d.cells.first.map { tok($0.state) } ?? "-") : "off"))
            case .pods(let d):
                let tag = d.ownerTag.map { "[\($0)]" } ?? ""
                if !d.showsCells { out.append("pods\(tag):off"); continue }
                if d.presence == .nearby { out.append("pods\(tag)~") } else if !tag.isEmpty { out.append("pods\(tag)") }
                let names = ["L", "R", "C"]
                for (i, c) in d.cells.enumerated() { out.append("\(d.cells.count == 3 ? names[i] : "P"):\(tok(c.state))") }
            }
        }
        return out.joined(separator: " ")
    }
}

/// App-module self-test hook (Store / StateBuilder) called by `--selftest`. Pure: no files, no timers, no windows.
enum AppSelfTest {
    static func sample(seq: UInt64, t: Date, used: String? = "18.52 GB", swap: String? = "39.8 MB", pct: Int? = 48,
                       level: PressureLevel = .normal, simulated: Bool = false) -> MemSample {
        var s: [Field: String?] = [:]
        for f in Field.allCases { s[f] = .some("1.00 GB") }
        s[.physical] = .some("24.00 GB"); s[.used] = .some(used); s[.swap] = .some(swap)
        var b = MemoryBytes()
        for f in Field.allCases { b[f] = s[f]! == nil ? nil : 1 << 30 }
        return MemSample(seq: seq, tWall: t, durUs: 10, bytes: b, strings: s, pressure: pct.map { ($0, level) },
                         simulated: simulated, failed: used == nil ? ["mem.mib:vm.page_free_count"] : [], mode: .mte)
    }

    static func kb(_ p: Int, connected: Bool = true) -> DeviceGroup {
        DeviceGroup(kind: .keyboard, name: "KB", ownerTag: nil, connected: connected, cells: [BatteryCell(label: "鍵盤", state: .ok(p, charging: false))])
    }
    static func pods(_ name: String, _ l: Int) -> DeviceGroup {
        DeviceGroup(kind: .airpods, name: name, ownerTag: name, connected: true,
                    cells: [BatteryCell(label: "左耳", state: .ok(l, charging: false)), BatteryCell(label: "右耳", state: .unavailable),
                            BatteryCell(label: "充電盒", state: .ok(40, charging: true))])
    }

    static func sys(seq: UInt64, t: Date, cpu: Reading<CPUReading>? = nil, tasks: Reading<TaskCounts>? = nil, net: Reading<NetReading>? = nil,
                    rx: Double? = 739_000, cpuSim: Bool = false, netSim: Bool = false) -> SysSample {
        SysSample(seq: seq, tWall: t, durUs: 300,
                  cpu: cpu ?? .value(CPUReading(system: 4.99, user: 16.65, idle: 78.36, nice: 0, cores: 12)),
                  tasks: tasks ?? .value(TaskCounts(threads: 4_783, processes: 795)),
                  net: net ?? .value(NetReading(pktIn: 27_833_717, pktOut: 68_441_461, bytesIn: 22_758_680_252, bytesOut: 93_632_064_060,
                                                pktInRate: rx == nil ? nil : 612, pktOutRate: rx == nil ? nil : 148, rxRate: rx,
                                                txRate: rx == nil ? nil : 19_574, ifaces: 14)),
                  cpuSimulated: cpuSim, netSimulated: netSim)
    }

    /// v2 Store / StateBuilder / DSP cases (spec §10.1 store.*, dsp.view_tokens, ui.mem_hz).
    static func v2Cases() -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        func expect(_ name: String, _ ok: Bool, _ d: String = "") { out.append(SelfTestCase(name, ok, d)) }
        func names(_ d: Set<Region>) -> String { d.map(\.rawValue).sorted().joined(separator: ",") }
        let t0 = Date(timeIntervalSince1970: 1_790_000_100)
        func at(_ x: Double) -> Date { t0.addingTimeInterval(x) }
        let all = Set(Region.allCases)

        // view / language / battery column switch → full redraw; same settings → nothing
        let a = Store(config: Config(), startedAt: t0)
        a.apply(sample(seq: 1, t: at(0)), now: at(0)); a.applySys(sys(seq: 1, t: at(0)), now: at(0)); a.clearDirty()
        a.setUI(UISettings(view: .cpu), lang: .zh, now: at(0.1)); let v1 = a.dirty; a.clearDirty()
        a.setUI(UISettings(view: .cpu), lang: .en, now: at(0.2)); let v2 = a.dirty; a.clearDirty()
        a.setUI(UISettings(view: .cpu, batteryVisible: false), lang: .en, now: at(0.3)); let v3 = a.dirty; a.clearDirty()
        a.setUI(UISettings(view: .cpu, batteryVisible: false), lang: .en, now: at(0.4)); let v4 = a.dirty
        let ps = a.panelState(now: at(0.4))
        expect("store.view_switch_full", v1 == all && v2 == all && v3 == all && v4.isEmpty && ps.view == .cpu && ps.lang == .en && !ps.batteryVisible,
               "\(names(v4))")

        // hidden view: MEM on the CPU view changes no key; battery groups with the column hidden → no dirty
        let h = Store(config: Config(), startedAt: t0)
        h.setUI(UISettings(view: .cpu), lang: .zh, now: at(0))
        h.applySys(sys(seq: 1, t: at(1)), now: at(1)); h.clearDirty()
        h.apply(sample(seq: 1, t: at(1.25)), now: at(1.25)); let h1 = h.dirty
        h.apply(sample(seq: 2, t: at(2.0), used: "19.00 GB"), now: at(2.0)); let h2 = h.dirty
        h.setUI(UISettings(view: .memory, batteryVisible: false), lang: .zh, now: at(2.1)); h.clearDirty()
        h.applyBattery([kb(50)], now: at(2.2)); let h3 = h.dirty
        expect("store.hidden_view_no_dirty", h1.isEmpty && h2.isEmpty && h3.isEmpty, "\(names(h1))|\(names(h2))|\(names(h3))")

        // per-view staleness: CPU view → SysSample age; 5 s chip, 10 s all "—"; .failed → "—" at once; .skipped keeps
        let p = Store(config: Config(), startedAt: t0)
        p.setUI(UISettings(view: .cpu), lang: .zh, now: at(0))
        p.applySys(sys(seq: 1, t: at(1)), now: at(1))
        for i in 0..<12 { p.apply(sample(seq: UInt64(i + 1), t: at(1 + Double(i))), now: at(1 + Double(i))) }   // MEM keeps flowing
        let s6 = p.panelState(now: at(6.5)), s11 = p.panelState(now: at(11.5))
        let staleOK = s6.sampleStale && s6.cpu.system == .text("4.99%") && s11.sampleStale && s11.cpu.system == .failed && s11.cpu.threads == .failed
            && s11.net.download == .failed && !p.isStale(view: .memory, now: at(11.5))
        p.applySys(sys(seq: 2, t: at(12), cpu: .failed(err: "kr=5")), now: at(12))
        let sF = p.panelState(now: at(12))
        p.applySys(sys(seq: 3, t: at(13), cpu: .skipped(reason: "dt"), tasks: .skipped(reason: "dt"), net: .skipped(reason: "dt")), now: at(13))
        let sS = p.panelState(now: at(13))
        p.applySys(sys(seq: 4, t: at(14), tasks: .failed(err: "implausible")), now: at(14))
        let sT = p.panelState(now: at(14))
        expect("store.stale_per_view", staleOK && !sF.sampleStale && sF.cpu.system == .failed && sF.cpu.user == .failed && sF.cpu.threads == .text("4,783")
               && sS.cpu.system == .failed && sS.cpu.threads == .text("4,783") && sS.net.download == .text("5.91 Mb/秒")
               && sT.cpu.system == .text("4.99%") && sT.cpu.threads == .failed && sT.cpu.processes == .failed,
               "6s=\(s6.sampleStale) 11s=\(StateBuilder.key(s11.cpu.system)) fail=\(StateBuilder.key(sF.cpu.system)) skip=\(StateBuilder.key(sS.net.download))")

        // display-pass merge: memory view → graph only with the .000 MEM; the tick adds nothing while MEM arrived this
        // second, scrolls the graph when it did not; CPU view → SysSample + tick = one pass
        let m = Store(config: Config(), startedAt: t0)
        var passes: [String] = []
        for (i, f) in [0.0, 0.25, 0.5, 0.75].enumerated() {
            m.apply(sample(seq: UInt64(i + 1), t: at(10 + f), swap: "\(40 + i).0 MB"), now: at(10 + f))
            passes.append(names(m.dirty.intersection([.graph]))); m.clearDirty()
            if i == 0 { m.tick1Hz(now: at(10.03)); passes.append("tick:" + names(m.dirty)); m.clearDirty() }
        }
        m.tick1Hz(now: at(11.03)); let missed = m.dirty.contains(.graph); m.clearDirty()
        m.setUI(UISettings(view: .cpu), lang: .zh, now: at(11.5)); m.clearDirty()
        m.applySys(sys(seq: 1, t: at(12)), now: at(12)); let sysPass = m.dirty.contains(.graph) && m.dirty.contains(.cpuSys); m.clearDirty()
        m.apply(sample(seq: 9, t: at(12.0)), now: at(12.01)); let memHidden = m.dirty; m.clearDirty()
        m.tick1Hz(now: at(12.03)); let cpuTick = m.dirty
        expect("store.pass_merge", passes == ["graph", "tick:", "", "", ""] && missed && sysPass && memHidden.isEmpty && cpuTick.isEmpty,
               "\(passes) missed=\(missed) sys=\(sysPass) hidden=\(names(memHidden)) cpu_tick=\(names(cpuTick))")

        // histories: one point per second whatever the view, same second replaces, failed → nil point, skipped → none
        let c = Store(config: Config(), startedAt: t0)
        for i in 0..<5 { c.applySys(sys(seq: UInt64(i), t: at(20 + Double(i))), now: at(20 + Double(i))) }
        c.applySys(sys(seq: 9, t: at(24.4)), now: at(24.4))                                     // same second
        let n1 = (c.cpuHistoryCount, c.netHistoryCount)
        c.applySys(sys(seq: 10, t: at(25), cpu: .failed(err: "x"), net: .failed(err: "x")), now: at(25))
        c.applySys(sys(seq: 11, t: at(26), cpu: .skipped(reason: "dt"), net: .skipped(reason: "dt")), now: at(26))
        c.applySys(sys(seq: 12, t: at(27), rx: nil), now: at(27))                                // baseline just set
        let st = c.sysHistoryStats()
        let cs = c.panelState(now: at(27))
        var tsOK = true, last = -1.0
        cs.cpuHistory.forEach { if $0.t <= last { tsOK = false }; last = $0.t }
        expect("store.history_coverage", n1 == (5, 5) && c.cpuHistoryCount == 7 && c.netHistoryCount == 7 && st.cpu == 6 && st.net == 5
               && tsOK && cs.cpuHistory.count == 7 && cs.net.download == .failed && cs.net.packetsIn == .text("27,833,717"),
               "n1=\(n1) cpu=\(c.cpuHistoryCount) net=\(c.netHistoryCount) valid=\(st)")

        // per-graph simulated stripe: a net.if injection marks only NetPoints, a cpu.load one only CPUPoints (spec §169)
        let g = Store(config: Config(), startedAt: t0)
        g.applySys(sys(seq: 1, t: at(1), net: .failed(err: "injected"), netSim: true), now: at(1))
        g.applySys(sys(seq: 2, t: at(2), cpu: .failed(err: "injected"), cpuSim: true), now: at(2))
        let gs = g.panelState(now: at(2))
        var cpuSims: [Bool] = [], netSims: [Bool] = [], cpuVals: [Bool] = []
        gs.cpuHistory.forEach { cpuSims.append($0.simulated); cpuVals.append($0.system != nil) }
        gs.netHistory.forEach { netSims.append($0.simulated) }
        expect("store.sim_per_graph", cpuSims == [false, true] && netSims == [true, false] && cpuVals == [true, false],
               "cpu=\(cpuSims) net=\(netSims)")

        // language change re-formats the shown speeds (no new sample needed)
        let l = Store(config: Config(), startedAt: t0)
        l.setUI(UISettings(view: .network), lang: .zh, now: at(0)); l.applySys(sys(seq: 1, t: at(1)), now: at(1))
        let zhD = l.panelState(now: at(1)).net.download
        l.setUI(UISettings(view: .network, language: .en), lang: .en, now: at(1.1))
        let enD = l.panelState(now: at(1.1)).net.download
        expect("store.lang_net", zhD == .text("5.91 Mb/秒") && enD == .text("5.91 Mb/s"), "\(StateBuilder.key(zhD)) \(StateBuilder.key(enD))")

        // badge: localized for the language and the active view; recomputed on a view switch; full redraw on/off
        let b = Store(config: Config(), startedAt: t0)
        b.apply(sample(seq: 1, t: at(0)), now: at(0)); b.clearDirty()
        let parts = BadgeParts(fail: ["mem.swap", "cpu.load"], hang: [], garbage: [], pressureLevel: nil, pressurePercent: 0)
        b.setSimulation(parts: parts, now: at(0)); let bOn = b.dirty; let zhMem = b.badge
        b.clearDirty()
        b.setUI(UISettings(view: .cpu, language: .en), lang: .en, now: at(0.1)); let enCPU = b.badge
        b.setSimulation(parts: nil, now: at(0.2))
        expect("store.badge_localized", bOn == all && zhMem == "模擬中：交換檔、CPU 負載 讀取失敗" && enCPU == "SIM: CPU LOAD, SWAP FAILED" && b.badge == nil,
               "\(zhMem ?? "-") | \(enCPU ?? "-")")

        // region keys: only the active view's regions + shared; battery only while visible
        var ks = Snapshot.fixtureState(now: t0, view: .network, lang: .en, battery: false)
        let kN = Set(StateBuilder.regionKeys(ks).keys)
        ks.view = .cpu; ks.batteryVisible = true
        let kC = Set(StateBuilder.regionKeys(ks).keys)
        expect("statebuilder.region_keys", kN == [.chrome, .clock, .sim, .axis, .netDown, .netUp, .netPktIn, .netPktOut, .netPktInS, .netPktOutS, .netRecv, .netSent]
               && kC == [.chrome, .clock, .sim, .axis, .battery, .cpuSys, .cpuUser, .cpuIdle, .cpuThreads, .cpuProcs],
               "\(names(kN)) / \(names(kC))")

        // DSP tokens (spec §9.1): non-memory views mem_seq=- + sys_seq=; view / lang / batv tokens
        let dm = PanelView.dspBody(Snapshot.fixtureState(now: t0), seq: 3, memSeq: 41, sysSeq: 7, regions: ["used"], drawUs: 120)
        let dc = PanelView.dspBody(Snapshot.fixtureState(now: t0, view: .cpu, lang: .en, battery: false), seq: 4, memSeq: 41, sysSeq: 7,
                                   regions: ["cpuSys", "graph"], drawUs: 99)
        expect("dsp.view_tokens", dm.hasPrefix("seq=3 mem_seq=41 clock=") && dm.contains(" view=mem lang=zh batv=1 sim=0") && !dm.contains("sys_seq")
               && dc.hasPrefix("seq=4 mem_seq=- sys_seq=7 clock=") && dc.contains("regions=cpuSys,graph") && dc.contains("bat=\"hidden\"")
               && dc.contains(" view=cpu lang=en batv=0 sim=0") && !dc.contains("blank=1"), "\(dm) || \(dc)")

        // memory sampling rate: the memory view on a visible window → --mem-hz, otherwise ≤ 1 Hz
        expect("ui.mem_hz_target", AppController.memHzTarget(view: .memory, visible: true, configured: 4) == 4
               && AppController.memHzTarget(view: .cpu, visible: true, configured: 4) == 1
               && AppController.memHzTarget(view: .memory, visible: false, configured: 4) == 1
               && AppController.memHzTarget(view: .network, visible: false, configured: 2) == 1
               && AppController.memHzTarget(view: .memory, visible: true, configured: 1) == 1)

        // L3 --mem-display-hz 2: values follow .000 / .500 only (sampling stays 4 Hz)
        var cfg = Config(); cfg.memDisplayHz = 2
        let d = Store(config: cfg, startedAt: t0)
        var shown: [UInt64] = [], swapDirty: [Bool] = []
        for (i, f) in [0.0, 0.25, 0.5, 0.75, 1.0].enumerated() {
            d.apply(sample(seq: UInt64(i + 1), t: at(30 + f), swap: "\(i).0 MB"), now: at(30 + f)); shown.append(d.shownMem?.seq ?? 0)
            swapDirty.append(d.dirty.contains(.sec2)); d.clearDirty()      // a held sample must not redraw the values
        }
        expect("store.mem_display_hz", shown == [1, 1, 3, 3, 5] && swapDirty == [true, false, true, false, true] && d.latest?.seq == 5,
               "\(shown) dirty=\(swapDirty)")
        return out
    }

    static func run() -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        func expect(_ name: String, _ ok: Bool, _ d: String = "") { out.append(SelfTestCase("app.\(name)", ok, d)) }
        var cfg = Config(); cfg.pageSeconds = 8
        cfg.memDisplayHz = 4        // region diffing at the 4 Hz sampling rate (the 2 Hz default: store.mem_display_hz)
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let st = Store(config: cfg, startedAt: t0)

        // 1. first sample → every memory region dirty, strings shown verbatim
        st.apply(sample(seq: 1, t: t0), now: t0)
        var s = st.panelState(now: t0)
        expect("store.first_sample", s.memory.used == .text("18.52 GB") && s.memory.pressurePercent == 48 && !s.sampleStale,
               "used=\(StateBuilder.key(s.memory.used))")
        expect("store.first_dirty", [.used, .pressure, .sec0, .sec2, .clock].allSatisfy(st.dirty.contains), "\(st.dirty.map(\.rawValue).sorted())")
        st.clearDirty()

        // 2. only the swap string changes → only sec2 dirty (same second → clock unchanged)
        st.apply(sample(seq: 2, t: t0.addingTimeInterval(0.25), swap: "40.1 MB"), now: t0.addingTimeInterval(0.25))
        expect("store.region_diff", st.dirty == [.sec2], "\(st.dirty.map(\.rawValue).sorted())")
        st.clearDirty()

        // 3. failed field in THIS sample → "—" at once (no old value)
        st.apply(sample(seq: 3, t: t0.addingTimeInterval(0.5), used: nil), now: t0.addingTimeInterval(0.5))
        s = st.panelState(now: t0.addingTimeInterval(0.5))
        expect("store.failed_now", s.memory.used == .failed && st.dirty.contains(.used), "used=\(StateBuilder.key(s.memory.used))")
        st.clearDirty()

        // 4. staleness: > 5 s without MEM → 停滯 chip, values kept; > 10 s → every value and pressure "—"
        st.tick1Hz(now: t0.addingTimeInterval(6))
        s = st.panelState(now: t0.addingTimeInterval(6))
        expect("store.stale_chip", s.sampleStale && s.memory.physical == .text("24.00 GB") && st.dirty.contains(.clock))
        st.clearDirty()
        st.tick1Hz(now: t0.addingTimeInterval(11))
        s = st.panelState(now: t0.addingTimeInterval(11))
        expect("store.stale_blank", s.sampleStale && s.memory.physical == .failed && s.memory.pressurePercent == nil && st.dirty.contains(.sec0))
        st.clearDirty()
        st.apply(sample(seq: 4, t: t0.addingTimeInterval(11.25)), now: t0.addingTimeInterval(11.25))
        s = st.panelState(now: t0.addingTimeInterval(11.25))
        expect("store.stale_recover", !s.sampleStale && s.memory.physical == .text("24.00 GB"))
        st.clearDirty()

        // 5. history: one point per closed second; graph dirty on every tick; coverage label from start time
        expect("store.history", st.historyPoints.count >= 1 && st.dirty.isEmpty, "points=\(st.historyPoints.count)")
        st.tick1Hz(now: t0.addingTimeInterval(12.05))
        expect("store.graph_tick", st.dirty.contains(.graph))
        s = st.panelState(now: t0.addingTimeInterval(125))
        expect("store.coverage", s.historyCoverage == 125 && StateBuilder.axisLabel(s.historyCoverage) == "收集中 2/10 分鐘",
               "\(s.historyCoverage)")
        expect("store.coverage_cap", st.panelState(now: t0.addingTimeInterval(5000)).historyCoverage == 900)
        st.clearDirty()

        // 6. simulation badge on → full redraw (frame); text change → sim region only; off → full redraw
        st.setSimulation(badge: "模擬中：交換檔 讀取失敗", now: t0.addingTimeInterval(12.1))
        expect("store.sim_on_full", Set(Region.allCases).isSubset(of: st.dirty))
        st.clearDirty()
        st.setSimulation(badge: "模擬中：壓力 嚴重 90%", now: t0.addingTimeInterval(12.2))
        expect("store.sim_text", st.dirty == [.sim], "\(st.dirty.map(\.rawValue).sorted())")
        st.clearDirty()
        st.setSimulation(badge: nil, now: t0.addingTimeInterval(12.3))
        expect("store.sim_off_full", Set(Region.allCases).isSubset(of: st.dirty))
        st.clearDirty()

        // 7. battery: groups → battery dirty; paging rotates AirPods every pageSeconds, HID pinned
        st.applyBattery([kb(100), pods("A", 90), pods("B", 80)], now: t0.addingTimeInterval(13))
        s = st.panelState(now: t0.addingTimeInterval(13))
        expect("store.battery_dirty", st.dirty.contains(.battery) && StateBuilder.dspBattery(s) == "kb:100 pods[A] L:90 R:U C:40c",
               StateBuilder.dspBattery(s))
        st.clearDirty()
        st.tick1Hz(now: t0.addingTimeInterval(20))
        expect("store.page_hold", st.panelState(now: t0.addingTimeInterval(20)).batteryPage == 0)
        st.tick1Hz(now: t0.addingTimeInterval(21.1))
        s = st.panelState(now: t0.addingTimeInterval(21.1))
        expect("store.page_flip", s.batteryPage == 1 && st.dirty.contains(.battery) && StateBuilder.dspBattery(s) == "kb:100 pods[B] L:80 R:U C:40c",
               "page=\(s.batteryPage) \(StateBuilder.dspBattery(s))")
        st.clearDirty()
        st.applyBattery([kb(99)], now: t0.addingTimeInterval(22))
        s = st.panelState(now: t0.addingTimeInterval(22))
        expect("store.page_clamp", s.batteryPage == 0 && StateBuilder.dspBattery(s) == "kb:99", StateBuilder.dspBattery(s))
        st.clearDirty()
        st.applyBattery([kb(99, connected: false)], now: t0.addingTimeInterval(23))
        expect("store.offline_token", StateBuilder.dspBattery(st.panelState(now: t0.addingTimeInterval(23))) == "kb:off")
        st.applyBattery([], now: t0.addingTimeInterval(24))
        expect("store.nodev_token", StateBuilder.dspBattery(st.panelState(now: t0.addingTimeInterval(24))) == "none")

        // 8. simulated pressure sample → pressureSimulated, history point flagged
        st.apply(sample(seq: 5, t: t0.addingTimeInterval(30), pct: 92, level: .critical, simulated: true), now: t0.addingTimeInterval(30))
        st.tick1Hz(now: t0.addingTimeInterval(31.05))
        s = st.panelState(now: t0.addingTimeInterval(31.05))
        expect("store.sim_pressure", s.memory.pressureSimulated && s.memory.pressureLevel == .critical
               && (s.history.last?.simulated ?? false) && s.history.last?.percent == 92)

        // 10. app-mode 1 Hz tick grid (monotonic one-shot, re-armed per tick): +30 ms after each wall second; an early
        //     fire never repeats a second; late → skip missed; a clock step back re-grids at once (no D-second stall)
        let a = AppController.nextTick(now: 1000.5, lastBoundary: 0)
        let b = AppController.nextTick(now: 1001.031, lastBoundary: a.boundary)
        let early = AppController.nextTick(now: 1001.99, lastBoundary: 1002)
        let back = AppController.nextTick(now: 942.04, lastBoundary: 1003)
        let late = AppController.nextTick(now: 1004.5, lastBoundary: 1002)
        expect("tick.grid", a.boundary == 1001 && abs(a.delay - 0.53) < 1e-6 && b.boundary == 1002 && abs(b.delay - 0.999) < 1e-6
               && early.boundary == 1003 && !early.steppedBack && late.boundary == 1005 && !late.steppedBack
               && back.steppedBack && back.boundary == 943 && back.delay < 1.0,
               "\([a, b, early, back, late].map { "\($0.boundary)/\(String(format: "%.3f", $0.delay))/\($0.steppedBack)" })")

        // 11. OPS-5 two agreeing checks: a suspect left by an ended phase (reset on phase change) never confirms a later
        //     single observation
        var loss = ScreenLossConfirm()
        let l1 = loss.observeLost(t0)
        loss.reset()
        let l2 = loss.observeLost(t0.addingTimeInterval(3600))
        let l3 = loss.observeLost(t0.addingTimeInterval(3601.5))
        let l4 = loss.observeLost(t0.addingTimeInterval(3700)), ok4 = loss.observeOK(), ok5 = loss.observeOK()
        expect("screen_loss.confirm", !l1 && !l2 && l3 && !l4 && ok4 && !ok5 && loss.since == nil, "\([l1, l2, l3, l4, ok4, ok5])")

        // 12. focus: handed back only after a panel-started entry; the panel being frontmost keeps the earlier app
        let me: pid_t = 4242
        expect("focus.rules", AppController.restoresFocus(entryPhase: .enteringFS) && !AppController.restoresFocus(entryPhase: .windowed)
               && AppController.previousApp(front: "panel", frontPID: me, kept: "Safari", own: me) == "Safari"
               && AppController.previousApp(front: "Terminal", frontPID: 77, kept: "Safari", own: me) == "Terminal"
               && AppController.previousApp(front: nil as String?, frontPID: nil, kept: "Safari", own: me) == "Safari"
               && AppController.previousApp(front: "panel", frontPID: me, kept: nil as String?, own: me) == nil)

        // 13. pid file: launch refuses only for another LIVE WokyisPanel; exit empties the file only while it is ours
        let named: (String?) -> (pid_t) -> String? = { n in { _ in n } }
        expect("pidfile.rules", AppController.otherLivePanel(content: "456\n", own: me, name: named("WokyisPanel")) == 456
               && AppController.otherLivePanel(content: "456\n", own: me, name: named("launchd")) == nil
               && AppController.otherLivePanel(content: "456\n", own: me, name: named(nil)) == nil
               && AppController.otherLivePanel(content: "4242\n", own: me, name: named("WokyisPanel")) == nil
               && AppController.otherLivePanel(content: "", own: me, name: named("WokyisPanel")) == nil
               && AppController.pidFileOwned(content: "4242\n", own: me) && !AppController.pidFileOwned(content: "456\n", own: me)
               && !AppController.pidFileOwned(content: "", own: me)
               && AppController.processName(getpid()) != nil && AppController.processName(Int32.max - 7) == nil)

        // 14. auto-recovery decision (AppController.autoRecoverDecision, pure): every branch
        func ar(_ phase: AppController.Phase, _ reason: String = "display_changed", windowed: Bool = false, fs: Int = 0,
                present: Bool = true, stable: Double = 3.2, attempts: [Double] = [], enabled: Bool = true,
                stableS: Double = 3, now: Double = 10_000, locked: Bool = false, replay: Bool = false) -> AppController.AutoRecoverDecision {
            AppController.autoRecoverDecision(phase: phase, lastCloseReason: reason, userWindowed: windowed, fsFailures: fs,
                                              wokyisPresent: present, stableFor: stable, recentAttempts: attempts, now: now,
                                              enabled: enabled, stableSeconds: stableS, locked: locked, replay: replay)
        }
        func arExpect(_ name: String, _ d: AppController.AutoRecoverDecision, _ action: AppController.AutoRecoverDecision.Action,
                      _ reason: String? = nil, schedule: Bool? = nil) {
            expect("auto_recover.\(name)", d.action == action && (reason == nil || d.reason == reason) && (schedule == nil || d.schedule == schedule),
                   "\(d.action.rawValue)/\(d.reason)/\(d.waitS.map { String(format: "%.2f", $0) } ?? "-")")
        }
        let mono0 = 10_000.0                       // monotonic seconds (AppController.monoNow), synthetic
        let ago: (Double) -> Double = { mono0 - $0 }
        arExpect("display_changed_stable", ar(.waitingForUser), .recover, "stable", schedule: true)
        let un = ar(.waitingForUser, stable: 1.5)
        arExpect("unstable_wait", un, .wait, "unstable", schedule: true)
        expect("auto_recover.unstable_wait_s", abs((un.waitS ?? -1) - 1.5) < 1e-9, "\(un.waitS ?? -1)")
        arExpect("no_wokyis_wait", ar(.waitingForUser, present: false, stable: 60), .wait, "no_wokyis", schedule: false)
        arExpect("start_waiting_for_display", ar(.waitingForDisplay, "start"), .recover, "stable", schedule: true)
        arExpect("display_missing_unstable", ar(.waitingForDisplay, "start", stable: 0.2), .wait, "unstable", schedule: true)
        for r in ["moved_off_wokyis", "created_off_wokyis", "windowed_off_wokyis", "fs_verify_failed_off_wokyis"] {
            arExpect("eligible.\(r)", ar(.waitingForUser, r), .recover, "stable")
        }
        arExpect("fs_verify_size_never", ar(.waitingForUser, "fs_verify_failed_size_scale"), .never, "close_fs_verify_failed_size_scale", schedule: false)
        arExpect("windowed_phase_never", ar(.windowed), .never, "phase_windowed", schedule: false)
        arExpect("user_left_fs_never", ar(.waitingForUser, windowed: true), .never, "user_left_fs")
        arExpect("exiting_never", ar(.exiting), .never, "phase_exiting")
        arExpect("in_flight_never", ar(.creating), .never, "phase_creating")
        arExpect("entering_never", ar(.enteringFS), .never, "phase_enteringFS")
        arExpect("running_never", ar(.running), .never, "phase_running")
        arExpect("fs_failed_3_never", ar(.waitingForUser, "fs_failed", fs: 3), .never, "fs_failed_manual")
        arExpect("fs_failed_3_display_never", ar(.waitingForDisplay, "start", fs: 3), .never, "fs_failed_manual")
        arExpect("fs_retry_pending_never", ar(.waitingForUser, "fs_failed", fs: 1), .never, "fs_retry_pending")
        arExpect("disabled_never", ar(.waitingForUser, enabled: false), .never, "disabled", schedule: false)
        arExpect("limit", ar(.waitingForUser, attempts: [ago(500), ago(300), ago(10)]), .limit, "auto_recover_limit", schedule: false)
        arExpect("limit_slides", ar(.waitingForUser, attempts: [ago(700), ago(300), ago(10)]), .recover, "stable")
        arExpect("below_limit", ar(.waitingForUser, attempts: [ago(300), ago(10)]), .recover, "stable")
        arExpect("custom_stable", ar(.waitingForUser, stable: 5, stableS: 7.5), .wait, "unstable")
        expect("auto_recover.window_prune", AppController.attemptsInWindow([ago(601), ago(599), ago(0)], now: mono0).count == 2)
        // SM-1: a confirm check closes the window 3.0 s after the last screen event → the stable window restarts at the
        // close (wait a full 3 s through the timer), not an immediate recover in the closing run-loop turn
        let closeStable = AppController.autoRecoverStableFor(now: mono0, lastScreenEvent: mono0 - 3.0, waitEntered: mono0, lastAttempt: nil)
        let closeD = ar(.waitingForUser, stable: closeStable)
        expect("auto_recover.close_restarts_window", closeStable == 0 && closeD.action == .wait && closeD.waitS == 3,
               "\(closeStable)/\(closeD.action.rawValue)/\(closeD.waitS ?? -1)")
        expect("auto_recover.stable_for_latest", AppController.autoRecoverStableFor(now: mono0, lastScreenEvent: mono0 - 9,
                                                                                    waitEntered: mono0 - 7, lastAttempt: mono0 - 4) == 4
               && AppController.autoRecoverStableFor(now: mono0, lastScreenEvent: mono0 - 2, waitEntered: mono0 - 7, lastAttempt: nil) == 2)
        // SM-3: the attempt window and stable window are monotonic seconds; the clock itself never goes backwards
        let m1 = AppController.monoNow(), m2 = AppController.monoNow()
        expect("auto_recover.mono_clock", m2 >= m1 && m1 > 0, "\(m1)/\(m2)")
        // F1: a second automatic attempt after a failed entry (panel frontmost) keeps the app recorded by the first
        let firstRec = AppController.previousApp(front: "Music", frontPID: 77, kept: nil as String?, own: me)
        expect("auto_recover.keeps_prev_app", AppController.previousApp(front: "panel", frontPID: me, kept: firstRec, own: me) == "Music")

        // 15. lock awareness (incident logs/panel-20261002-051634.log: started while locked → 3 fs_failed → manual)
        //     locked → wait (no window, no timer; the unlock re-evaluates)
        arExpect("locked.start_wait", ar(.waitingForDisplay, "start", locked: true), .wait, "locked", schedule: false)
        arExpect("locked.deferred_wait", ar(.waitingForUser, "locked", locked: true), .wait, "locked", schedule: false)
        arExpect("locked.display_changed_wait", ar(.waitingForUser, "display_changed", locked: true), .wait, "locked", schedule: false)
        arExpect("locked.fs_failed_locked_wait", ar(.waitingForUser, "fs_failed_locked", locked: true), .wait, "locked", schedule: false)
        arExpect("locked.no_wokyis_wait", ar(.waitingForUser, "locked", present: false, locked: true), .wait, "locked", schedule: false)
        //     never-states stay never while locked (no waiting_for_unlock promise)
        arExpect("locked.user_left_fs_never", ar(.waitingForUser, windowed: true, locked: true), .never, "user_left_fs")
        arExpect("locked.manual_never", ar(.waitingForUser, "fs_failed", fs: 3, locked: true), .never, "fs_failed_manual")
        arExpect("locked.disabled_never", ar(.waitingForUser, "locked", enabled: false, locked: true), .never, "disabled")
        arExpect("locked.in_flight_never", ar(.creating, locked: true), .never, "phase_creating")
        //     non-eligible close reasons are checked before the lock (no waiting_for_unlock promise for them)
        arExpect("locked.fs_retry_pending_never", ar(.waitingForUser, "fs_failed", fs: 1, locked: true), .never, "fs_retry_pending")
        arExpect("locked.size_scale_never", ar(.waitingForUser, "fs_verify_failed_size_scale", locked: true), .never,
                 "close_fs_verify_failed_size_scale")
        //     unlock → recover through the stable window (the unlock is a screen event: stableFor restarts at 0)
        let unlockStable = AppController.autoRecoverStableFor(now: mono0, lastScreenEvent: mono0, waitEntered: ago(900), lastAttempt: nil)
        let unlockD = ar(.waitingForUser, "fs_failed_locked", stable: unlockStable)
        expect("auto_recover.locked.unlock_schedules", unlockStable == 0 && unlockD.action == .wait && unlockD.reason == "unstable"
               && unlockD.waitS == 3 && unlockD.schedule, "\(unlockStable)/\(unlockD.action.rawValue)/\(unlockD.reason)/\(unlockD.waitS ?? -1)")
        arExpect("locked.unlock_recover_deferred", ar(.waitingForUser, "locked"), .recover, "stable", schedule: true)
        arExpect("locked.unlock_recover_fs_failed_locked", ar(.waitingForUser, "fs_failed_locked"), .recover, "stable")
        arExpect("locked.unlock_recover_start", ar(.waitingForDisplay, "locked"), .recover, "stable")
        arExpect("locked.unlock_no_wokyis", ar(.waitingForUser, "locked", present: false), .wait, "no_wokyis", schedule: false)
        //     limit respected after the unlock; a slid-out attempt frees it again
        arExpect("locked.unlock_limit", ar(.waitingForUser, "fs_failed_locked", attempts: [ago(500), ago(300), ago(10)]), .limit, "auto_recover_limit")
        arExpect("locked.unlock_limit_slides", ar(.waitingForUser, "locked", attempts: [ago(601), ago(300), ago(10)]), .recover, "stable")
        //     a fs failure while locked is not counted and never retries / locks manual; 3 unlocked failures still manual
        func fsSeq(_ locks: [Bool]) -> (Int, AppController.FSFailAction?) {
            var n = 0; var last: AppController.FSFailAction?
            for l in locks { let o = AppController.fsFailureOutcome(locked: l, failuresBefore: n); n = o.failures; last = o.action }
            return (n, last)
        }
        let lk3 = fsSeq([true, true, true]), mix = fsSeq([true, false, true, false]), un3 = fsSeq([false, true, false, false])
        let un1 = fsSeq([false]), un2 = fsSeq([false, false])
        expect("auto_recover.locked.fs_failed_not_counted", lk3.0 == 0 && lk3.1 == .waitForUnlock && mix.0 == 2 && mix.1 == .retry,
               "\(lk3)/\(mix)")
        expect("auto_recover.locked.unlocked_3_manual", un1 == (1, .retry) && un2 == (2, .retry) && un3.0 == 3 && un3.1 == .manual
               && ar(.waitingForUser, "fs_failed", fs: un3.0).reason == "fs_failed_manual", "\(un1)/\(un2)/\(un3)")
        //     a request deferred by the lock (start / SIGUSR2 / fs_retry / fs failure while locked) is replayed once after the
        //     unlock: stable window kept, but independent of --auto-recover and the limit; an automatic attempt is not replayed
        expect("auto_recover.locked.replay_triggers", AppController.replaysAfterUnlock(trigger: "start")
               && AppController.replaysAfterUnlock(trigger: "sigusr2") && AppController.replaysAfterUnlock(trigger: "fs_retry_2")
               && AppController.replaysAfterUnlock(trigger: "unlock_replay") && !AppController.replaysAfterUnlock(trigger: "auto_recover"))
        arExpect("locked.replay_disabled_locked_wait", ar(.waitingForUser, "locked", enabled: false, locked: true, replay: true),
                 .wait, "locked", schedule: false)
        arExpect("locked.replay_disabled_unlock_schedules", ar(.waitingForUser, "locked", stable: 0, enabled: false, replay: true),
                 .wait, "unstable", schedule: true)
        arExpect("locked.replay_disabled_recover", ar(.waitingForUser, "locked", enabled: false, replay: true), .recover, "unlock_replay")
        arExpect("locked.replay_fs_failed_locked_recover", ar(.waitingForUser, "fs_failed_locked", enabled: false, replay: true),
                 .recover, "unlock_replay")
        arExpect("locked.replay_over_limit", ar(.waitingForUser, "locked", attempts: [ago(500), ago(300), ago(10)], replay: true),
                 .recover, "unlock_replay")
        arExpect("locked.replay_no_wokyis", ar(.waitingForDisplay, "locked", present: false, enabled: false, replay: true),
                 .wait, "no_wokyis", schedule: false)
        arExpect("locked.replay_in_flight_never", ar(.creating, enabled: false, replay: true), .never, "phase_creating")
        //     the lock flag of the CG session dictionary (absent / false / NSNumber / garbage / no dictionary)
        expect("auto_recover.locked.session_dict", AppController.sessionLocked(["CGSSessionScreenIsLocked": true])
               && AppController.sessionLocked(["CGSSessionScreenIsLocked": NSNumber(value: 1)])
               && !AppController.sessionLocked(["CGSSessionScreenIsLocked": false])
               && !AppController.sessionLocked(["CGSSessionScreenIsLocked": NSNumber(value: 0)])
               && !AppController.sessionLocked(["CGSSessionScreenIsLocked": "yes"])
               && !AppController.sessionLocked(["kCGSSessionOnConsoleKey": true]) && !AppController.sessionLocked(nil))

        out += v2Cases()

        // 9. the renderer draws a Store state without layout problems
        if let (r, _) = Snapshot.renderImage(s) {
            let p = r.layoutProblems()
            expect("store.render", p.isEmpty, p.prefix(2).joined(separator: "; "))
        } else { expect("store.render", false, "no bitmap") }
        return out
    }
}
