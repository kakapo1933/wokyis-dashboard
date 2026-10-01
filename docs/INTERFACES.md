# WokyisPanel — module interfaces and file ownership

Binding spec: `phase2/final/spec.md` (§4 signatures). This file records the **exact** signatures that exist in the
skeleton today, the extensions to §4 that the skeleton made, and who owns which file. Parallel agents edit only their
own files; a signature change that crosses an ownership line must be agreed with the lead and reflected here.

Build: `scripts/build.sh` (owner: core) compiles an explicit list — every file below already exists and compiles.
**Adding a new Swift file to the app requires a build.sh edit — ask the lead/core owner**; prefer adding code to your
existing files. `scripts/build.sh` runs `--selftest` (non-zero fails the build) and then `tools/build.sh`.
Swift 5 language mode (`-swift-version 5`), target arm64-apple-macos14.0, `-O`, frameworks AppKit/IOKit/CoreText
(CryptoKit, ImageIO, UniformTypeIdentifiers autolink). One module, so every type below is visible everywhere.

## Ownership

| Files | Owner | State |
|---|---|---|
| `Sources/Core/{SourceID,Types,Config,Injector,EventLog,Support,Headless}.swift` | core (skeleton) | implemented |
| `Sources/Render/{PanelModel,PanelRenderer}.swift` | frozen (verbatim copy of phase2/final/src) | do not edit |
| `Sources/Memory/*` | memory agent | implemented |
| `Sources/Battery/*` (incl. new `BatteryMonitor.swift`) | battery agent | implemented |
| `Sources/App/*`, `Sources/Render/StateBuilder.swift`, `Sources/Core/Store.swift`, `Sources/Evidence/*`, `scripts/*` except `scripts/build.sh` | app agent | implemented |
| `scripts/build.sh`, `tools/build.sh`, `tools/mockup_measure.sh`, `tools/mockup_summarize.py`, `Resources/Info.plist` | core | implemented |
| `tools/src/{AMCompare,EdgeCheck,WinList,LogStats}.swift` + `tools/src/AMCompare+{AX,DryRun,Logic,PanelGate,Run,Vision}.swift`, `tools/{c2measure,c7_measure,injectdemo,linkcheck,selftest,wokyis_shot}.sh`, `tools/fixtures/sp_sample.json` | tools agent | implemented (built by `tools/build.sh` → `tools/bin/{amcompare,edgecheck,winlist,logstats}`; `tools/selftest.sh` runs at the end of `tools/build.sh`, `TOOLS_SELFTEST=0` skips it) |
| `tools/src/{Common,GlyphHeight,FontCal,OCR,ProcStat,Composite,Mockup}.swift`, `tools/capture_pair.sh`, `tools/README.md` | copied from phase 1/2 (capture_pair.sh now calls `tools/bin/composite`) | tools agent may extend README |

`tools/build.sh` builds `amcompare edgecheck winlist logstats` automatically as soon as `tools/src/<Tool>.swift`
exists, from `src/Common.swift src/<Tool>.swift src/<Tool>+*.swift` with `-parse-as-library` (so each tool needs its
own `@main`, and must not redefine `Common.swift` symbols: `ToolError die isoNow Bitmap loadCGImage writePNG PixRect
parseRect clamp InkResult borderBackground measureInk measureLines drawText strokeRectTop rgba Args`).

## Threads (spec §3)

memQ (sampler, serial .utility) · batQ / spQ (battery, serial .utility) · ctlQ (Injector, private) · logQ (EventLog,
private) · main (Store, PanelView, AppController, 1 Hz tick). Only value types cross threads. Callbacks documented as
"on main" must be delivered on `DispatchQueue.main`.

---

## Core (owner: core — implemented)

### SourceID.swift
```swift
enum SourceID: String, CaseIterable, Sendable {
  case memPhysical = "mem.physical", memVM = "mem.vm", memSwap = "mem.swap", memLevel = "mem.level",
       memPressure = "mem.pressure", memAudit = "mem.audit", batHID = "bat.hid", batIOPS = "bat.iops", batSP = "bat.sp"
  var badgeName: String                    // 實體記憶體 / 記憶體計數 / 交換檔 / 壓力值 / 壓力等級 / 稽核 / HID / AIRPODS 電量 / 藍牙連線
}
enum SourceError: Error, Sendable, Equatable {
  case injected(String), errno(Int32, String), kern(Int32), subprocess(Int32), timeout, parse(String), missingSymbol(String)
  var logToken: String                     // injected | errno=2 | kr=5 | rc=1 | timeout | parse | missing_symbol  (ERR err=…)
  var isInjected: Bool
}
enum Field: String, CaseIterable, Sendable { case physical, used, cached, swap, app, wired, compressed }
```

### Types.swift (shared value types)
```swift
enum FreeMode: String, Sendable { case mte, calibrated }
struct MemoryBytes: Sendable { var v: [Field: Int64?]; init(v: [Field: Int64?] = [:])
                               subscript(_ f: Field) -> Int64? { get set }   // nil = failed or absent
                               static let allFailed: MemoryBytes }
struct MemSample: Sendable { let seq: UInt64; let tWall: Date; let durUs: Int; let bytes: MemoryBytes
                             let strings: [Field: String?]; let pressure: (pct: Int, level: PressureLevel)?
                             let simulated: Bool; let failed: [String]; let mode: FreeMode }       // memberwise init
struct AuditResult: Sendable { let fresh: Bool; let sameAsPrev: Bool; let ageMs: Int?; let diffPages: [Field: Int]; let freeErrPages: Int }
struct HIDDevice: Sendable { let address: String; let name: String; let category: String; let percent: Int; let statusFlags: Int? }
enum PodPart: String, Sendable { case left, right, `case`, single }
struct AccPart: Sendable { let groupKey: String; let name: String; let accessoryID: String; let part: PodPart; let percent: Int; let charging: Bool
                           var sourceID: Int? = nil; var entryPart: String? = nil }   // IOPS "Power Source ID" / entry "Part Identifier" (「附近」 change detector only)
struct BTDevice: Sendable { let name: String; let address: String; let minorType: String?; let productID: String?
                            let connected: Bool; let levels: [String: Int] }   // "Main"/"Left"/"Right"/"Case"
struct WokyisScreen { let screen: NSScreen; let displayID: CGDirectDisplayID; let appKitFrame: NSRect; let cgBounds: CGRect }
struct SelfTestCase: Sendable { let name: String; let ok: Bool; let detail: String; init(_ name: String, _ ok: Bool, _ detail: String = "") }
```
Render-side value types used across modules live in the frozen `Sources/Render/PanelModel.swift`:
`PressureLevel(normal=1, warning=2, critical=4; init(kernel:); word)`, `PressureSample`, `Shown`, `MemoryDisplay`,
`DeviceKind`, `CellState`, `BatteryCell`, `Presence` (connected | nearby | offline), `DeviceGroup` (stored `presence`; computed
`connected` = presence == .connected and `showsCells` = presence != .offline; extension `init(kind:name:ownerTag:connected:cells:)`
kept for two-state callers), `PanelState`; and in `PanelRenderer.swift`: `Region`, `Layout`,
`Theme`, `PanelRenderer` (`draw(_:_:only:)`, `specs`, `boxes`, `layoutProblems()`, `static pages(_:)`).

### Config.swift
```swift
enum LogLevel: String, Sendable { case summary, sample }
struct Config: Sendable, Equatable {
  var logDir = "logs", runDir = "run", memHz = 4.0, auditHz = 0.2, spPeriod = 20.0, spPath = "/usr/sbin/system_profiler"
  var breakMIBs: [String] = [], displayID: UInt32? = nil, focusRestore = true, hidTrustNotify = false
  var autoRecover = true, autoRecoverStableSeconds = 3.0      // --auto-recover yes|no, --auto-recover-stable-seconds 0.5…60
  var offlineGrace = 600.0, pageSeconds = 8.0, selftest = false, snapshotOut: String? = nil, dumpRects = false
  var logLevel: LogLevel = .summary, summarySeconds = 10.0, headless = false, duration: Double? = nil, args: [String]
  enum Mode: String { case app, headless, selftest, snapshot }; var mode: Mode
  static func parse(_ argv: [String]) throws -> Config      // throws Config.ParseError(description:); "help" for -h/--help
  static let usage: String
  var logDirURL: URL; var runDirURL: URL                  // relative → cwd; if cwd == "/" (LaunchServices) → <bundle>/../..
  static func resolve(_ p: String) -> URL
}
enum ConfigSelfTest { static func run() -> [SelfTestCase] }
```
Flags: `--log-dir --run-dir --mem-hz(1…10) --audit-hz(0…10, ≤mem-hz) --sp-period(5…3600) --sp-path --break-mib(repeatable)
--display-id --no-focus-restore --auto-recover yes|no --auto-recover-stable-seconds(0.5…60) --hid-trust-notify yes|no --offline-grace --nearby-fresh-seconds(0…86400, 0 = no 「附近」) --page-seconds --log-level summary|sample
--summary-seconds --headless --duration(only with --headless) --selftest --snapshot OUT.png --dump-rects(only with --snapshot)`.
Unknown flag → exit 64 with usage; `-psn_…` ignored.

### Injector.swift (spec §11)
```swift
enum InjectMode: Sendable { case none, hang, garbage }
final class Injector: @unchecked Sendable {
  init(runDir: URL, log: EventLog?)
  func start()                                   // first read is synchronous; then vnode(run dir) + 1 s stat on ctlQ
  func stop()
  func check(_ id: SourceID) throws              // id ∈ fail → throw SourceError.injected(id.rawValue). FIRST line of every read()
  func checkMIB(_ name: String) throws           // "mem.mib:<name>" ∈ fail → throw .injected("mem.mib:<name>")
  func mode(_ id: SourceID) -> InjectMode        // hang only bat.sp; garbage only bat.sp / bat.iops; hang wins
  var pressureOverride: (level: PressureLevel, percent: Int)? { get }
  var badge: String? { get }                     // nil = nothing active; "模擬中：交換檔、HID 讀取失敗；藍牙連線 逾時；壓力 警告 71%"
  var active: Bool { get }
  var generation: UInt64 { get }                 // +1 per state change (Store: full redraw when the sim frame toggles)
  func snapshot(now: Date = Date()) -> Injector.Snapshot   // expired → .empty even before ctlQ notices
  @discardableResult func apply(_ data: Data?, now: Date, reasonIfNil: String? = nil) -> Injector.Outcome
  static func parse(_ data: Data?, now: Date, reasonIfNil: String? = nil) -> (Snapshot, Outcome)
  static func describe(_ s: Snapshot) -> String  // "fail=mem.swap pressure=4/92 expires=…" (CTL state=, status.sh)
}
enum InjectorSelfTest { static func run() -> [SelfTestCase]; static func runLive(dir: URL) -> [SelfTestCase] }
```
Rules: `version` must be 1; `expires` required when anything is injected; > now+900 s → clamped (`WARN ctl_expires_clamped`);
past → `CTL expired`; `{}`/missing → cleared; parse error, version≠1, unknown key, unknown id, hang≠bat.sp,
garbage∉{bat.sp,bat.iops}, pressure level∉{1,2,4} or percent∉0…100 → cleared + `CTL invalid reason=…`.
Log lines written by the Injector: `CTL state="…"`, `CTL state="none" why=missing|empty`, `CTL invalid reason="…"`,
`CTL expired`, `WARN ctl_expires_clamped`. `scripts/sim.sh` must write `control.json` via temp file + `mv`.

### EventLog.swift (spec §12 + D4)
```swift
final class EventLog: @unchecked Sendable {
  init(dir: URL, level: LogLevel = .summary, summarySeconds: Double = 10, rotateBytes: Int = 64 << 20,
       echoStdout: Bool = true, now: Date = Date()) throws
  var simActive: @Sendable () -> Bool            // set once at start: { injector.active } → " sim=1" appended to lines without sim=
  func line(_ kind: String, _ body: String, at: Date = Date())    // file only (level filter)
  func event(_ kind: String, _ body: String, at: Date = Date())   // file + stdout (MEM/DSP/AUD/BAT never echoed)
  func summary(_ s: String, at: Date = Date())    // stdout only "HH:MM:SS SUM <s>", ≤ 1 per summarySeconds (call it at 1 Hz)
  func flushSync()                                // drain logQ + fsync
  var currentFile: URL { get }
  func stats() -> (written: [String: Int], dropped: [String: Int], bytes: Int64)
  static func timestamp(_ d: Date) -> String      // e.g. YYYY-MM-DDTHH:MM:SS.mmm+08:00 (local, thread-safe)
  static func hms(_ d: Date) -> String            // 05:07:13
  static func compactStamp(_ d: Date) -> String   // 20261001-050713
  static func q(_ s: String) -> String            // "quoted value" (inner " → ')
}
enum EventLogSelfTest { static func run(dir: URL) -> [SelfTestCase] }
```
Line = `<timestamp> <KIND> <body>\n`, one `write(2)` per line on logQ. Pass `at:` = sample START time for MEM.
Files `logs/panel-YYYYMMDD-HHMMSS.log`, then `-001.log`, `-002.log` … at 64 MB; `logs/current.log` → relative symlink;
nothing is ever deleted; `WARN log_dir_mb=` when logs/ > 1 GB (start + hourly).
**Levels (D4)**: `summary` (default) → MEM kept only when ≥ summarySeconds after the last kept MEM (by `at`), DSP dropped,
AUD ≤ 1 per 60 s, every other kind kept. `sample` → everything.
Measured (README §4.5): summary ≈ 5.3 MB/day with keyboard + trackpad, sample ≈ 101 MB/day without DSP, ≤ 180 MB/day with DSP. Original estimate: summary ≈ 5–10 MB/day (MEM 8 640 × ~330 B ≈ 2.9 MB,
AUD 1 440 × ~120 B, HIST/HEALTH, BAT/SP depending on how often battery lines are written); sample ≈ 170–200 MB/day
(MEM 4 Hz ≈ 114 MB, DSP ≤ 4 Hz ≈ 52 MB, AUD 0.2 Hz ≈ 2 MB, plus events).

### Support.swift
```swift
enum StartInfo { static let launchedAt: Date; static let buildHash: String
                 static func startBody(config: Config, mode: Config.Mode, selftest: String, mibs: String) -> String }
enum SummaryFormat { static func body(sample: MemSample?, groups: [DeviceGroup], sim: Bool) -> String }
     // used="18.52 GB" press=48%/1 swap="39.8 MB" kb=100 tp=85 mouse=- airpods=100/97/48c mode=mte sim=0  (cells: N, Nc, fail, na, off, -)
enum ProcessHealth { struct Sample { let cpuSeconds: Double; let footprintMB: Double; let rssMB: Double }
                     static func sample() -> Sample? }       // proc_pid_rusage(self), CPU includes reaped children
```

### Headless.swift (D5)
```swift
final class HeadlessRunner: @unchecked Sendable { init(config: Config, log: EventLog, injector: Injector, table: SysctlTable)
                                                  func start(); func shutdown(reason: String) }
enum Headless { static func run(config: Config) -> Never }
```
`--headless [--duration S]`: EventLog + Injector + `MemorySampler` + `BatteryMonitor`, main thread runs `CFRunLoopRun()`
(no NSApplication, no Dock icon; main-queue blocks and main-run-loop sources work). Writes START, SUM (stdout),
HIST and HEALTH (every 60 s), STOP. Exits 0 on duration / SIGINT / SIGTERM / SIGHUP (SIGHUP inherited as ignored — nohup —
stays ignored); a second SIGINT → 130.

---

## Memory (owner: memory agent — implemented)

```swift
// SysctlTable.swift  (every name resolved once with sysctlnametomib; per-MIB failure isolation)
struct SysctlTable: Sendable {
  static let standardNames: [String]            // the 20 scalar MIBs of §5.2 incl. hw.pagesize (vm.swapusage read separately)
  static let swapName = "vm.swapusage"
  let names: [String]; let broken: Set<String>
  init(names: [String], broken: Set<String>)    // broken: --break-mib → resolve "bogus.<name>" (real ENOENT); also applies to vm.swapusage
  var resolvedCount: Int { get }                // START line mibs=resolved/total (names only, not vm.swapusage)
  var unresolved: [String] { get }              // names (+ vm.swapusage) that failed to resolve
  func read(_ name: String) -> Result<Int64, SourceError>      // .errno(e, name) when unresolved / sysctl fails
  func readSwapUsed() -> Result<Int64, SourceError>             // xsw_usage.xsu_used
}
// MemoryFormulas.swift  (pure)
enum MemoryFormulas {
  static let noResidual = Int64.min             // "no calibrated residual yet"
  static let fBase, fMTE, eNames, uNames, iNames, wNames, cNames: [String]; static let levelName, pressureName: String
  static func compute(raw: [String: Result<Int64, SourceError>], memsize: Result<Int64, SourceError>,
                      swap: Result<Int64, SourceError>, mode: FreeMode, residualPages: Int64,
                      previous: MemoryBytes?) -> (MemoryBytes, warnings: [String])   // raw must contain "hw.pagesize"
  static func pressure(level:kernelPressure:) -> (pct: Int, level: PressureLevel)?   // clamp(100 − level, 0, 100)
}
// MemorySampler.swift
final class MemorySampler: @unchecked Sendable {
  init(hz: Double, auditHz: Double, table: SysctlTable, injector: Injector, log: EventLog, audit: HostAudit = HostAudit(),
       onSample: @escaping @Sendable (MemSample) -> Void)          // onSample is called on memQ; the consumer hops to main
  let memQ: DispatchQueue                                           // serial .utility
  func start(); func stop()                                         // after stop() returns no more onSample calls; never call stop() on memQ
  func sampleNow()                                                  // wake from sleep: one extra sample ASAP (grid unchanged)
  func stats() -> (samples: UInt64, lateP99Ms: Double?, lateMaxMs: Double?, mode: FreeMode)   // for HEALTH timer_late_p99_ms
  static func memBody(_ s: MemSample, injectorActive: Bool) -> String                        // MEM line body
}
// HostAudit.swift — the only host_statistics64 caller
struct HostVM: Sendable, Equatable { free, speculative, internalPages, external, wire, purgeable, compressor: Int64
                                     faults, lookups, zeroFill, pageins: UInt64 }
final class HostAudit { init(host: @escaping () -> Result<HostVM, SourceError> = HostAudit.liveHost)   // fake host in selftest
  static func liveHost() -> Result<HostVM, SourceError>
  func run(snapshot: () -> [String: Result<Int64, SourceError>]) -> AuditResult?   // nil = host call failed (lastError)
  private(set) var mode: FreeMode; private(set) var residualPages: Int64            // noResidual until the first adopted audit
  private(set) var lastError: SourceError?; private(set) var lastSwitch: ModeSwitch?; private(set) var lastFreeErr: Int?
  var windowMedian: Int? }
// AMFormat.swift
enum AMFormat { static func string(_ bytes: Int64) -> String; static let selfTestCases: [(Int64, String)] }   // 13 cases of §5.3
enum MemorySelfTest { static func run() -> [SelfTestCase] }  // pure: AMFormat 13, sysctl resolve/break-mib, formulas, dependencies,
                                                             // MTE fallback, guards, pressure, history, audit (fake host), MEM line
// PressureHistory.swift
struct PressureHistory { static let capacity = 900; init()
  mutating func add(pct: Int?, level: PressureLevel?, simulated: Bool, wallSecond: Int)  // same second: max / most severe / OR
  mutating func closeThrough(wallSecond: Int)       // 1 Hz tick: close the open second if older than wallSecond
  func points() -> [PressureSample]                  // closed seconds, oldest first, t = wall second
  var coverageSeconds: Double { get } }              // last.t − first.t + 1 of stored points, ≤ 900 (Store uses min(now−start, 900))
```
Semantics the consumers rely on:
- `MemSample.simulated` = the **pressure** of this sample is simulated (override active, or pressure/level failed by
  injection) → magenta history strip. The frame/badge come from `injector.badge`, not from this flag.
- Injection mapping: `mem.physical` → hw.memsize; `mem.vm` → every scalar `vm.*` MIB (NOT vm.swapusage, which is `mem.swap`);
  `mem.level` → kern.memorystatus_level; `mem.pressure` → kern.memorystatus_vm_pressure_level; `mem.mib:<name>` → that MIB;
  `mem.audit` → the audit only. `MemSample.failed` lists injected ids as given and real failures as `mem.mib:<name>`.
- The audit reads REAL sysctl values (no injection) and runs on the first tick and then every round(memHz/auditHz) ticks.

Log lines owned by the memory module:
```
MEM seq=… dur_us=… mode=mte|calibrated sim=0|1 phys=<bytes> "<AM string>" used=… cached=… swap=… app=… wired=… comp=… pct=48 lvl=1 [psim=1] fail=-|id,id
    failed field → `<key>=- "—"`; failed pressure → `pct=- lvl=-`; every sample via log.line (summary level decimates)
AUD fresh=0|1 same=0|1 age_ms=-|N d_used=… d_cached=… d_app=… d_wired=… d_comp=… free_err=-|N mode=… resid=-|N win_med=-|N
    d_* = host AM formula − sysctl formula on (A+B)/2 (pages, used with the current mode's F); '-' when not adopted
ERR src=<mem.* id> err=<logToken> [mib=<name>]            onset / token change (event); + ` repeat=1 n=… for_s=…` every 60 s (line)
RECOVER src=<id> [mib=<name>] failed_s=… n=…               failure cleared (event)
WARN guard_hold field=used|app | free_fallback reason=mte_mib_missing|mte_mib_missing_no_residual|calibrated_no_residual
     (each key at most once per 60 s, ` suppressed=N`) | free_mode from=… to=… median=… reason=median|mib_missing
     | mib_unresolved names=… broken=… | break_mib_unknown names=… | pagesize_fallback …
```

## Battery (owner: battery agent — implemented)

```swift
// HIDSource.swift   (§4 extension: injector parameter added)
final class HIDSource { init(queue: DispatchQueue, injector: Injector, onChange: @escaping @Sendable () -> Void)
                        func read() throws -> [HIDDevice]; func stop() }
// AccessorySource.swift   (§4 extension: init(injector:), removeNotifications())
final class AccessorySource { init(injector: Injector); func read() throws -> [AccPart]
                              func installNotifications(onMain: @escaping () -> Void)   // call on main; sources on MAIN run loop
                              func removeNotifications() }
// BTProfilerSource.swift   (§4 extension: cancel(), childPID)
final class BTProfilerSource { init(path: String, queue: DispatchQueue, injector: Injector)
  func poll(completion: @escaping @Sendable (Result<[BTDevice], SourceError>, _ ms: Int) -> Void)   // completion on `queue`
  func cancel(); var childPID: pid_t? { get } }
// BatteryAggregator.swift   (§4 extension: init(offlineGrace:hidTrustNotify:nearbyFresh:log:); nearbyFresh defaults to 300 s)
final class BatteryAggregator { init(offlineGrace: TimeInterval, hidTrustNotify: Bool, nearbyFresh: TimeInterval = 300, log: EventLog?)
  func merge(hid: Result<[HIDDevice], SourceError>, acc: Result<[AccPart], SourceError>,
             sp: (devices: [BTDevice], at: Date)?, spLastError: SourceError?, now: Date) -> [DeviceGroup] }
enum BatterySelfTest { static func run() -> [SelfTestCase] }       // --selftest hook (sp fixture parsing, merge, ordering…)
// BatteryMonitor.swift   (NEW, not in §4: the batQ/spQ scheduler shared by the app and --headless)
final class BatteryMonitor { init(config: Config, injector: Injector, log: EventLog,
                                  onGroups: @escaping @Sendable ([DeviceGroup]) -> Void)   // onGroups delivered on MAIN
  func start()              // call on main (installs IOPS run-loop notifications)
  func stop()               // timers off, notifications removed, running system_profiler killed and reaped
  func pollNow(reason: String) }
```
Log lines owned by the battery module: `BAT`, `SP`, `DEV`, `ERR src=bat.*`. `DeviceGroup` arrays are already ordered
and carry `ownerTag` and `presence`; offline grace, connection truth and the 「附近」 (nearby) state are decided in the
aggregator (rule: README §8.5.1).

## App (owner: app agent — implemented)

```swift
// Core/Store.swift  (main only; §4 extension: `now:` overloads, simulation badge, accessors)
final class Store { init(config: Config, startedAt: Date = Date())
  func apply(_ m: MemSample); func apply(_ m: MemSample, now: Date)                 // history.add + region diff
  func applyBattery(_ groups: [DeviceGroup]); func applyBattery(_ groups: [DeviceGroup], now: Date)   // page set change → page 0
  func setSimulation(badge: String?, now: Date = Date())                               // frame on/off → full redraw
  func tick1Hz(now: Date)          // history.closeThrough, AirPods page rotation (config.pageSeconds), .graph always dirty
  func panelState(now: Date) -> PanelState    // stale > 5 s (chip), blank > 10 s (7 values + pressure "—"), coverage = min(now−start, 900)
  func markAll(); func clearDirty(); private(set) var dirty: Set<Region>
  var staleAfter = 5.0, blankAfter = 10.0; private(set) var latest: MemSample?, groups: [DeviceGroup], badge: String?, samples: UInt64
  var historyPoints: [PressureSample]; func isStale(now:) -> Bool; func isBlank(now:) -> Bool }
// Render/StateBuilder.swift  (pure)
enum StateBuilder { static func placeholder(now: Date) -> PanelState; static let blankMemory: MemoryDisplay
  static func memory(_ m: MemSample) -> MemoryDisplay            // nil string in THIS sample → .failed
  static func regionKeys(_ s: PanelState) -> [Region: String]    // a region is redrawn when its key changes; .chrome = sim frame flag
  static func axisLabel(_ coverage: Double) -> String; static func deviceSignature(_:) -> String
  static func dspBattery(_ s: PanelState) -> String }            // "kb:100 tp:85 L:100 R:97 C:48c" (page shown; F/U/S/off/none; kb[TAG]: / pods[TAG] when a kind is shown twice)
enum AppSelfTest { static func run() -> [SelfTestCase] }         // 56 app.* cases in --selftest (Store/StateBuilder, tick, screen loss, focus, pid file, 30 auto_recover)
// App/DisplayLocator.swift
enum DisplayLocator { static func locate(override: CGDirectDisplayID?) -> WokyisScreen?   // §9.1 order; override is strict
  static func displayID(of: NSScreen) -> CGDirectDisplayID?; static func describe(_:) -> String; static func signature() -> String }
// App/PanelView.swift
final class PanelView: NSView { let renderer: PanelRenderer; var log: EventLog?; var visibleOnScreen: Bool
  func update(_ s: PanelState, dirty: Set<Region>); func update(_ s: PanelState, dirty: Set<Region>, memSeq: UInt64?)
      // setNeedsDisplay(Layout.region[r]); .chrome → whole view; nothing while !visibleOnScreen (occluded)
  override func draw(_ dirtyRect: NSRect)     // regions ∩ rects being drawn → renderer.draw(ctx, s, only:) (+ sim frame); DSP line
  private(set) var drawnState: PanelState?, drawnMemSeq: UInt64?, dspSeq: UInt64, draws: UInt64
  func takeDrawStats() -> (draws: UInt64, avgMs: Double?) }
// App/AppController.swift  (§9.2 state machine: waitingForDisplay/creating/enteringFS/running/windowed/waitingForUser/exiting)
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate { init(config: Config, log: EventLog, injector: Injector)
  // auto-recovery (pure, selftested as app.auto_recover.*): waitingForDisplay, or waitingForUser closed by display_changed /
  // moved_off_wokyis / created_off_wokyis / windowed_off_wokyis / fs_verify_failed_off_wokyis, Wokyis located, screen
  // configuration unchanged ≥ stableSeconds since the latest of the last screen event, entering the waiting phase and the last
  // automatic attempt (autoRecoverStableFor; monotonic seconds from monoNow = CLOCK_MONOTONIC) → tryCreate("auto_recover")
  // (prevApp kept: previousApp rule, as fs_retry).
  // never: disabled, other phases (windowed / creating / enteringFS / running / exiting), user left full screen (until
  // SIGUSR2 / green-button re-entry), fs_failed (retries pending, or fsFailures ≥ 3 → manual); ≤ 3 attempts per 600 s.
  static func autoRecoverDecision(phase: Phase, lastCloseReason: String, userWindowed: Bool, fsFailures: Int, wokyisPresent: Bool,
      stableFor: Double, recentAttempts: [Double], now: Double, enabled: Bool, stableSeconds: Double) -> AutoRecoverDecision
  static func autoRecoverStableFor(now: Double, lastScreenEvent: Double, waitEntered: Double, lastAttempt: Double?) -> Double
  static func monoNow() -> Double
  struct AutoRecoverDecision { enum Action { case never, wait, recover, limit }; action; reason: String; waitS: Double?; var schedule: Bool }
  static let autoRecoverLimit = 3, autoRecoverWindow: TimeInterval = 600; static func attemptsInWindow(_: [Double], now: Double) -> [Double] }
// App/Signals.swift
final class Signals { init(queue: DispatchQueue = .main, handler: @escaping (Int32) -> Void)
  func install(_ sigs: [Int32]); func cancel(); static func name(_ s: Int32) -> String }   // 2nd SIGINT → _exit(130)
// App/main.swift: SIGPIPE ignored; parse Config; selftest / snapshot / headless / app (EventLog, Injector, START,
//   NSApplication .regular, beginActivity(.userInitiatedAllowingIdleSystemSleep), AppController).
// Evidence/Snapshot.swift — unchanged API (render / renderImage / stateJSON / fixtureState / offscreenState / runOffscreen);
//   the live SIGUSR1 path renders the last drawn state (or the Store state while occluded / before the first draw).
// Evidence/SelfTest.swift — runAll / runQuick (unchanged).
```
App log lines: `WIN event=display_found|display_missing|window_created|enter_fs|did_enter_fs|focus_restored|focus_restore|
fs_failed|exit_fs|user_exit_fs|visible|occluded|display_changed|wokyis_lost|closed|wrong_screen|sigusr2|exiting|wake|sleep|phase|
auto_recover_config|auto_recover_scheduled|auto_recover|auto_recover_cancelled|auto_recover_wait|auto_recover_off`
(`closed why=fs_verify_failed cause=off_wokyis|size_scale`; `auto_recover_scheduled stable_s= in_s= phase= close_reason= trigger=` — always before an attempt; `in_s=0.00` when the stable
window had already elapsed at that evaluation,
`auto_recover attempt=n trigger=screen_check|timer|phase phase= close_reason= stable_s=`; over the limit
`ERR src=window err=auto_recover_limit n= window_s=600 action=wait_for_sigusr2`, once per waiting episode)
(`visible`/`occluded` carry `occluded=0|1` for logstats), `DSP seq= mem_seq= clock= regions=all|used,… bat="…" page=n/N
stale=0|1 [blank=1] draw_us= sim=`, `SNAP path= source=drawn|store dsp_seq= mem_seq= layout_problems=`,
`HIST n= span_s= coverage_s= gaps= nil_points= sim_points=` and `HEALTH … draws= draw_ms_avg= timer_late_p99_ms= occluded= phase=`
(every 60 s), `STOP reason= uptime_s= samples= draws= sp_child_at_stop=`.
Scripts (bash 3.2, `scripts/_common.sh` shared): `start.sh [--bg] [-- args]`, `stop.sh`, `status.sh`, `logs.sh`,
`sim.sh fail|hang|garbage|pressure|clear|status` (each command replaces control.json atomically; --for ≤ 900 s),
`snapshot.sh` (SIGUSR1), `fullscreen.sh` (SIGUSR2). The pid file (`run/panel.pid`, emptied at exit, never deleted) is
written by the app path; headless does not write it. App-mode launch refuses (`ERR src=pidfile err=already_running pid=
action=exit`, `STOP reason=already_running`, exit 1) while the file names another live WokyisPanel; exit empties the file
only while it still holds the panel's own pid (else `WARN pidfile_kept content= own=`). The app 1 Hz tick is a monotonic
one-shot re-armed per wall second (+30 ms); a clock step back re-grids it (`WARN clock_step src=tick dir=back by_s= regrid=1`).
`WIN event=focus_restore skipped=1 reason=user_toggle` = a user green-button re-entry from windowed (no focus hand-back;
the recorded previous app is one-shot). BAT lines of stale AirPods groups carry `sp_age_s=` outside the compared detail
(it rides on the forced 15 s BAT line, never one line per second).
