// GoldenFixture.swift — the `render.memory.golden` fixture (spec §9.3 / §10.2): the `--snapshot` fixture shape with
// LITERAL strings (AMFormat en_TW results), a fixed clock and a fixed `now`, so the rendered pixels do not depend on
// the machine's time zone, region or the current time (no EventLog.hms, localtime_r, ByteCountFormatter).
// Self-contained on purpose: it uses only the v1 PanelModel types, so tools/golden_pin.sh compiles this SAME file into
// both the frozen v1 harness (tools/golden/v1/) and the current-renderer harness and pins the hash of its state.
// Owner: foundation (golden). Changing anything here changes the pinned hash → rerun tools/golden_pin.sh.
import Foundation

enum GoldenFixture {
    static let now: Double = 1_790_000_000
    static let clock = "12:34:56"

    static func state() -> PanelState {
        let mem = MemoryDisplay(physical: .text("24.00 GB"), used: .text("18.52 GB"), cached: .text("3.41 GB"), swap: .text("39.8 MB"),
                                app: .text("7.86 GB"), wired: .text("3.07 GB"), compressed: .text("7.59 GB"),
                                pressurePercent: 48, pressureLevel: .normal)
        var hist: [PressureSample] = []
        for k in stride(from: 899, through: 0, by: -1) {
            let x = Double(k)
            let pct = (48 + 6 * sin(x / 47) + 3 * sin(x / 11)).rounded()
            hist.append(PressureSample(t: now - x, percent: pct, level: .normal, simulated: false))
        }
        let devices = [
            DeviceGroup(kind: .keyboard, name: "Magic Keyboard", ownerTag: nil, connected: true, cells: [BatteryCell(label: "鍵盤", state: .ok(100, charging: false))]),
            DeviceGroup(kind: .trackpad, name: "Magic Trackpad", ownerTag: nil, connected: true, cells: [BatteryCell(label: "軌跡板", state: .ok(85, charging: false))]),
            DeviceGroup(kind: .airpods, name: "AirPods Pro", ownerTag: nil, connected: true,
                        cells: [BatteryCell(label: "左耳", state: .ok(100, charging: false)), BatteryCell(label: "右耳", state: .ok(97, charging: false)),
                                BatteryCell(label: "充電盒", state: .ok(48, charging: true))]),
        ]
        return PanelState(memory: mem, history: hist, now: now, historyCoverage: 900, devices: devices, clock: clock)
    }
}
