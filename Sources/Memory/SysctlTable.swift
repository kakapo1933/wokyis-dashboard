// SysctlTable.swift — MIB pre-resolution, per-MIB failure isolation, --break-mib (spec §5.1, §5.2, §11).
// Every name is resolved ONCE with sysctlnametomib at init; each read is one sysctl(2) on the cached MIB.
// A name that failed to resolve (really missing, or --break-mib → resolved as "bogus.<name>" → real ENOENT)
// fails only its own reads (`.errno(e, name)`); every other MIB keeps working.
// `vm.swapusage` (struct xsw_usage) is resolved and read separately (`readSwapUsed`), subject to --break-mib too.
// Owner: memory agent.
import Foundation

struct SysctlTable: Sendable {
    /// Every scalar MIB the sampler reads each tick (spec §5.2). `vm.swapusage` (struct xsw_usage) is read separately.
    static let standardNames: [String] = [
        "hw.pagesize", "hw.memsize",
        "vm.page_free_count", "vm.page_free_cpu_count",
        "vm.mte.free.kernel_tagged", "vm.mte.free.cpu_claimed", "vm.mte.free.cpu_kernel_tagged", "vm.mte.cell.inactive",
        "vm.page_pageable_external_count", "vm.page_cpu_pageable_external_count",
        "vm.page_purgeable_count", "vm.page_purgeable_wired_count",
        "vm.page_pageable_internal_count", "vm.page_cpu_pageable_internal_count",
        "vm.page_wired_count", "vm.page_throttled_count",
        "vm.mte.compress_ts_pages_used", "vm.mte.compress_non_ts_pages_used",
        "kern.memorystatus_level", "kern.memorystatus_vm_pressure_level",
    ]
    static let swapName = "vm.swapusage"

    private struct Entry: Sendable { let mib: [Int32]; let err: Int32 }   // mib empty ⇔ err != 0

    let names: [String]
    let broken: Set<String>
    private let entries: [String: Entry]
    private let swapEntry: Entry

    /// broken: names from --break-mib → resolved as "bogus.<name>" so resolution really fails (ENOENT).
    init(names: [String], broken: Set<String>) {
        self.names = names; self.broken = broken
        var e: [String: Entry] = [:]
        for n in names where e[n] == nil { e[n] = SysctlTable.resolve(n, broken: broken.contains(n)) }
        entries = e
        swapEntry = SysctlTable.resolve(SysctlTable.swapName, broken: broken.contains(SysctlTable.swapName))
    }

    private static func resolve(_ name: String, broken: Bool) -> Entry {
        let lookup = broken ? "bogus." + name : name
        var mib = [Int32](repeating: 0, count: Int(CTL_MAXNAME))
        var len = mib.count
        if sysctlnametomib(lookup, &mib, &len) == 0 { return Entry(mib: Array(mib[0..<len]), err: 0) }
        let e = errno
        return Entry(mib: [], err: e == 0 ? ENOENT : e)
    }

    /// Number of `names` whose MIB resolved at init (START line `mibs=resolved/total`).
    var resolvedCount: Int { names.filter { entries[$0]?.err == 0 }.count }
    /// Names that failed to resolve (for the START-time WARN line).
    var unresolved: [String] { names.filter { (entries[$0]?.err ?? ENOENT) != 0 } + (swapEntry.err != 0 ? [SysctlTable.swapName] : []) }

    /// One scalar read. 4-byte values are sign-extended from Int32, 8-byte values taken as Int64.
    func read(_ name: String) -> Result<Int64, SourceError> {
        guard let en = entries[name] else { return .failure(.errno(ENOENT, name)) }
        guard en.err == 0 else { return .failure(.errno(en.err, name)) }
        var buf: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        var mib = en.mib
        let r = mib.withUnsafeMutableBufferPointer { p in sysctl(p.baseAddress, UInt32(p.count), &buf, &len, nil, 0) }
        if r != 0 { return .failure(.errno(errno, name)) }
        switch len {
        case 4: return .success(Int64(Int32(truncatingIfNeeded: buf & 0xFFFF_FFFF)))
        case 8: return .success(Int64(bitPattern: buf))
        default: return .failure(.parse("\(name) len=\(len)"))
        }
    }

    /// `vm.swapusage` → xsu_used (bytes).
    func readSwapUsed() -> Result<Int64, SourceError> {
        guard swapEntry.err == 0 else { return .failure(.errno(swapEntry.err, SysctlTable.swapName)) }
        var sw = xsw_usage()
        var len = MemoryLayout<xsw_usage>.size
        var mib = swapEntry.mib
        let r = mib.withUnsafeMutableBufferPointer { p in sysctl(p.baseAddress, UInt32(p.count), &sw, &len, nil, 0) }
        if r != 0 { return .failure(.errno(errno, SysctlTable.swapName)) }
        return .success(Int64(bitPattern: sw.xsu_used))
    }
}
