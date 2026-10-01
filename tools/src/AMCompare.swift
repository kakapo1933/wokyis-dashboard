// amcompare — criterion #4 harness (spec §15 #4): Activity Monitor footer vs the Wokyis panel, pre-registered protocol.
//
// usage:
//   amcompare unittest                         string→bytes, thresholds, normalisation, hue classes, control.json, log join
//   amcompare dry-run [--scenario NAME|all] [--out DIR] [--panel-bin PATH]
//                                              whole harness on synthetic inputs (no AM, no screencapture, no live panel)
//   amcompare axdump [--graph-frame x,y,w,h]   read-only AX dump of AM's footer (values, frames, graph candidate)
//   amcompare preflight [--out DIR] [common options]
//   amcompare run [--out-root evidence/c4] [common options]      → <out-root>/run-<yyyyMMdd-HHmmss>/
//   amcompare panelocr WOKYIS.png --rects R.tsv [--state S.json [--ref SNAPSHOT.png]]
//                                              c2measure's gate: 7 values + pressure % + clock vs state.json, battery
//                                              column vs the snapshot PNG; layout-equivalent (digits → 9) = accepted
//                                              (AMCompare+PanelGate.swift)
// common options: --pid PID (default: run/panel.pid) --run-dir DIR (run) --log FILE (logs/current.log)
//                 --rects FILE (default: SIGUSR1 → newest run/snapshot-*.rects.tsv) --graph-frame x,y,w,h (CG points)
// Relative paths: taken from the cwd when they exist there, otherwise from the project root (tools/bin/../..).
// Exit (run): 0 PASS, 1 FAIL, 3 INCOMPLETE, 4 ABORTED, 2 preflight failed / usage.
// Read-only towards Activity Monitor: AX attribute reads and CGWindowList only — no clicks, focus changes or keystrokes.
import Foundation
import AppKit

@main
struct AMCompare {
    static var projectRoot: String {
        let exe = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
        return exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    }
    /// Absolute paths as given; a relative path that exists under the cwd is taken from the cwd, otherwise from the project root.
    static func resolve(_ p: String) -> String {
        if p.hasPrefix("/") { return p }
        let cwd = FileManager.default.currentDirectoryPath + "/" + p
        return FileManager.default.fileExists(atPath: cwd) ? cwd : projectRoot + "/" + p
    }

    static func main() {
        let argv = Array(CommandLine.arguments.dropFirst())
        guard let cmd = argv.first else { usage(); exit(2) }
        let a = Args(Array(argv.dropFirst()), flagNames: ["help"])
        let toolHash = sha256File(Bundle.main.executablePath ?? CommandLine.arguments[0])
        switch cmd {
        case "unittest": let logic = LogicTests.run(), gate = PanelGate.selfTest(); exit(logic && gate ? 0 : 1)
        case "dry-run": exit(DryRun.main(a, toolHash: toolHash, root: projectRoot))
        case "axdump":
            guard let am = RealAM(graphOverride: graphOverride(a)) else { print("Activity Monitor is not running"); exit(2) }
            print(am.dump(), terminator: "")
            print("visibility\t\(am.visibility())")
            exit(am.discoveryError == nil ? 0 : 1)
        case "preflight", "run":
            guard let am = RealAM(graphOverride: graphOverride(a)) else { print("Activity Monitor is not running"); exit(2) }
            let runDir = resolve(a.one("run-dir") ?? "run")
            let pid = a.int("pid").map { pid_t($0) } ?? (try? String(contentsOfFile: runDir + "/panel.pid", encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let rects = a.one("rects").map { (try? String(contentsOfFile: resolve($0), encoding: .utf8)) ?? "" } ?? pid.flatMap { snapshotRects(pid: $0, runDir: runDir) }
            let h = Harness(am: am, capturer: ScreenCapturer(), controlPath: runDir + "/control.json", logPath: resolve(a.one("log") ?? "logs/current.log"),
                            rectsTSV: rects, mainBounds: WindowCheck.mainDisplayBounds(), compositeBin: projectRoot + "/tools/bin/composite",
                            hostCallers: runningHostCallers, panelPid: pid)
            h.toolHash = toolHash
            if cmd == "preflight" {
                let cs = h.preflight()
                var t = "# amcompare preflight \(isoNow())\n"
                for c in cs { t += "\(c.ok ? "OK  " : "FAIL")\t\(c.name)\t\(c.detail)\n" }
                let ok = cs.allSatisfy { $0.ok }
                t += "preflight\t\(ok ? "PASS" : "FAIL")\n"
                print(t, terminator: "")
                if let o = a.one("out") { let d = resolve(o); try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true); writeText(t, d + "/preflight.txt") }
                exit(ok ? 0 : 2)
            }
            let root = resolve(a.one("out-root") ?? "evidence/c4")
            let o = h.run(root: root, stamp: compactStamp(Date()))
            switch o { case .pass: exit(0); case .fail: exit(1); case .incomplete: exit(3); case .aborted: exit(4); case .preflightFailed: exit(2) }
        case "panelocr":
            guard let png = a.positional.first, let rp = a.one("rects") else { usage(); exit(2) }
            let state = a.one("state").map(resolve)
            // reference image for the battery column: --ref, else the PNG next to S.state.json (snapshot-<ts>.png)
            let ref = a.one("ref").map(resolve) ?? state.flatMap { $0.hasSuffix(".state.json") ? String($0.dropLast(11)) + ".png" : nil }
            exit(PanelGate.run(png: resolve(png), rects: (try? String(contentsOfFile: resolve(rp), encoding: .utf8)) ?? "", state: state, ref: ref))
        default: usage(); exit(2)
        }
    }

    static func graphOverride(_ a: Args) -> CGRect? {
        guard let s = a.one("graph-frame") else { return nil }
        let p = s.split(separator: ",").compactMap { Double($0) }
        guard p.count == 4 else { die("bad --graph-frame") }
        return CGRect(x: p[0], y: p[1], width: p[2], height: p[3])
    }

    /// SIGUSR1 → the panel writes run/snapshot-<ts>.{png,rects.tsv,…}; wait ≤ 5 s for a rects file newer than the signal.
    static func snapshotRects(pid: pid_t, runDir: String) -> String? {
        let t0 = Date()
        guard kill(pid, SIGUSR1) == 0 else { return nil }
        while Date().timeIntervalSince(t0) < 5 {
            Thread.sleep(forTimeInterval: 0.2)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: runDir)) ?? []
            let cands = files.filter { $0.hasPrefix("snapshot-") && $0.hasSuffix(".rects.tsv") }.compactMap { f -> (String, Date)? in
                let p = runDir + "/" + f
                guard let m = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date, m >= t0.addingTimeInterval(-0.5) else { return nil }
                return (p, m)
            }
            if let newest = cands.max(by: { $0.1 < $1.1 }) { return try? String(contentsOfFile: newest.0, encoding: .utf8) }
        }
        return nil
    }

    static func usage() {
        print("""
        usage: amcompare unittest
               amcompare dry-run [--scenario NAME|all] [--out DIR] [--panel-bin PATH]
               amcompare axdump [--graph-frame x,y,w,h]
               amcompare preflight [--out DIR] [--pid PID] [--run-dir run] [--log logs/current.log] [--rects FILE] [--graph-frame x,y,w,h]
               amcompare run [--out-root evidence/c4] [--pid PID] [--run-dir run] [--log logs/current.log] [--rects FILE] [--graph-frame x,y,w,h]
               amcompare panelocr WOKYIS.png --rects R.tsv [--state S.json [--ref SNAPSHOT.png]]
        """)
    }
}
