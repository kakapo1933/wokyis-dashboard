// Golden.swift — `render.memory.golden` (spec §10.2): the memory / zh / battery-column frame must stay pixel-identical
// to v1. GoldenFixture.state() is rendered offscreen exactly like tools/golden (1280×720 sRGB premultipliedLast,
// flipped, measure = true) and its RGBA SHA-256 is compared with GoldenPin:
//   * same OS build (kern.osversion) and a different hash → FAIL
//   * different OS build → PASS with `repin_needed os=<new> pinned=<old>` (font rasterisation may change between OS
//     builds; tools/golden_pin.sh re-pins only after the frozen v1 renderer and the current one agree on all states).
// Owner: foundation (golden).
import CoreGraphics
import CryptoKit
import Foundation

extension Snapshot {
    /// The locale / time-zone independent golden fixture (literal strings, clock "12:34:56", now 1_790_000_000).
    static func goldenState() -> PanelState { GoldenFixture.state() }
}

enum GoldenSelfTest {
    /// (RGBA SHA-256 hex, layout problems) of `state` rendered the way tools/golden/GoldenMain.swift renders it.
    static func render(_ state: PanelState) -> (sha: String, problems: [String])? {
        var buf = [UInt8](repeating: 0, count: 1280 * 720 * 4)
        let problems: [String]? = buf.withUnsafeMutableBytes { p in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: p.baseAddress, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 1280 * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.translateBy(x: 0, y: 720); ctx.scaleBy(x: 1, y: -1)
            let r = PanelRenderer()
            r.draw(ctx, state)
            return r.layoutProblems()
        }
        guard let problems else { return nil }
        return (SHA256.hash(data: Data(buf)).map { String(format: "%02x", $0) }.joined(), problems)
    }

    static func osVersion() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var b = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &b, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: b)
    }

    /// Pure decision (unit-tested below): same OS → hash must match; other OS → pass with a repin note.
    static func judge(sha: String, os: String, pinSHA: String, pinOS: String) -> (ok: Bool, detail: String) {
        if os == pinOS { return (sha == pinSHA, sha == pinSHA ? "sha=\(sha.prefix(16)) os=\(os)" : "MISMATCH sha=\(sha) pinned=\(pinSHA) os=\(os)") }
        return (true, "repin_needed os=\(os) pinned=\(pinOS) sha=\(sha) (run tools/golden_pin.sh)")
    }

    static func run() -> [SelfTestCase] {
        var out: [SelfTestCase] = []
        guard let (sha, problems) = render(Snapshot.goldenState()) else { return [SelfTestCase("render.memory.golden", false, "no bitmap")] }
        let j = judge(sha: sha, os: osVersion(), pinSHA: GoldenPin.rgbaSHA256, pinOS: GoldenPin.osVersion)
        out.append(SelfTestCase("render.memory.golden", j.ok && problems.isEmpty,
                                j.detail + (problems.isEmpty ? "" : " layout: " + problems.prefix(2).joined(separator: "; "))))
        // the default-valued v2 fields ARE the v1 frame: an explicit memory / zh / battery state hashes the same
        var explicit = Snapshot.goldenState()
        explicit.view = .memory; explicit.lang = .zh; explicit.batteryVisible = true
        let e = render(explicit)?.sha
        out.append(SelfTestCase("render.memory.golden_defaults", e == sha, "explicit=\(e?.prefix(16) ?? "-") default=\(sha.prefix(16))"))
        // repin rule
        let a = judge(sha: "x", os: "A", pinSHA: "x", pinOS: "A").ok, b = judge(sha: "y", os: "A", pinSHA: "x", pinOS: "A").ok
        let c = judge(sha: "y", os: "B", pinSHA: "x", pinOS: "A")
        out.append(SelfTestCase("render.memory.golden_repin_rule", a && !b && c.ok && c.detail.hasPrefix("repin_needed os=B pinned=A"), c.detail))
        return out
    }
}
