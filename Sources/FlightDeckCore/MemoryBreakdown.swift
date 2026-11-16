import Foundation

// The inspector's on-demand "Memory breakdown": what a process's memory is made of (heap, graphics, mapped files,
// code, stacks...), split into dirty, swapped/compressed and clean pages. The numbers come from Apple's own tools:
// `/usr/bin/footprint` first (fast, and its total matches the Memory column), `vmmap --summary` as a fallback. Both only
// work for the user's own processes without root. Never run per sample: one run takes 0.1 s (footprint) to a few
// seconds (vmmap on a large app).

/// One process's memory, by VM region category. Sizes are bytes; a nil size means the tool didn't report that column
/// (for example footprint without a swapped column), never "zero".
public struct MemoryBreakdown: Sendable, Hashable {
    public enum Source: String, Sendable { case footprint = "footprint", vmmap = "vmmap" }

    /// Coarse buckets the UI shows bars for. Each tool category (e.g. "Malloc Small", "IOSurface") maps to one.
    public enum Group: String, Sendable, CaseIterable, Hashable {
        case malloc = "Heap (malloc)"
        case graphics = "Graphics and images"
        case mappedFiles = "Mapped files and shared memory"
        case code = "Code and libraries"
        case stack = "Stacks"
        case kernel = "Page tables (kernel)"
        case other = "Other"
    }

    /// One row of the tool's table.
    /// `dirty` is resident dirty memory (written by the process, must be kept in RAM or compressed/swapped);
    /// `swapped` is memory currently compressed or swapped out; `clean` is resident memory that can be dropped and
    /// re-read from disk (code, mapped files). footprint ≈ dirty + swapped.
    public struct Category: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public var name: String
        public var group: Group
        public var dirty: UInt64?
        public var swapped: UInt64?
        public var clean: UInt64?
        /// Memory the process has marked as reusable (purgeable/volatile, or malloc's reclaimable free pages).
        public var reclaimable: UInt64?
        public var regions: Int?
        /// Contribution to the process footprint: dirty + swapped (or just dirty when swap isn't reported).
        public var footprint: UInt64 { (dirty ?? 0) + (swapped ?? 0) }
    }

    /// Totals for one Group: the sum of its categories, keeping nil for columns no category reported.
    public struct GroupTotal: Sendable, Hashable, Identifiable {
        public var id: Group { group }
        public var group: Group
        public var dirty: UInt64?, swapped: UInt64?, clean: UInt64?
        public var categories: [Category]
        public var footprint: UInt64 { (dirty ?? 0) + (swapped ?? 0) }
    }

    public var source: Source
    /// The process's physical footprint and lifetime peak as the tool reported them (nil if absent from its output).
    public var footprint: UInt64?
    public var peak: UInt64?
    public var categories: [Category]

    /// Categories summed into groups, biggest footprint first. Groups with no categories are left out.
    public var groups: [GroupTotal] {
        func sum(_ cs: [Category], _ k: KeyPath<Category, UInt64?>) -> UInt64? {
            let vs = cs.compactMap { $0[keyPath: k] }
            return vs.isEmpty ? nil : vs.reduce(0, +)
        }
        return Dictionary(grouping: categories, by: \.group).map { g, cs in
            GroupTotal(group: g, dirty: sum(cs, \.dirty), swapped: sum(cs, \.swapped), clean: sum(cs, \.clean),
                       categories: cs.sorted { $0.footprint > $1.footprint })
        }.sorted { ($0.footprint, $0.clean ?? 0) > ($1.footprint, $1.clean ?? 0) }
    }

    /// Whole-process totals over all categories (nil where no category reported the column).
    public var totalDirty: UInt64? { let v = categories.compactMap(\.dirty); return v.isEmpty ? nil : v.reduce(0, +) }
    public var totalSwapped: UInt64? { let v = categories.compactMap(\.swapped); return v.isEmpty ? nil : v.reduce(0, +) }
    public var totalClean: UInt64? { let v = categories.compactMap(\.clean); return v.isEmpty ? nil : v.reduce(0, +) }

    /// Maps a tool category name to a group. The names are Apple's VM tags as printed by vmmap/footprint; matching is by
    /// substring so variants ("Malloc Small (empty)", "IOAccelerator (graphics)", "owned unmapped (graphics)") land in
    /// the same bucket. Order matters: "(graphics)" is checked before generic names.
    public static func group(of name: String) -> Group {
        let n = name.lowercased()
        if n.contains("malloc") { return .malloc }
        let graphics = ["iosurface", "ioaccelerator", "(graphics)", "coreanimation", "cg image", "cg raster", "coreui image",
                        "coreimage", "image io", "imageio", "metal", "agx", "quicklook thumbnails", "attributegraph"]
        if graphics.contains(where: n.contains) { return .graphics }
        if n.contains("mapped file") || n.contains("shared memory") { return .mappedFiles }
        if n.hasPrefix("__") || n.contains("dyld") || n.contains("shlib") || n.contains("shared cache") { return .code }
        if n.hasPrefix("stack") { return .stack }
        if n.contains("page table") { return .kernel }
        return .other
    }
}

/// Parsers for the two tools' text output, and the runner that picks one. Parsers are pure so they can be tested with
/// captured output.
public enum MemoryBreakdownReader {
    /// Why a breakdown couldn't be made, in words the inspector can show.
    public enum Failure: Error, Sendable, Equatable {
        case notOwnProcess
        case toolFailed(String)
    }

    /// Runs `footprint` (then `vmmap --summary` if footprint gives nothing usable) for `pid`. Blocking; call off the
    /// main thread. `ownedByUser` is checked first because both tools need task access, which macOS only grants for the
    /// user's own processes (and not for hardened/platform ones) without root.
    public static func read(pid: Int32, ownedByUser: Bool) -> Result<MemoryBreakdown, Failure> {
        guard ownedByUser || getuid() == 0 else { return .failure(.notOwnProcess) }
        // `-f bytes` prints exact byte counts; `--swapped` adds the compressed/swapped column.
        if let out = Shell.run("/usr/bin/footprint", ["--swapped", "-f", "bytes", "\(pid)"], timeout: 20), let b = parseFootprint(out) {
            return .success(b)
        }
        if let out = Shell.run("/usr/bin/vmmap", ["--summary", "\(pid)"], timeout: 60), let b = parseVmmapSummary(out) {
            return .success(b)
        }
        return .failure(.toolFailed("footprint and vmmap couldn't read this process. macOS refuses them for protected processes (for example Apple's own hardened apps) even when they run as you."))
    }

    /// Parses a size with an optional unit: "185139200 B", "9664 KB", "177 MB", "2.5 GB" (footprint, two tokens) or
    /// "2048K", "25.2M", "1.6G", "824" (vmmap, one token, bare numbers are bytes). Units are binary (1024-based), as both
    /// tools use. Returns nil for anything that isn't a size.
    static func size(_ number: Substring, unit: Substring? = nil) -> UInt64? {
        var digits = number, u = unit.map(String.init) ?? ""
        if unit == nil, let last = number.last, last.isLetter { digits = number.dropLast(); u = String(last) }
        guard let v = Double(digits), v >= 0 else { return nil }
        let mult: Double
        switch u.uppercased() {
        case "", "B": mult = 1
        case "K", "KB": mult = 1024
        case "M", "MB": mult = 1_048_576
        case "G", "GB": mult = 1_073_741_824
        case "T", "TB": mult = 1_099_511_627_776
        default: return nil
        }
        return UInt64((v * mult).rounded())
    }

    /// footprint's summary table. The header row names the columns ("Dirty (Swapped) Clean Reclaimable Regions
    /// Category", with optional extras such as "Wired"), each size printed as "<number> <unit>". In footprint the
    /// swapped amount is part of Dirty (hence the parentheses), so it is subtracted to get resident dirty. The TOTAL
    /// row and separator rows are skipped; "phys_footprint" and "phys_footprint_peak" come from the Auxiliary data.
    /// nil when no table was found (the tool printed an error instead).
    public static func parseFootprint(_ text: String) -> MemoryBreakdown? {
        var columns: [String]?
        var cats: [MemoryBreakdown.Category] = []
        var footprint: UInt64?, peak: UInt64?
        for line in text.split(separator: "\n") {
            let t = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard !t.isEmpty else { continue }
            if t.last == "Category", t.first == "Dirty" {
                // Size columns are everything before "Regions"; strip the parentheses from "(Swapped)".
                columns = t.prefix { $0 != "Regions" }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "()")).lowercased() }
                continue
            }
            if t.first == "phys_footprint:", t.count >= 2 { footprint = size(t[1], unit: t.count > 2 ? t[2] : nil); continue }
            if t.first == "phys_footprint_peak:", t.count >= 2 { peak = size(t[1], unit: t.count > 2 ? t[2] : nil); continue }
            guard let cols = columns, t.count >= cols.count * 2 + 2 else { continue }
            // Each size is two tokens; then the region count; the rest (which may contain spaces) is the category.
            var values: [String: UInt64] = [:]
            var ok = true
            for (i, c) in cols.enumerated() {
                guard let v = size(t[i * 2], unit: t[i * 2 + 1]) else { ok = false; break }
                values[c] = v
            }
            guard ok, let regions = Int(t[cols.count * 2]) else { continue }
            let name = t[(cols.count * 2 + 1)...].joined(separator: " ")
            if name == "TOTAL" { continue }
            let swapped = values["swapped"]
            let dirty = values["dirty"].map { d in swapped.map { d >= $0 ? d - $0 : 0 } ?? d }
            cats.append(.init(name: name, group: MemoryBreakdown.group(of: name), dirty: dirty, swapped: swapped,
                              clean: values["clean"], reclaimable: values["reclaimable"], regions: regions))
        }
        guard columns != nil, !cats.isEmpty else { return nil }
        // The header's "Footprint: N" is the same figure as phys_footprint; use it if the auxiliary block was absent.
        if footprint == nil, let r = text.range(of: #"Footprint: [0-9.]+ [KMGT]?B"#, options: .regularExpression) {
            let t = text[r].split(separator: " ")
            footprint = size(t[1], unit: t[2])
        }
        return MemoryBreakdown(source: .footprint, footprint: footprint, peak: peak, categories: cats)
    }

    /// `vmmap --summary`'s "REGION TYPE" table. Its first header line names the columns (VIRTUAL RESIDENT DIRTY
    /// SWAPPED VOLATILE NONVOL EMPTY REGION); each row is the region name (may contain spaces and parentheses) followed
    /// by one token per column, and sometimes a trailing note ("see MALLOC ZONE table below"). The row's numbers are
    /// found as the first run of `columns` consecutive size tokens. Here DIRTY is resident dirty and SWAPPED is separate;
    /// clean = RESIDENT − DIRTY. Rows with nothing resident or swapped (guard pages, reserved VM) are dropped. The table
    /// ends at its "TOTAL" row, which also keeps the MALLOC ZONE table below from being read as regions.
    public static func parseVmmapSummary(_ text: String) -> MemoryBreakdown? {
        var columns: [String]?
        var inTable = false
        var cats: [MemoryBreakdown.Category] = []
        var footprint: UInt64?, peak: UInt64?
        for line in text.split(separator: "\n") {
            let t = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard !t.isEmpty else { continue }
            // "Physical footprint:  241.5M" and "Physical footprint (peak):  300.0M"
            if line.hasPrefix("Physical footprint (peak):"), let v = t.last { peak = size(v); continue }
            if line.hasPrefix("Physical footprint:"), let v = t.last { footprint = size(v); continue }
            if columns == nil, t.first == "VIRTUAL", t.contains("RESIDENT") { columns = t.map { $0.lowercased() }; continue }
            if columns != nil, line.hasPrefix("REGION TYPE") { continue }
            if columns != nil, t.first?.allSatisfy({ $0 == "=" }) == true { inTable = true; continue }
            guard inTable, let cols = columns else { continue }
            if t.first == "TOTAL" { break }
            guard let start = (0..<t.count).first(where: { i in
                i > 0 && i + cols.count <= t.count && t[i..<(i + cols.count)].allSatisfy { size($0) != nil }
            }) else { continue }
            var values: [String: UInt64] = [:]
            for (k, c) in cols.enumerated() { values[c] = size(t[start + k]) }
            let name = t[..<start].joined(separator: " ")
            let resident = values["resident"], dirty = values["dirty"], swapped = values["swapped"]
            guard (resident ?? 0) > 0 || (swapped ?? 0) > 0 else { continue }
            let clean = resident.map { r in dirty.map { r >= $0 ? r - $0 : 0 } ?? r }
            // "REGION" heads the count column; NONVOL (non-volatile purgeable) is not reclaimable, VOLATILE is.
            cats.append(.init(name: name, group: MemoryBreakdown.group(of: name), dirty: dirty, swapped: swapped, clean: clean,
                              reclaimable: values["volatile"], regions: values["region"].map { Int($0) }))
        }
        guard !cats.isEmpty else { return nil }
        return MemoryBreakdown(source: .vmmap, footprint: footprint, peak: peak, categories: cats)
    }
}
