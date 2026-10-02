// PanelRenderer+Views.swift — v2 CPU and network views (AM CPU / Network tab footers) on the shared geometry.
// Cells come from Layout.geometry(view:battery:lang:); every value auto-fits to its cell's `room`
// (hero 110 → 96 pt: flattest digits 1/4/7 ≥ 69 px; grid fixed at 60 pt like the memory grid: ≥ 43 px — r2 removed the
// 56 pt grid floor, which left 1/4/7 at exactly 40 px, zero margin), so the ≥ 30 px gap holds by construction.
// A grid integer that does not fit at 60 pt (≥ 10-digit packet totals in the 800 px column) switches to "1.23 G".
import AppKit
import CoreText

extension PanelRenderer {
    static let heroFloor: CGFloat = 96, gridFloor: CGFloat = 60

    /// "16.65%" → digits + "%" symbol at unit size (as the pressure / battery numbers). "—" when failed.
    func pctPieces(_ v: Shown, size: CGFloat, minPx: Int) -> [Piece] {
        guard case .text(let t) = v else { return [Piece(text: "—", font: Fonts.num(size, .semibold), color: Theme.value, cls: "symbol")] }
        if t.hasSuffix("%") {
            return [Piece(text: String(t.dropLast()), font: Fonts.num(size), color: Theme.value, cls: "digit", minPx: minPx),
                    Piece(text: "%", font: Fonts.num(Size.unit), color: Theme.value, cls: "symbol", gapBefore: 4)]
        }
        return valuePieces(v, size: size, minPx: minPx)
    }

    /// "1.23 G" — decimal unit chosen on the ROUNDED value (999,999,999 → "1.00 G", never "1,000.00 M"), as L10n.speed.
    static func compactCount(_ n: Double) -> String {
        var v = n, i = 0
        let units = ["", " K", " M", " G", " T", " P"]
        while i < units.count - 1 && (v * 100).rounded(.toNearestOrAwayFromZero) / 100 >= 1000 { v /= 1000; i += 1 }
        return L10n.fmt2(v) + units[i]
    }

    /// Largest size ≤ start (step 2, floor) whose pieces fit `room`.
    func fitted(_ make: (CGFloat) -> [Piece], hero: Bool, room: CGFloat) -> [Piece] {
        var size = hero ? Size.hero : Size.secondary
        let floor = hero ? Self.heroFloor : Self.gridFloor
        while size > floor && width(make(size)) > room { size -= 2 }
        return make(size)
    }

    /// Label (+ optional series swatch right after it) and auto-fitted value of one cell.
    func drawCell(_ ctx: CGContext, _ c: Cell, label: String, value: Shown, pct: Bool, swatch: CGColor?, id: String) {
        let l = text(ctx, labelPieces(label), x: c.x, baseline: c.labelBase, id: "label.\(id)")
        var labels = ["label.\(id)"]
        if let col = swatch, !l.isNull {
            let sw = CGRect(x: (l.maxX + 14).rounded(), y: (l.midY - 14).rounded(), width: 28, height: 28)
            ctx.setFillColor(col)
            ctx.addPath(CGPath(roundedRect: sw, cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.fillPath()
            addBox("swatch.\(id)", sw); labels.append("swatch.\(id)")
        }
        let minPx = c.hero ? 64 : 40
        var pieces = fitted({ pct ? self.pctPieces(value, size: $0, minPx: minPx) : self.valuePieces(value, size: $0, minPx: minPx) }, hero: c.hero, room: c.room)
        if width(pieces) > c.room, case .text(let t) = value, !t.isEmpty, t.allSatisfy({ $0.isNumber || $0 == "," }) {
            // ≥ 10-digit packet totals in the 800 px layout: compact "1.23 G" (only when the AM integer cannot fit at 60 pt)
            let compact = Shown.text(Self.compactCount(Double(t.replacingOccurrences(of: ",", with: "")) ?? 0))
            pieces = fitted({ self.valuePieces(compact, size: $0, minPx: minPx) }, hero: c.hero, room: c.room)
        }
        text(ctx, pieces, x: c.x, baseline: c.valueBase, id: "value.\(id)")
        logCell(c, labels, "value.\(id)")
    }

    // MARK: CPU (AM CPU tab: System / User / Idle %, CPU LOAD graph, Threads, Processes)

    func drawCPUCell(_ ctx: CGContext, _ s: PanelState, _ r: Region) {
        guard let c = geo.cells[r] else { return }
        let cpu = s.cpu
        switch r {
        case .cpuSys: drawCell(ctx, c, label: T(.cpuSystem), value: cpu.system, pct: true, swatch: Theme.seriesRed, id: "cpuSys")
        case .cpuUser: drawCell(ctx, c, label: T(.cpuUser), value: cpu.user, pct: true, swatch: Theme.seriesCyan, id: "cpuUser")
        case .cpuIdle: drawCell(ctx, c, label: T(.cpuIdle), value: cpu.idle, pct: true, swatch: nil, id: "cpuIdle")
        case .cpuThreads: drawCell(ctx, c, label: T(.cpuThreads), value: cpu.threads, pct: false, swatch: nil, id: "cpuThreads")
        case .cpuProcs: drawCell(ctx, c, label: T(.cpuProcesses), value: cpu.processes, pct: false, swatch: nil, id: "cpuProcs")
        default: break
        }
    }

    /// Graph well shared by the CPU and network graphs (same look as the pressure well: radius 10, minute grid,
    /// 5-minute mark brighter). `hLines` = y positions of the horizontal guide lines (major first).
    func drawWell(_ ctx: CGContext, _ g: CGRect, major: CGFloat?, minor: [CGFloat]) {
        ctx.setFillColor(Theme.well)
        ctx.addPath(CGPath(roundedRect: g, cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.fillPath()
        addBox("graph", g)
        for k in 1..<10 {
            let x = (g.maxX - CGFloat(k) / 10 * g.width).rounded()
            ctx.setFillColor(k == 5 ? Theme.gridMajor : Theme.grid)
            ctx.fill(CGRect(x: x, y: g.minY + 6, width: k == 5 ? 2 : 1, height: g.height - 12))
        }
        ctx.setFillColor(Theme.grid)
        for y in minor { ctx.fill(CGRect(x: g.minX + 6, y: y.rounded(), width: g.width - 12, height: 1)) }
        if let y = major { ctx.setFillColor(Theme.gridMajor); ctx.fill(CGRect(x: g.minX + 6, y: y.rounded(), width: g.width - 12, height: 1)) }
    }

    /// Contiguous runs (Δt < 2.5 s) of valid points inside the visible span; a missing / nil second = gap.
    func runs<P: SecondPoint>(_ h: HistoryView<P>, now: Double, t: (P) -> Double, valid: (P) -> Bool) -> [[P]] {
        var out: [[P]] = [], cur: [P] = []
        var lastT = -Double.infinity
        h.forEach { p in
            guard now - t(p) <= graphSpan + 2 else { return }
            if !valid(p) { if !cur.isEmpty { out.append(cur); cur = [] }; return }
            if !cur.isEmpty && t(p) - lastT >= 2.5 { out.append(cur); cur = [] }
            cur.append(p); lastT = t(p)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Step series as integer-snapped rects (no anti-aliased paths: ~0.4 ms per graph instead of ~3 ms, measured):
    /// for each point a column [x(t), x(next)) and, for the outline, a 2 px top edge plus a 2 px vertical connector to
    /// the previous step. `fill(k)` = (top, bottom) of the filled column, `edge(k)` = y of the outline.
    /// `sim` (r2): the 7 px magenta stripe of simulated seconds uses the SAME column span as the fill (v1's pressure graph
    /// fills x(t[k])…x(t[k+1]) too), so consecutive simulated seconds form a solid bar instead of 1-px-gapped dashes.
    struct StepRects { var fill: [CGRect] = []; var line: [CGRect] = []; var sim: [CGRect] = [] }
    func stepRects<P>(_ run: [P], t: (P) -> Double, xOf: (Double) -> CGFloat, pxPerSec: CGFloat,
                      fill: (P) -> (CGFloat, CGFloat), edge: (P) -> CGFloat,
                      simulated: ((P) -> Bool)? = nil, simTop: CGFloat = 0) -> StepRects {
        var out = StepRects()
        var prevEdge: CGFloat? = nil
        for (k, p) in run.enumerated() {
            let x0 = xOf(t(p)).rounded()
            let x1 = k + 1 < run.count ? xOf(t(run[k + 1])).rounded() : x0 + max(1, pxPerSec.rounded())
            guard x1 > x0 else { continue }
            let (top, bottom) = fill(p)
            if bottom - top >= 1 { out.fill.append(CGRect(x: x0, y: top, width: x1 - x0, height: bottom - top)) }
            let e = edge(p).rounded()
            out.line.append(CGRect(x: x0, y: e - 1, width: x1 - x0, height: 2))
            if let pe = prevEdge, abs(pe - e) > 1 { out.line.append(CGRect(x: x0 - 1, y: min(pe, e) - 1, width: 2, height: abs(pe - e) + 2)) }
            prevEdge = e
            if let sm = simulated, sm(p) { out.sim.append(CGRect(x: x0, y: simTop, width: x1 - x0, height: 7)) }
        }
        return out
    }

    /// CPU LOAD (AM SMCPUGraphController). Simulated seconds are striped inside valid runs only (v1 pressure rule).: inner series System (red, from the bottom), outer series System + User
    /// (cyan, stacked on it); fills α 0.3, 2 px outline; vertical scale max 110 % (AM setMaxValue 110 → 10 % headroom).
    func drawCPUGraph(_ ctx: CGContext, _ s: PanelState) {
        let g = geo.graph
        let plot = g.insetBy(dx: 0, dy: 4)
        func yOf(_ p: Float) -> CGFloat { (plot.maxY - CGFloat(min(110, max(0, p)) / 110) * plot.height).rounded() }
        drawWell(ctx, g, major: yOf(50), minor: [yOf(100)])
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: g, cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.clip()
        let pxPerSec = g.width / CGFloat(graphSpan)
        func xOf(_ t: Double) -> CGFloat { g.maxX - CGFloat(s.now - t) * pxPerSec }
        var red = StepRects(), cyan = StepRects(), sim: [CGRect] = []
        for run in runs(s.cpuHistory, now: s.now, t: { $0.t }, valid: { $0.system != nil && $0.user != nil }) {
            let r = stepRects(run, t: { $0.t }, xOf: xOf, pxPerSec: pxPerSec, fill: { (yOf($0.system!), plot.maxY) }, edge: { yOf($0.system!) },
                              simulated: { $0.simulated }, simTop: g.maxY - 7)
            let c = stepRects(run, t: { $0.t }, xOf: xOf, pxPerSec: pxPerSec, fill: { (yOf($0.system! + $0.user!), yOf($0.system!)) },
                              edge: { yOf($0.system! + $0.user!) })
            red.fill += r.fill; red.line += r.line; cyan.fill += c.fill; cyan.line += c.line; sim += r.sim
        }
        ctx.setFillColor(Theme.seriesCyan.copy(alpha: 0.3)!); ctx.fill(cyan.fill)
        ctx.setFillColor(Theme.seriesRed.copy(alpha: 0.3)!); ctx.fill(red.fill)
        ctx.setFillColor(Theme.seriesCyan); ctx.fill(cyan.line)
        ctx.setFillColor(Theme.seriesRed); ctx.fill(red.line)
        ctx.setFillColor(Theme.sim); ctx.fill(sim)
        ctx.restoreGState()
    }

    // MARK: network (AM Network tab: Download / Upload, Packets in/out(/sec), Data received / sent, DATA graph)

    func drawNetCell(_ ctx: CGContext, _ s: PanelState, _ r: Region) {
        guard let c = geo.cells[r] else { return }
        let n = s.net
        switch r {
        case .netDown: drawCell(ctx, c, label: T(.netDownload), value: n.download, pct: false, swatch: Theme.seriesCyan, id: "netDown")
        case .netUp: drawCell(ctx, c, label: T(.netUpload), value: n.upload, pct: false, swatch: Theme.seriesRed, id: "netUp")
        case .netPktIn: drawCell(ctx, c, label: T(.netPacketsIn), value: n.packetsIn, pct: false, swatch: nil, id: "netPktIn")
        case .netPktOut: drawCell(ctx, c, label: T(.netPacketsOut), value: n.packetsOut, pct: false, swatch: nil, id: "netPktOut")
        case .netPktInS: drawCell(ctx, c, label: T(.netPacketsInRate), value: n.packetsInRate, pct: false, swatch: nil, id: "netPktInS")
        case .netPktOutS: drawCell(ctx, c, label: T(.netPacketsOutRate), value: n.packetsOutRate, pct: false, swatch: nil, id: "netPktOutS")
        case .netRecv: drawCell(ctx, c, label: T(.netReceived), value: n.received, pct: false, swatch: nil, id: "netRecv")
        case .netSent: drawCell(ctx, c, label: T(.netSent), value: n.sent, pct: false, swatch: nil, id: "netSent")
        default: break
        }
    }

    /// DATA graph (AM SMNetworkGraphController, DATA mode): received on top (cyan, up from the mid line), sent below
    /// (red, inverted, down from the mid line); one shared linear scale = 1.1 × the largest visible value of either
    /// series (floor 1 kB/s); fills α 0.3, 2 px outline, same step rects as the CPU graph.
    func drawNetGraph(_ ctx: CGContext, _ s: PanelState) {
        let g = geo.graph
        let plot = g.insetBy(dx: 0, dy: 4)
        let mid = (plot.minY + plot.height / 2).rounded()
        drawWell(ctx, g, major: mid, minor: [])
        var peak = 1000.0
        s.netHistory.forEach { p in if s.now - p.t <= graphSpan + 2 { peak = max(peak, p.rx ?? 0, p.tx ?? 0) } }
        let scale = peak * 1.1, half = plot.height / 2
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: g, cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.clip()
        let pxPerSec = g.width / CGFloat(graphSpan)
        func xOf(_ t: Double) -> CGFloat { g.maxX - CGFloat(s.now - t) * pxPerSec }
        func up(_ v: Double) -> CGFloat { (mid - CGFloat(min(1, v / scale)) * half).rounded() }
        func down(_ v: Double) -> CGFloat { (mid + CGFloat(min(1, v / scale)) * half).rounded() }
        var rx = StepRects(), tx = StepRects(), sim: [CGRect] = []
        for run in runs(s.netHistory, now: s.now, t: { $0.t }, valid: { $0.rx != nil }) {
            let r = stepRects(run, t: { $0.t }, xOf: xOf, pxPerSec: pxPerSec, fill: { (up($0.rx!), mid) }, edge: { up($0.rx!) },
                              simulated: { $0.simulated }, simTop: g.maxY - 7)
            rx.fill += r.fill; rx.line += r.line; sim += r.sim
        }
        for run in runs(s.netHistory, now: s.now, t: { $0.t }, valid: { $0.tx != nil }) {
            let r = stepRects(run, t: { $0.t }, xOf: xOf, pxPerSec: pxPerSec, fill: { (mid, down($0.tx!)) }, edge: { down($0.tx!) })
            tx.fill += r.fill; tx.line += r.line
        }
        // simulated seconds are marked inside valid runs only — the v1 pressure-graph rule, now the same for all three graphs
        ctx.setFillColor(Theme.seriesCyan.copy(alpha: 0.3)!); ctx.fill(rx.fill)
        ctx.setFillColor(Theme.seriesRed.copy(alpha: 0.3)!); ctx.fill(tx.fill)
        ctx.setFillColor(Theme.seriesCyan); ctx.fill(rx.line)
        ctx.setFillColor(Theme.seriesRed); ctx.fill(tx.line)
        ctx.setFillColor(Theme.sim); ctx.fill(sim)
        ctx.restoreGState()
    }
}
