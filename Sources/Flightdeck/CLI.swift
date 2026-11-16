import Foundation
import FlightdeckCore

/// Command-line interface of the app binary (Flightdeck.app/Contents/MacOS/Flightdeck):
///   --snapshot [--json] [--top N]   one warmed-up sample: summary + findings (or full JSON)
///   --findings                      current findings only
///   --csv <trace> <out.csv> [--processes]
///   --report <trace> <out.pdf>
///   --stats <trace>                 summary statistics of a recording
@MainActor
enum CLI {
    static let usage = """
    Flightdeck command line
      --snapshot [--json] [--top N]   sample the system once (after a 1 s warm-up) and print a summary or JSON
      --findings                      print current findings (what's wrong right now)
      --stats <trace.flightlog>       summary statistics and findings of a recording
      --csv <trace> <out.csv> [--processes]   export system (or per-process) metrics
      --report <trace> <out.pdf>      write a PDF flight report
      --help
    """

    static func handle() {
        let a = CommandLine.arguments
        func value(_ flag: String, _ n: Int = 1) -> [String]? {
            guard let i = a.firstIndex(of: flag), i + n < a.count else { return nil }
            return Array(a[(i + 1)...(i + n)])
        }
        if a.contains("--help") { print(usage); exit(0) }
        if a.contains("--bench-ui") { UIBench.run(renders: Int(value("--bench-ui")?.first ?? "") ?? 20) }
        if a.contains("--snapshot") || a.contains("--findings") {
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

    static func warmSample() -> Snapshot {
        let sampler = Sampler(); _ = sampler.sample(); Thread.sleep(forTimeInterval: 1); return sampler.sample()
    }

    static func load(_ path: String) -> Trace? {
        do { return try Trace.read(from: URL(fileURLWithPath: path)) } catch { fail("can't read \(path): \(error.localizedDescription)") }
    }

    static func write(_ d: Data, to path: String) -> Never {
        do { try d.write(to: URL(fileURLWithPath: path)); print("wrote \(path)"); exit(0) } catch { fail(error.localizedDescription) }
    }

    static func fail(_ msg: String) -> Never { FileHandle.standardError.write(Data("flightdeck: \(msg)\n".utf8)); exit(1) }

    static func printSummary(_ s: Snapshot, top: Int) {
        func m(_ v: Double?, _ f: String) -> String { v.map { String(format: f, $0) } ?? "—" }
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

struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ v: Encodable) { value = v }
    func encode(to e: Encoder) throws { try value.encode(to: e) }
}
