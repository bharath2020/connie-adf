import Foundation
import Testing
import Darwin
import ADFModel
import ADFPreparation

/// T0 work probe (parse/prepare tier, macOS or simulator): instructions
/// retired by `ADFParser.parse` and `DocumentPreparer.prepare` (default
/// theme) on every repo fixture, plus allocations, no UI. Compared between
/// two refs by `Scripts/perf-probe.sh` (tier `parse`).
///
/// Opt-in: `PERF_PROBE=1 swift test --filter ParsePreparePerfTests`. One
/// JSON line per fixture, printed after `PERF_PROBE ` and appended to
/// `PERF_PROBE_OUT` when set. Knobs: `PERF_PROBE_PARSE_REPS` (3),
/// `PERF_PROBE_WARMUPS` (1), `PERF_PROBE_MALLOC_REPS` (1),
/// `PERF_PROBE_PARSE_FIXTURES` (comma-separated fixture names without
/// `.json`), `PERF_PROBE_LABEL`.
@Suite("T0 work probe: parse and prepare", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PERF_PROBE"] != nil
                    || ProcessInfo.processInfo.environment["PERF_PROBE_OUT"] != nil,
                "opt-in: PERF_PROBE=1"))
struct ParsePreparePerfTests {
    struct Rep {
        var parse: Double?
        var prepare: Double?
        var cpuMs: Double
        var blocks: Int
        var mallocsParse: Int?
        var mallocsPrepare: Int?
    }

    @Test("instructions retired by parse and prepare, every fixture")
    func parsePrepare() async throws {
        let environment = ProcessInfo.processInfo.environment
        func int(_ key: String, _ fallback: Int, minimum: Int) -> Int {
            environment[key].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map { max(minimum, $0) } ?? fallback
        }
        let reps = int("PERF_PROBE_PARSE_REPS", 3, minimum: 1)
        let warmups = int("PERF_PROBE_WARMUPS", 1, minimum: 0)
        let mallocReps = int("PERF_PROBE_MALLOC_REPS", 1, minimum: 0)
        var only: Set<String>?
        if let list = environment["PERF_PROBE_PARSE_FIXTURES"], !list.isEmpty {
            only = Set(list.split(separator: ",").map { String($0) })
        }
        let label = environment["PERF_PROBE_LABEL"].flatMap { $0.isEmpty ? nil : $0 }
        let outPath = environment["PERF_PROBE_OUT"].flatMap { $0.isEmpty ? nil : $0 }

        let names = try Self.fixtureNames().filter { only?.contains($0) ?? true }
        try #require(!names.isEmpty, "no fixture matched")
        for name in names {
            let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("\(name).json"))
            for _ in 0..<warmups { _ = try await Self.rep(data, countMallocs: false) }
            var measured: [Rep] = []
            for _ in 0..<reps { measured.append(try await Self.rep(data, countMallocs: false)) }
            var counted: [Rep] = []
            for _ in 0..<mallocReps { counted.append(try await Self.rep(data, countMallocs: true)) }

            var line: [String: Any] = [
                "schema": 1,
                "tier": "parse",
                "fixture": name,
                "renderer": "-",
                "source": "\(name).json",
                "fixture_bytes": data.count,
                "fixture_fnv64": Self.fnv64(data),
                "reps": measured.count,
                "warmups": warmups,
                "counts": ["blocks": measured[0].blocks],
                "counts_unstable": Set(measured.map(\.blocks)).count > 1 ? ["blocks"] : [String](),
                "env": ["os": Self.osVersion, "config": Self.configuration] as [String: Any],
            ]
            if let label { line["label"] = label }
            let parse = measured.compactMap(\.parse), prepare = measured.compactMap(\.prepare)
            if parse.count == measured.count, prepare.count == measured.count {
                if let stats = Self.summary(zip(parse, prepare).map { $0 + $1 }) { line["instructions"] = stats }
                if let stats = Self.summary(parse) { line["instructions_parse"] = stats }
                if let stats = Self.summary(prepare) { line["instructions_prepare"] = stats }
            }
            if let stats = Self.summary(measured.map(\.cpuMs)) { line["cpu_ms"] = stats }
            let mallocsParse = counted.compactMap(\.mallocsParse), mallocsPrepare = counted.compactMap(\.mallocsPrepare)
            if !mallocsParse.isEmpty, !mallocsPrepare.isEmpty {
                let parseMedian = Self.intMedian(mallocsParse), prepareMedian = Self.intMedian(mallocsPrepare)
                line["mallocs"] = ["all": parseMedian + prepareMedian, "parse": parseMedian, "prepare": prepareMedian, "reps": counted.count]
            }
            Self.emit(line, to: outPath)
        }
    }

    // MARK: - Measurement

    static func rep(_ data: Data, countMallocs: Bool) async throws -> Rep {
        let cpu0 = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        if countMallocs { Malloc.start() }
        let i0 = Rusage.instructions()
        let document = try await ADFParser().parse(data)
        let i1 = Rusage.instructions()
        let mallocsParse = countMallocs ? Malloc.read() : nil
        let blocks = DocumentPreparer(theme: .default).prepare(document)
        let i2 = Rusage.instructions()
        let mallocsAll = countMallocs ? Malloc.stop() : nil
        let cpu2 = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        func delta(_ start: UInt64?, _ end: UInt64?) -> Double? {
            guard let start, let end, end >= start else { return nil }
            return Double(end - start)
        }
        return Rep(
            parse: delta(i0, i1), prepare: delta(i1, i2), cpuMs: Double(cpu2 &- cpu0) / 1e6, blocks: blocks.count,
            mallocsParse: mallocsParse, mallocsPrepare: mallocsAll.flatMap { all in mallocsParse.map { all - $0 } }
        )
    }

    /// `proc_pid_rusage` (`RUSAGE_INFO_V4`) looked up at run time: libproc
    /// is not declared in the simulator SDK, and one path serves both.
    enum Rusage {
        typealias ProcPidRusage = @convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Int32
        static let function: ProcPidRusage? =
            dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_pid_rusage").map { unsafeBitCast($0, to: ProcPidRusage.self) }

        static func instructions() -> UInt64? {
            guard let function else { return nil }
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) {
                function(getpid(), Int32(RUSAGE_INFO_V4), UnsafeMutableRawPointer($0))
            }
            return status == 0 ? info.ri_instructions : nil
        }
    }

    /// All-thread allocation count through `malloc_logger` (parsing may run
    /// off the calling thread). The callback only bumps a preallocated
    /// integer: anything else inside malloc can deadlock the runtime.
    enum Malloc {
        typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
        nonisolated(unsafe) static let total: UnsafeMutablePointer<Int> = {
            let buffer = UnsafeMutablePointer<Int>.allocate(capacity: 1)
            buffer.initialize(to: 0)
            return buffer
        }()
        nonisolated(unsafe) static let slot: UnsafeMutablePointer<Logger?>? =
            dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger")?.assumingMemoryBound(to: Logger?.self)

        static let logger: Logger = { type, _, _, _, _, _ in
            guard type & 2 != 0 else { return }
            Malloc.total.pointee &+= 1
        }

        static func start() {
            _ = total
            total.pointee = 0
            slot?.pointee = logger
        }

        static func read() -> Int? { slot == nil ? nil : total.pointee }

        static func stop() -> Int? {
            guard let slot else { return nil }
            slot.pointee = nil
            return total.pointee
        }
    }

    // MARK: - Fixtures and output

    /// The repo-root `Fixtures/` directory (this file is in
    /// `Tests/ADFPreparationTests/Perf/`).
    static var fixtures: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Fixtures")
    }

    static func fixtureNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixtures.path)
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }

    static func fnv64(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        data.withUnsafeBytes { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        return String(hash, radix: 16)
    }

    static func summary(_ values: [Double]) -> [String: Any]? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        let median = sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.count > 1
            ? values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1) : 0
        let cv = mean > 0 ? variance.squareRoot() / mean * 100 : 0
        return [
            "median": median, "min": sorted[0], "max": sorted[sorted.count - 1],
            "cv_pct": (cv * 1_000).rounded() / 1_000, "samples": values,
        ]
    }

    static func intMedian(_ values: [Int]) -> Int {
        values.sorted()[values.count / 2]
    }

    static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static var configuration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    static func emit(_ object: [String: Any], to path: String?) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            Issue.record("perf probe: line is not valid JSON: \(object)")
            return
        }
        print("PERF_PROBE \(text)")
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            Issue.record("perf probe: cannot write \(path)")
            return
        }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data((text + "\n").utf8))
    }
}
