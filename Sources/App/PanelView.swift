// PanelView.swift — the single flipped NSView; region invalidation; draw → PanelRenderer; DSP log (spec §4, §7.3, §12).
// Owner: app agent.
//
// update(): setNeedsDisplay(Layout.region[r]) for each dirty region (a full redraw when `.chrome` is dirty). While the
// window is occluded nothing is invalidated (the Store keeps updating; the controller forces one full redraw when the
// window becomes visible again). draw(): the regions that intersect the rects being drawn are repainted
// (renderer.draw(ctx, state, only:) — chrome first, clipped by AppKit to the dirty rects); a dirty rect that covers the
// whole view → a full render incl. the simulation frame. Each draw ends with one DSP line (seq, mem_seq, clock,
// regions, battery strings, page, stale, sim) — the screen ↔ sample join for criterion #4.
import AppKit

final class PanelView: NSView {
    let renderer = PanelRenderer()
    private(set) var state: PanelState?
    /// State of the last committed draw (what is on screen) — SIGUSR1 snapshots render this.
    private(set) var drawnState: PanelState?
    private(set) var drawnMemSeq: UInt64?
    private var memSeq: UInt64?
    var log: EventLog?
    /// Set by the controller from the window's occlusion state. No invalidation while false.
    var visibleOnScreen = true

    private(set) var dspSeq: UInt64 = 0
    private(set) var draws: UInt64 = 0
    private var drawSeconds: Double = 0
    private var drawsSinceHealth: UInt64 = 0
    private var drawSecondsSinceHealth: Double = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var wantsDefaultClipping: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { nil }

    /// setNeedsDisplay(Layout.region[r]) for r in dirty; `.chrome` (simulation frame toggled / forced) → whole view.
    func update(_ s: PanelState, dirty: Set<Region>) { update(s, dirty: dirty, memSeq: memSeq) }

    func update(_ s: PanelState, dirty: Set<Region>, memSeq: UInt64?) {
        state = s; self.memSeq = memSeq
        guard visibleOnScreen, !dirty.isEmpty else { return }
        if dirty.contains(.chrome) || bounds.size != NSSize(width: Layout.W, height: Layout.H) {
            needsDisplay = true
            return
        }
        for r in dirty { if let rr = Layout.region[r] { setNeedsDisplay(rr) } }
    }

    /// Average draw time since the previous call (HEALTH line) and the number of draws in that window.
    func takeDrawStats() -> (draws: UInt64, avgMs: Double?) {
        defer { drawsSinceHealth = 0; drawSecondsSinceHealth = 0 }
        return (drawsSinceHealth, drawsSinceHealth > 0 ? drawSecondsSinceHealth / Double(drawsSinceHealth) * 1000 : nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard let s = state else {
            ctx.setFillColor(Theme.bg); ctx.fill(bounds)
            return
        }
        var rectsPtr: UnsafePointer<NSRect>? = nil
        var n = 0
        getRectsBeingDrawn(&rectsPtr, count: &n)
        let rects = (0..<n).compactMap { rectsPtr?[$0] }
        let full = dirtyRect.contains(bounds) || rects.contains { $0.contains(bounds) } || bounds.size != NSSize(width: Layout.W, height: Layout.H)
        var drawn: [String]
        if full {
            renderer.draw(ctx, s)
            drawn = ["all"]
        } else {
            var only: Set<Region> = [.chrome]
            for (r, rr) in Layout.region where rects.contains(where: { $0.intersects(rr) }) { only.insert(r) }
            renderer.draw(ctx, s, only: only)
            if s.simulationBadge != nil { renderer.drawSimFrame(ctx) }   // clipped to the dirty rects by AppKit
            drawn = Region.allCases.filter { only.contains($0) && $0 != .chrome }.map(\.rawValue)
        }
        let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        draws += 1; drawSeconds += dt; drawsSinceHealth += 1; drawSecondsSinceHealth += dt
        drawnState = s; drawnMemSeq = memSeq
        dspSeq += 1
        let pages = PanelRenderer.pages(s.devices).count
        let blank = s.memory.used == .failed && s.memory.physical == .failed && s.memory.pressurePercent == nil
        log?.line("DSP", "seq=\(dspSeq) mem_seq=\(memSeq.map { String($0) } ?? "-") clock=\(s.clock) regions=\(drawn.joined(separator: ",")) "
                  + "bat=\(EventLog.q(StateBuilder.dspBattery(s))) page=\(min(s.batteryPage, pages - 1) + 1)/\(pages) "
                  + "stale=\(s.sampleStale ? 1 : 0)\(blank ? " blank=1" : "") draw_us=\(Int(dt * 1e6)) sim=\(s.simulationBadge == nil ? 0 : 1)")
    }
}
