// Command-line modes of the app binary. `FlightDeckApp.init` calls `CLI.handle()`; every recognised mode prints its
// output and exits before any window or the Engine is created. With no recognised flag, `handle()` returns and the GUI
// starts normally (so does a mode whose arguments are missing or incomplete).
import Foundation
import FlightDeckCore

/// Command-line interface of the app binary (FlightDeck.app/Contents/MacOS/FlightDeck):
///   --snapshot [--json] [--top N]   one warmed-up sample: summary + findings (or full JSON)
///   --findings [--json]             current findings only
///   --csv <trace> <out.csv> [--processes]
///   --report <trace> <out.pdf>
///   --stats <trace>                 summary statistics of a recording
///   --json-stream [interval] [--top N]   one JSON snapshot per line, every `interval` seconds, until killed
/// Developer-only (not in `usage`): --render-views <dir> and --bench-ui [renders], see UIBench.
@MainActor
enum CLI {
    static let usage = """
    FlightDeck command line
      --snapshot [--json] [--top N]   sample the system once (after a 1 s warm-up) and print a summary or JSON
      --findings                      print current findings (what's wrong right now)
      --json-stream [seconds] [--top N]   print one JSON snapshot per line every `seconds` (default 1) until
                                      interrupted; --top keeps only the N busiest processes per line
      --stats <trace.flightlog>       summary statistics and findings of a recording
      --csv <trace> <out.csv> [--processes]   export system (or per-process) metrics
      --report <trace> <out.pdf>      write a PDF flight report
      --help
    """

    /// Parses `CommandLine.arguments` and runs the first matching mode. Does not return if a mode ran.
    static func handle() {
        let a = CommandLine.arguments
        // The `n` arguments following `flag`, or nil if the flag is absent or too few arguments follow it.
        func value(_ flag: String, _ n: Int = 1) -> [String]? {
            guard let i = a.firstIndex(of: flag), i + n < a.count else { return nil }
            return Array(a[(i + 1)...(i + n)])
        }
        if a.contains("--help") { print(usage); exit(0) }
        // A mistyped flag or a missing argument must not silently open the GUI instead. (Single-dash arguments are
        // left alone: macOS and the automation hooks pass those, e.g. -destination, -NSDocumentRevisionsDebugMode.)
        let known: [String: Int] = ["--snapshot": 0, "--json": 0, "--findings": 0, "--processes": 0, "--top": 1, "--stats": 1, "--csv": 2,
                                    "--report": 2, "--json-stream": 0, "--render-views": 1, "--bench-ui": 0, "--render-iconset": 1, "--render-dock-previews": 1]
        for (i, arg) in a.enumerated().dropFirst() where arg.hasPrefix("--") {
            guard let n = known[arg] else { fail("unknown option \(arg)\n\n\(usage)") }
            if n > 0 && (i + n >= a.count || a[(i + 1)...(i + n)].contains { $0.hasPrefix("--") }) && arg != "--bench-ui" {
                fail("\(arg) needs \(n) argument\(n == 1 ? "" : "s")\n\n\(usage)")
            }
        }
        if let v = value("--render-views") { UIBench.renderViews(to: v[0]) }
        if a.contains("--json-stream") { jsonStream(a) }
        if a.contains("--bench-ui") { UIBench.run(renders: Int(value("--bench-ui")?.first ?? "") ?? 20) }
        if a.contains("--snapshot") || a.contains("--findings") {
            // CLI findings come from a single sample, so only instantaneous conditions are found; "sustained for N
            // minutes" findings need the long-running app.
            let s = warmSample()
            let findings = Analyzer().ingest(s)
            if a.contains("--json") {
                let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
                struct Out: Encodable { var snapshot: Snapshot; var findings: [Finding] }
                let data = (try? enc.encode(a.contains("--findings") ? AnyEncodable(findings) : AnyEncodable(Out(snapshot: s, findings: findings)))) ?? Data()
                FileHandle.standardOutput.write(data); print("")
            } else if a.contains("--findings") {
                printFindings(findings)
            } else {
                printSummary(s, top: Int(value("--top")?.first ?? "") ?? 10); printFindings(findings)
            }
            exit(0)
        }
        if let v = value("--stats"), let t = load(v[0]) {
            let st = TraceStats.compute(t)
            print("\(t.host) · \(st.frames) samples · \(st.start.formatted()) – \(st.end.formatted())")
            for (k, s, f) in [("CPU %", st.cpu, "%.1f"), ("Mem pressure %", st.pressure, "%.1f"), ("Power W", st.watts, "%.1f"), ("Hottest °C", st.hottest, "%.1f")] {
                if let s { print(k.padding(toLength: 16, withPad: " ", startingAt: 0) + String(format: " avg \(f)  p95 \(f)  peak \(f)", s.avg, s.p95, s.peak)) }
            }
            print("Top CPU: " + st.topCPU.prefix(5).map { String(format: "%@ %.1f%%", $0.name, $0.avg) }.joined(separator: ", "))
            for i in st.findings { print("  \(i.start.formatted(date: .omitted, time: .standard))  \(i.title)  (\(Int(i.duration)) s)") }
            exit(0)
        }
        if let v = value("--csv", 2), let t = load(v[0]) {
            let csv = a.contains("--processes") ? TraceExport.processCSV(t) : TraceExport.systemCSV(t)
            write(Data(csv.utf8), to: v[1])
        }
        if let v = value("--report", 2), let t = load(v[0]) {
            guard let pdf = FlightReportView.pdf(t) else { fail("could not render the report") }
            write(pdf, to: v[1])
        }
    }

    /// `--json-stream [interval] [--top N]`: samples forever, writing each snapshot as one line of compact JSON (keys
    /// sorted, ISO 8601 times) so scripts can read it with `jq` or line by line. The interval is an optional bare number
    /// after the flag (0.25 s minimum). Unmeasured values encode as `{"unavailable":…}`, as in `--snapshot --json`.
    /// Ends when stdout is closed (the default SIGPIPE action exits quietly, e.g. under `| head`) or on Ctrl-C.
    static func jsonStream(_ a: [String]) -> Never {
        var interval = 1.0
        if let i = a.firstIndex(of: "--json-stream"), i + 1 < a.count, !a[i + 1].hasPrefix("-") {
            guard let v = Double(a[i + 1]), v.isFinite, v > 0 else { fail("--json-stream: interval must be a number of seconds") }
            interval = max(v, 0.25)
        }
        let top = a.firstIndex(of: "--top").flatMap { $0 + 1 < a.count ? Int(a[$0 + 1]) : nil }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]; enc.dateEncodingStrategy = .iso8601
        let sampler = Sampler(); _ = sampler.sample()   // primes the delta-based counters; the first line is already real
        let out = FileHandle.standardOutput
        var next = Date().addingTimeInterval(interval)
        while true {
            // Sleep to a fixed schedule rather than "interval after the last write", so sampling cost doesn't add drift.
            Thread.sleep(until: next); next = max(next.addingTimeInterval(interval), Date())
            var s = sampler.sample()
            if let top { s.processes = Array(s.processes.sorted { $0.cpu > $1.cpu }.prefix(max(top, 0))) }
            guard var d = try? enc.encode(s) else { continue }
            d.append(0x0A)
            out.write(d)
        }
    }

    /// Two samples a second apart: delta-based values (CPU %, disk/network rates) are unavailable in the first one.
    static func warmSample() -> Snapshot {
        let sampler = Sampler(); _ = sampler.sample(); Thread.sleep(forTimeInterval: 1); return sampler.sample()
    }

    /// Reads a trace file, exiting with an error message if it can't be read.
    static func load(_ path: String) -> Trace? {
        do { return try Trace.read(from: URL(fileURLWithPath: path)) } catch { fail("can't read \(path): \(error.localizedDescription)") }
    }

    /// Writes the output file and exits (0 on success, 1 with a message on failure).
    static func write(_ d: Data, to path: String) -> Never {
        do { try d.write(to: URL(fileURLWithPath: path)); print("wrote \(path)"); exit(0) } catch { fail(error.localizedDescription) }
    }

    static func fail(_ msg: String) -> Never { FileHandle.standardError.write(Data("flightdeck: \(msg)\n".utf8)); exit(1) }

    /// Human-readable one-sample summary plus the top apps by CPU. Unmeasured values print as "—", never as 0.
    static func printSummary(_ s: Snapshot, top: Int) {
        func m(_ v: Double?, _ f: String) -> String { v.map { String(format: f, $0) } ?? "—" }
        // CPU % is "% of all cores" here; per-app CPU below is "% of one core" (can exceed 100).
        print("CPU \(m(s.cpu.total.value, "%.1f%%"))  load \(s.cpu.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " "))")
        print("Memory \(Fmt.bytes(s.memory.used)) of \(Fmt.bytes(s.memory.total))  pressure \(m(s.memory.pressure.value, "%.0f%%"))  swap \(s.memory.swapUsed.value.map(Fmt.bytes) ?? "—")")
        print("Disk R \(s.disk.readBps.value.map(Fmt.rate) ?? "—")  W \(s.disk.writeBps.value.map(Fmt.rate) ?? "—")   Net ↓ \(s.network.inBps.value.map(Fmt.rate) ?? "—")  ↑ \(s.network.outBps.value.map(Fmt.rate) ?? "—")")
        print("Power \(m(s.power.systemWatts.value, "%.1f W"))  hottest \(m(s.power.hottest.value, "%.0f °C"))  thermal \(["Nominal", "Fair", "Serious", "Critical"][min(s.power.thermalState, 3)])  GPU \(m(s.gpu.value, "%.0f%%"))")
        print("")
        func l(_ x: String, _ w: Int) -> String { x.count >= w ? String(x.prefix(w)) : x + String(repeating: " ", count: w - x.count) }
        func r(_ x: String, _ w: Int) -> String { x.count >= w ? x : String(repeating: " ", count: w - x.count) + x }
        print(l("APP", 34) + r("CPU%", 8) + r("MEMORY", 11) + r("PROCS", 7))
        for a in AppUsage.aggregate(s.processes).sorted(by: { $0.cpu > $1.cpu }).prefix(top) {
            print(l(a.name, 34) + r(String(format: "%.1f", a.cpu), 8) + r(Fmt.bytes(a.memory), 11) + r("\(a.processes)", 7))
        }
    }

    static func printFindings(_ f: [Finding]) {
        print("")
        if f.isEmpty { print("All systems normal."); return }
        for x in f { print("[\(["", "INFO", "CAUTION", "WARNING"][x.severity.rawValue])] \(x.title)" + (x.detail.map { "\n    \($0)" } ?? "")) }
    }
}

/// Type-erases an Encodable so `--json` can encode either the findings array or the snapshot+findings struct.
struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ v: Encodable) { value = v }
    func encode(to e: Encoder) throws { try value.encode(to: e) }
}
