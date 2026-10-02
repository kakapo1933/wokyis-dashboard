# Verification tools (Wokyis dashboard)

Swift 6.3.3 (`-parse-as-library`), Apple frameworks only (CoreGraphics / ImageIO / CoreText / AppKit fonts / Vision / libproc). No network, no sudo, no third-party code.
Build: `tools/build.sh` (also run at the end of `scripts/build.sh`) → binaries in `tools/bin/` (gitignored):
- `glyphheight fontcal ocr procstat composite`: `swiftc -O -parse-as-library src/Common.swift src/<Tool>.swift -o bin/<tool>`
- `mockup`: `Sources/Render/{PanelModel,PanelRenderer,PanelRenderer+Views,L10n}.swift src/Mockup.swift` (the app's renderer, unmodified)
- `amcompare edgecheck winlist logstats`: built when `src/<Tool>.swift` exists, from `src/Common.swift src/<Tool>.swift src/<Tool>+*.swift`

Sources `src/Common.swift GlyphHeight.swift FontCal.swift OCR.swift ProcStat.swift Composite.swift` are the Phase 1 tools copied unchanged;
`src/Mockup.swift` is the v2 (spec r2) mockup driver: 3 views × zh/en × battery column on/off. `capture_pair.sh` now calls `tools/bin/composite`.

Offscreen layout check (criterion #2, offscreen part):
```
tools/bin/mockup render DIR [FILTER]   # 12 combos × typ/worst_p1/worst_p2(battery only)/failed_sim/collect_stale_nodev/nearby_huge = 66
                                       # states → DIR/mockup_<view>_<lang>_<bat|full>_<state>.png + DIR/data/*.{rects,boxes}.tsv +
                                       # DIR/data/layout_report.txt; per state: layoutProblems(), region redraw == full frame,
                                       # measure=false == measure=true (exit 1 if any problem)
tools/bin/mockup check                 # SecondRing.put, badge whole-item collapse, digit guard (11 PASS lines)
tools/bin/mockup bench [--measure]     # CPU ms per draw (full / values / graph / clock / battery) per combo
tools/bin/mockup fmt                   # speed / file / percent / compact boundary strings
tools/mockup_measure.sh DIR            # glyphheight on every mockup with its own rects → DIR/data/*.glyph.tsv, DIR/annotated/*.png
python3 tools/mockup_summarize.py DIR  # per-element min/max ink height table
tools/golden_pin.sh [--check] [--out DIR]   # frozen v1 vs current renderer on 21 golden states + app_golden; re-pins
                                       # Sources/Evidence/GoldenPin.swift only when RGBA + ink boxes agree everywhere
```

| tool | purpose | acceptance criterion |
|---|---|---|
| `glyphheight` | ink bounding box (glyph height/width in px) inside rects of a PNG, pass/fail, annotated PNG | #2 |
| `fontcal` | offscreen 1x font calibration: pt → px ink height, min pt for a px target, string widths | #2 (layout budget) |
| `ocr` | Apple Vision text recognition with pixel boxes (en-US + zh-Hant) | #4, #5 (read numbers from AM / panel screenshots) |
| `procstat` | CPU% (one core, from cumulative CPU time) + phys_footprint/RSS of a process tree, CSV | #7 |
| `composite` + `capture_pair.sh` | one `screencapture` call for both displays → side-by-side PNG with timestamps | #1, #4 |

## glyphheight

```
glyphheight IMAGE.png --rect x,y,w,h[:label[@minpx]] [--rect ...] [--lines] [--gap N] [--threshold N] [--min N] [--out annotated.png]
```
- Coordinates are image pixels, origin top-left. A Wokyis capture (`screencapture -x -D 2 f.png`, or the 2nd file of `screencapture -x a.png b.png`) is 1280×720 = 1:1 screen pixels.
- Background = most frequent colour on the rect's 1-px border → draw each rect with padding around the text, not through glyphs, and not over other UI elements (a bar/gauge inside the rect counts as ink).
- Ink = pixel whose max(|ΔR|,|ΔG|,|ΔB|) vs background ≥ threshold; default threshold adaptive = 50 % of the max contrast in the rect (edge at ~50 % anti-alias coverage). Accuracy verified ±1 px on anti-aliased bars of known fractional height (`fontcal selftest`).
- `--lines` splits the rect into text lines (ink rows separated by ≥ `--gap` empty rows) and reports each.
- Output TSV: `label line rect ink_x ink_y ink_w ink_h bg_rgb threshold max_contrast min_h result`; exit 1 if any rect with a minimum FAILs (or has no ink).
- `--out` draws: yellow = measured rect, green/red box = ink bbox (pass/fail), tick marks at the top & bottom ink rows, `label: h=NNpx ≥64 OK`.

Example (criterion #2):
```
glyphheight wokyis.png --rect 20,20,420,120:MemoryUsed@64 --rect 20,150,300,60:label@32 --out out/annotated.png
```

## fontcal

```
fontcal report [--digits 64] [--labels 32] [--sheet out.png]   # markdown tables
fontcal minsize --font sfmono-semibold --text "18.52 GB" --target 64
fontcal measure --font pingfang-medium --size 34 --text "已使用記憶體"
fontcal render  --font sf-bold --size 87 --text "100%" --out x.png [--fg FFFFFF --bg 000000 --yoff 0.25]
fontcal fonts | fontcal selftest [--out bars.png]
```
Font keys: `sf-<w>` (= SwiftUI `.system(size:weight:)`), `sfmono-<w>` (monospaced digits), `sfround-<w>` (`design: .rounded`), `pingfang-<regular|medium|semibold>` (PingFang TC). Heights are the worst case over 4 sub-pixel baseline offsets × dark/light polarity. Output reports the actual font used per run (CJK under the system font falls back to `.PingFangUIDisplayTC-*`).

## ocr

```
ocr IMAGE.png [--crop x,y,w,h] [--scale N] [--langs "en-US;zh-Hant,en-US"] [--fast] [--no-correct] [--minconf C] [--json] [--words] [--digitfix]
```
- `.accurate` level. Vision only reads CJK when `zh-Hant` is first in the list, which lowers Latin/digit confidence, so by default two passes (`en-US` and `zh-Hant,en-US`) run and are merged by box overlap (IoU > 0.3), keeping the higher-confidence reading. Each line reports which pass won.
- Boxes are in ORIGINAL image pixels, top-left origin (crop offset and `--scale` undone). `--scale 2/3` helps small 1x UI text (e.g. Activity Monitor on a Retina main display is 2x already).
- `--digitfix`: in mostly-numeric tokens map O/o→0, I/l/|→1 (Vision read `04:04:10` as `O4:04:10` once).

## procstat

```
procstat (--pid PID | --name COMM) [--duration SEC=60] [--interval SEC=1] [--csv out.csv] [--quiet]
```
- CPU from `proc_pid_rusage(RUSAGE_INFO_V4)` `ri_user_time + ri_system_time` (mach ticks → ns via `mach_timebase_info`), summed over root + all descendants (tree rebuilt every sample from `proc_listallpids` + `PROC_PIDTBSDINFO` ppid; identity = (pid, start time)). New processes count their full CPU; CPU of descendants that exited between samples is recovered from parents' `ri_child_user/system_time` delta minus what was already counted.
- Memory per sample: Σ `ri_phys_footprint` (Activity Monitor "Memory" column) and Σ `ri_resident_size` (RSS). MB = 2^20 bytes.
- Summary: `avg_cpu_pct_1core = total_cpu_s / wall_s × 100`, max interval %, footprint/RSS max & avg, per-process table. Exit 4 if the root exits (partial summary still printed; the last partial interval is lost).
- CPU present before the first (baseline) sample is not counted — start procstat before the load you want to measure, or measure a steady-state window.
- Own overhead: 0.02 s CPU per 10 s at 1 s interval (≈0.2 %), and it is not part of the measured tree.

Example (criterion #7): `procstat --pid <panel pid> --duration 300 --interval 2 --csv out/procstat.csv`

## composite / capture_pair.sh

```
capture_pair.sh OUT_DIR TAG [--lg-crop x,y,w,h] [--lg-scale S] [--caption text]
composite MAIN.png WOKYIS.png --out OUT.png [--lg-crop x,y,w,h] [--lg-scale S] [--caption text] [--time text]
```
- `screencapture -x a.png b.png` (one invocation) writes the main display (e.g. 3840×2160) to the FIRST file and the Wokyis (1280×720) to the SECOND; a third filename is ignored (2 displays). `composite` exits 3 if the second image is not 1280×720 (wrong order).
- `capture_pair.sh` brackets the single call with wall-clock timestamps (duration measured 244–390 ms) and logs them to `OUT_DIR/capture_log.tsv`; the composite caption shows start … end. Any skew between the two displays is ≤ that duration.
- Wokyis is pasted 1:1 (never resampled, so glyphheight/OCR still work on the composite at the reported offset); the main display defaults to ×0.5 (e.g. 3840×2160 → 1920×1080 points) or ×1 for a crop (`--lg-*` options apply to the main display).
- `composite` without `--time` uses the MAIN.png mtime, which is the file-write time (≈0.3–0.5 s after the capture instant) — prefer `capture_pair.sh`.

---

# Phase 3 verification tools (criteria #1, #2, #4, #6, #7, #8, #10)

Built by `tools/build.sh` (which then runs `tools/selftest.sh`, ~2 s; `TOOLS_SELFTEST=0` skips it). All read-only towards
other apps: CGWindowList, AX attribute reads and `screencapture` only — no clicks, focus changes or keystrokes.

| tool | criterion | self-test |
|---|---|---|
| `bin/edgecheck` | #1 1-px outer ring on all four edges | `edgecheck --selftest` |
| `bin/winlist` | #1 panel windows vs displays; G5 menu bar / Dock over the Wokyis | `winlist --selftest` |
| `bin/logstats` | #6 / G4 update intervals from the panel log | `logstats --selftest` |
| `bin/amcompare` | #4 AM vs panel harness (pre-registered protocol) | `amcompare unittest`, `amcompare dry-run` |
| `c2measure.sh` | #2 font heights on the real capture | `c2measure.sh --offline PANEL.png`; gate: `c2measure.sh --from-capture CAP.png --snapshot PREFIX` |
| `c7_measure.sh` | #7 CPU / memory of the process tree | `c7_measure.sh PID 10 --settle 0 --no-top`; v2: `c7_measure.sh launch 300 --view cpu` |
| `c7_ab.sh` | #7 v1 / v2 A/B budget matrix (spec §11.4) | `c7_ab.sh --dry-run`; `c7_ab.sh --summarize DIR` |
| `injectdemo.sh` | #8 injected + real failures | `injectdemo.sh --plan`; env hooks `SIM SHOT PANEL_LOG PIDFILE DIAG_DIR WAIT_SCALE` |
| `linkcheck.sh` | #10 README links | `selftest.sh` |
| `wokyis_shot.sh` | helper: Wokyis-only capture (main-display half of the call discarded) | — |
| `selftest.sh [--dry-run [DIR]]` | runs all of the above self-tests | — |

## edgecheck
```
edgecheck IMAGE.png [--color 3A4048] [--tol 6] [--exclude x,y,w,h[:label]]… [--ring N] [--inner] [--expect-size 1280x720] [--out ann.png]
```
Ring pixel matches when max(|ΔR|,|ΔG|,|ΔB|) ≤ tol. Edges: top/bottom rows 0 and H−1 (W px each), left/right columns (H px each);
corners count for both edges. Excluded pixels leave the denominators and are listed separately (privacy dot:
`--exclude 1256,0,24,24:privacy`). `--inner` shows that the ring inside is NOT the edge colour (frame not offset).
Exit 0 all match / 1 mismatch. Offscreen mockups: 8 non-simulation states PASS (1256/1280/720/696 with the privacy
exclude); the 4 simulation states FAIL by design (magenta 6-px frame covers the ring — criterion #1 is shot without injection).

## winlist
```
winlist --owner WokyisPanel [--wokyis x,y,w,h] [--check] [--json]     winlist --overlays [--watch SEC --interval MS]     winlist --displays
```
CG global points. Lists EVERY window of the owner (on- and off-screen) with layer, alpha, bounds, which displays it intersects
and whether it lies fully inside the Wokyis (first non-main 1280×720 display, or the display named "Wokyis").
`verdict PASS` = ≥ 1 on-screen window inside the Wokyis and 0 on-screen windows touching another display (off-screen ones —
e.g. the 1920×30 menu-bar placeholders every app owns — are listed, not failed). `--overlays`: on-screen windows above the
normal layer owned by Window Server / Dock / SystemUIServer / Control Center / Notification Center that intersect the Wokyis
(G5), sampled every `--interval` ms for `--watch` s.

## logstats
```
logstats LOG… [--since T] [--until T] [--last-min N] [--occluded T0,T1]… [--mem-max 2] [--bat-max 60] [--sp-max 60] [--check] [--json OUT]
```
MEM interval n/min/p50/mean/p99/max (+ top gaps), split visible / occluded; DSP count, rate, regions; per-device BAT interval;
SP interval, duration, failures; HIST/HEALTH/ERR/WARN/CTL/DEV/WIN. Intervals never span START/STOP (restart gaps listed).
Occlusion timeline: `WIN … occluded=0|1` or `WIN event=occluded|visible` (authoritative), else `HEALTH occluded=N` (coarse),
or manual `--occluded`. With `log_level=summary` (D4 default) MEM is decimated → the MEM verdict is NOT APPLICABLE and the
overall result INCOMPLETE: criterion #6 / G4 need a `--log-level sample` run.
v2: a `## CPU / NET` section (CPU lines, fail / skip counts, sys / user / idle means; NET lines, fail / skip, rx / tx bps
p50 / p99, `WARN net_counter_reset` count; `UI` event counts), `DSP_regions[view=…]` per view (DSP lines without `view=`
count as `mem`), HEALTH `passes= view= mem_hz=`; the JSON gains `cpu`, `net`, `ui`, `dsp.regions_by_view`.

## amcompare (criterion #4)
```
amcompare preflight [--out DIR]            amcompare run [--out-root DIR]       amcompare axdump
amcompare unittest                         amcompare dry-run [--scenario NAME|all] [--out DIR]
amcompare panelocr WOKYIS.png --rects R.tsv [--state S.json [--ref SNAPSHOT.png]]   (c2measure gate, see c2measure.sh)
common: --pid PID (run/panel.pid) --run-dir run --log logs/current.log --rects FILE --graph-frame x,y,w,h
```
Requires the panel running with `--log-level sample` (DSP lines) for ≥ 60 s, `run/control.json` empty, AM's Memory tab
visible and uncovered on the main display (user consent), and no `vm_stat top amcal hsprobe memprobe procstat` running.
`run` = preflight → `protocol.md` (written with O_EXCL before the first attempt, then chmod 444; its sha256 is re-checked at
the end) → exactly 3 time points ≥ 60 s apart, ≤ 3 attempts each, first valid attempt counts → FAIL or INCOMPLETE stops the
run immediately. One attempt: AX 50 Hz until any footer string changes (`ax_before`) → ONE `screencapture -x lg.png
wokyis.png` (lg.png = main display) (t_cap0/t_cap1) → `ax_after` → OCR (Vision, per-value crops) of AM and panel → AM graph colour (rightmost 4 px of
the AX graph frame) and panel pill colour (hue classes) → join with the DSP commit whose on-screen interval intersects
[t_cap0−0.1 s, t_cap1] → judgement from the displayed strings (exact, KB/MB/GB = 2^10/2^20/2^30). The only invalid
reasons are the five of spec §15 #4 (i–v); an unclassifiable AM graph colour is NOT invalid (the attempt is judged, colour
FAIL); AM not refreshing within 12 s while AX reads work is a failed precondition → ABORT; other tool errors ABORT the run. Outputs per run: `protocol.md preflight.txt
attempts.tsv am_ax_trace.csv summary.md panel_rects.tsv attempt-NN/{lg,wokyis,composite,report}.png ax_before.json
ax_after.json am_ocr.tsv panel_ocr.tsv log_slice.log result.json`. Exit 0 PASS / 1 FAIL / 3 INCOMPLETE / 4 ABORTED / 2 preflight.
`dry-run` runs the same code with a scripted AX source, a synthetic 3840×2160 AM image, the real offscreen panel render
(`WokyisPanel --snapshot`) and a synthetic sample-level log; 11 scenarios with known outcomes (pass, retry, fail-used,
fail-pressure, invalid-am-ocr (i), invalid-panel (ii), slow (iii), ax-fail (iv), control (v), am-colour-unknown (FAIL),
no-refresh (ABORTED)).
Note: the first Vision request of a process can take ~1 min (model load); `run` warms it up before protocol.md.
v2: only `view=mem` DSP lines join (a line without `view=` is a v1 memory commit); a CPU / network commit stays in the
timeline (it ends the on-screen interval of the memory commit before it) but never matches. The panel rects come from the
memory-view snapshot, so run criterion #4 with the panel on the memory view — e.g. started with `--view memory --battery yes
--lang zh` (CLI flags are never saved, spec §7). The dry-run's synthetic DSP lines carry `view=mem lang=zh batv=1`.
The panel crops (`PanelRegions.columns`, clock / battery crops) are the v1 memory + zh + battery-column layout, so the
preflight check `panel on memory / 繁體中文 / battery shown` fails unless the last DSP line has `view=mem lang=zh batv=1`
(a v1 line without the tokens counts as that layout) and names the status-menu setting to change.

## c2measure.sh (criterion #2)
`tools/c2measure.sh [--out DIR] [--tag wokyis] [--tries 3]` — SIGUSR1 snapshot → Wokyis-only capture → acceptance
gate (else retry, ≤ `--tries`, all tries kept in `<tag>-tries.tsv` with `layout_match` / `exact_match` and
`<tag>-tryN-ocr.tsv`) → glyphheight on the binding class rects (`glyph.tsv`, annotated), per-glyph rects (`perglyph.tsv`)
and every `label.*` element box padded 5 px with `--lines` (`element.tsv`) → `method.md` with the gate rule, the accepted
try's gate result and per-class minima. `--offline PANEL.png` measures an offscreen render instead (no signal, no capture,
no gate). `--from-capture CAP.png --snapshot PREFIX` (repeatable; one pair per try, `PREFIX` = `run/snapshot-<ts>`) runs
the gate and the measurement on existing files (no signal, no capture); the capture is copied to `<tag>-tryN.png`.
v2: `--render VIEW LANG yes|no` renders the fixture with `build/WokyisPanel.app --snapshot --dump-rects --view VIEW --lang
LANG --battery yes|no` into `<out>/<tag>-render.png` and measures it like `--offline`. The live / from-capture gate compares
the memory values, so it applies to the memory view only: a snapshot whose `state.json` names another view is refused
(exit 2) — measure the CPU / network views with `--render` until a gate for them exists. The gate's crops are the v1 zh +
battery-column layout, so a memory snapshot with `"lang": "en"` or `"battery_visible": false` is refused too (exit 2, the
message names the status-menu setting); measure those layouts with `--render memory en|zh yes|no`.

Gate (`amcompare panelocr CAP --rects PREFIX.rects.tsv --state PREFIX.state.json --ref PREFIX.png`, exit 0 = accepted):
a capture is accepted when every gated text element is **layout-equivalent** to the snapshot. Layout key = the existing
OCR normalisation (`OCRNorm.key`: spaces unified, digitfix, whitespace removed, upper case, dash / empty → "—") with every
ASCII digit mapped to `9` on both sides; `.` `,` `:` `%` and letters stay literal. The renderer draws numbers in SF Pro
Condensed with monospaced digits (`kMonospacedNumbersSelector`), so equal keys mean identical glyph positions and the
snapshot rects stay valid while the memory values change at 4 Hz (the former exact-string gate accepted 0 of 9 live
captures). Gated elements: the 7 memory values, pressure % and the clock vs `state.json`; the battery value column
(x 1040–1272, y 12–648; en-US OCR lines that contain a digit or `%`) vs the same OCR of the snapshot PNG — same number of
lines, pairwise equal keys, line centres within ±30 px. Rejected: e.g. `9.99 GB` vs `10.00 GB`, `—` vs a number, a
battery row appearing / disappearing / moving, `99%` vs `100%`. Exact equality is recorded as well (`match` column,
summary `ALL MATCH` = exact, `LAYOUT MATCH` = digits differ only, `MISMATCH` = rejected). Not OCR-gated: label text
(static except battery device labels and the pressure word; en-US OCR cannot read CJK, and zh-Hant readings of the same
label differ between a capture and the render). `amcompare unittest` includes the layout-key and battery-list cases.

## c7_measure.sh (criterion #7)
`tools/c7_measure.sh PID [300] [--out DIR] [--settle 60] [--interval 2] [--no-top]` — settle, `ps` of the process
group + descendants before/after, `procstat` over the whole tree (incl. system_profiler children) with CSV, `top -l N -s 2 -pid`
as a cross-check (skip with `--no-top`; top calls host statistics — never during criterion #4 or a memory gate),
`verdict.txt` (avg CPU < 2 % of one core, max phys_footprint < 150 MB). Run once visible and once occluded (`--out …/occluded`).
v2: `tools/c7_measure.sh launch [300] [--view memory|cpu|network] [--binary PATH] [--panel-arg ARG]… [--sim "pressure red 92"]`
starts its own panel (refused while any WokyisPanel runs — `scripts/stop.sh` first) with `--log-dir logs --run-dir run`
plus the CLI-only `--view` / extra args (nothing is saved), optionally applies `scripts/sim.sh ARGS --for settle+secs+60`,
measures, then clears the simulation and stops it (SIGTERM; the user's panel is not restarted). `--binary` selects e.g. a
kept v1 build (`build/WokyisPanel-v1`; v1 has no `--view`). Both modes add, from the panel log whose START has `pid=PID`
(`tools/c7_health.pl`, `health.tsv`): `health_max5_cpu_pct` (max over HEALTH pairs ≥ 295 s apart in the measured window
of Δcpu_s / Δt; panel process only; `-` when the window is < 5 min; the baseline is the last HEALTH ≤ 65 s before the
window, i.e. the end of the warm-up minute), `passes_per_s`, `draw_ms_avg`, `mem_hz`, `sys_dur_us_p99`, `view`. They
are reported and do not change the verdict.

## c7_ab.sh (criterion #7, spec §11.4)
`tools/c7_ab.sh [--rounds 3] [--seconds 300] [--settle 60] [--cells C1,…,C5] [--views memory,cpu,network] [--v1 PATH]
[--out DIR] [--dry-run]` — one `c7_measure.sh launch` per (round, cell, binary, view), v1 next to the v2 memory run and
the order reversed on even rounds (v1 / v2 alternate). Cells: C1 default, C2 `sim.sh pressure red 92`, C3 `--log-level
sample` (C1–C3 also on v1, memory view), C4 `--battery no`, C5 `--lang en` (v2 only). Without a v1 binary at `--v1`
(default `build/WokyisPanel-v1`) the v1 rows are skipped and the summary has no v2 − v1 delta. Output: `results.tsv`,
one c7_measure directory per run, `summary.md` (per cell / binary / view: mean 5-min average, max 5-min window, pass/s,
v2 − v1; PASS = every v2 max window < 2.0 %; design target C1 ≤ 1.8 %; the §11.4 decision-ladder step). The default
matrix is ≈ 6 h; nothing has been measured with it yet. `--summarize DIR` rewrites `summary.md` from `results.tsv`.
Prerequisites: no panel running, the Wokyis connected, Activity Monitor closed. Exit 0 PASS, 1 FAIL, 2 usage / a run
could not start.

## injectdemo.sh (criterion #8)
`tools/injectdemo.sh [--out DIR] [--airpods] [--only ID] [--plan]` — per source (mem.swap, mem.vm, mem.level, bat.hid,
[bat.iops+bat.sp], hang bat.sp, garbage bat.sp): before / during ×2 / after Wokyis captures, waits for the matching `ERR` line
AND for the display evidence (battery: the DEV line that turns the affected rows `failed` / `stale` — for bat.sp only once
the last good sp is > 45 s old) before the during captures (a step without it FAILS), clears, waits until every such row has
a DEV `to=connected|offline`, keeps the step's log lines, checks the pid never changed and no new
`~/Library/Logs/DiagnosticReports/WokyisPanel*`. `injectdemo.sh real` restarts the panel with `--break-mib vm.swapusage` and
`--sp-path /nonexistent/system_profiler` (then normally again). Needs `scripts/sim.sh`, `start.sh`, `stop.sh`.

## linkcheck.sh (criterion #10)
`tools/linkcheck.sh README.md [> OUT.txt]` — every relative Markdown / `<img>` / reference link must exist
(anchors, URLs and fenced code skipped). Exit 1 when any is missing.
