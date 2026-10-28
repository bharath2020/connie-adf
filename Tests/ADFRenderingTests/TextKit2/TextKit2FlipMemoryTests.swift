#if canImport(UIKit)
import SwiftUI
import UIKit
import Testing
import Darwin
import ADFPreparation
@testable import ADFRendering

/// Attribution for the §3.6 twenty-flip memory check (raw settled
/// footprint within 5 MB of the SwiftUI control): what each renderer
/// switch allocates, by malloc size class, through the real document view
/// on stress-5k. Three series of ten switch pairs each:
///
/// - `textKit2`: SwiftUI ↔ TextKit 2 (eligible rows become TK2 rows);
/// - `mechanism`: the same switches on a theme no text is eligible under,
///   so only the switch itself runs (environment change, row bodies);
/// - `idle`: the same settle cycles with no switch.
///
/// A diagnostic, not a gate (`TK2_FLIP_MEMORY=1`, simulator:
/// `TEST_RUNNER_TK2_FLIP_MEMORY=1`): it prints allocation traffic per
/// switch direction and the raw `phys_footprint` after each pair. The
/// difference between the first two series is what TextKit 2 rows cost per
/// switch; the free-but-dirty pages the raw figure keeps scale with it.
@Suite("TextKit 2 switch memory", .serialized, .enabled(if: ProcessInfo.processInfo.environment["TK2_FLIP_MEMORY"] != nil))
@MainActor
struct TextKit2FlipMemoryTests {
    struct Traffic: CustomStringConvertible {
        var bytes = [Int](repeating: 0, count: 3)
        var count = [Int](repeating: 0, count: 3)
        var description: String {
            zip(["tiny", "small", "large"], zip(bytes, count))
                .map { String(format: "%@ %.0f KB/%d", $0, Double($1.0) / 1024, $1.1) }
                .joined(separator: " ")
        }
    }

    static func footprintKB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) / 1024 : -1
    }

    static func model(theme: ADFTheme) async throws -> ADFDocumentModel {
        let model = ADFDocumentModel(theme: theme)
        model.load(data: try TextKit2FixtureSweepTests.fixtureData("stress-5k"))
        for _ in 0..<1_000 where model.phase != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.phase == .ready)
        return model
    }

    /// Runs `body` with every allocation counted by size class.
    static func counting(_ body: () async throws -> Void) async rethrows -> Traffic {
        MallocCounter.reset()
        MallocCounter.install()
        defer { MallocCounter.uninstall() }
        try await body()
        return MallocCounter.snapshot()
    }

    @Test("allocation traffic and raw footprint per renderer switch (stress-5k)")
    func switchTraffic() async throws {
        let undescribable = ADFTheme(body: .custom("Georgia", size: 17))
        let sampleStacks = ProcessInfo.processInfo.environment["TK2_FLIP_MEMORY"] == "stacks"
        for (series, theme, switches) in [("textKit2", ADFTheme.default, true), ("mechanism", undescribable, true), ("idle", .default, false)] {
            let model = try await Self.model(theme: theme)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            let host = UIHostingController(rootView: ADFDocumentView(model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: .swiftUI))
            window.rootViewController = host
            window.isHidden = false
            try await TextKit2DiagnosticsTests.settle(window)
            // Warm-up pair, not counted.
            for renderer in [ADFTextRenderer.textKit2, .swiftUI] where switches {
                host.rootView = ADFDocumentView(model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: renderer)
                try await TextKit2DiagnosticsTests.settle(window)
            }
            let start = Self.footprintKB()
            var on = Traffic(), off = Traffic(), footprints: [Int] = []
            var liveOn = 0
            for _ in 0..<10 {
                for renderer in [ADFTextRenderer.textKit2, .swiftUI] {
                    MallocCounter.sampling.pointee = series == "textKit2" && sampleStacks && renderer == .textKit2
                    let traffic = try await Self.counting {
                        if switches {
                            host.rootView = ADFDocumentView(model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: renderer)
                        }
                        try await TextKit2DiagnosticsTests.settle(window)
                        TextKit2DiagnosticsTests.render(window)
                    }
                    MallocCounter.sampling.pointee = false
                    if renderer == .textKit2 {
                        liveOn = TextKit2FallbackTests.rows(in: host.view).count
                        for i in 0..<3 { on.bytes[i] += traffic.bytes[i]; on.count[i] += traffic.count[i] }
                    } else {
                        for i in 0..<3 { off.bytes[i] += traffic.bytes[i]; off.count[i] += traffic.count[i] }
                    }
                }
                footprints.append(Self.footprintKB() - start)
            }
            window.isHidden = true
            window.rootViewController = nil
            if series == "textKit2", sampleStacks { print("TK2 switch memory stacks (ten ON switches)\n" + MallocCounter.sampleReport()) }
            print("TK2 switch memory \(series): live TK2 rows ON \(liveOn); ten ON switches: \(on); ten OFF switches: \(off); raw footprint vs start after each pair (KB): \(footprints)")
        }
    }
}

/// Counts allocations by size class through `malloc_logger` (the stack
/// logging hook). The callback runs inside malloc, so it touches only a
/// preallocated buffer with plain integer arithmetic: anything that needs
/// Swift metadata at that point (a generic, a tuple, a range pattern)
/// re-enters the runtime's metadata lock and aborts. Counts from other
/// threads may race; the figures are approximate.
enum MallocCounter {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
    /// Bytes [tiny, small, large], then counts [tiny, small, large].
    nonisolated(unsafe) static let totals: UnsafeMutablePointer<Int> = {
        let buffer = UnsafeMutablePointer<Int>.allocate(capacity: 6)
        buffer.initialize(repeating: 0, count: 6)
        return buffer
    }()
    nonisolated(unsafe) static let slot: UnsafeMutablePointer<Logger?>? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger")?.assumingMemoryBound(to: Logger?.self)

    /// Call-stack samples (main thread, tiny and small, one in `stride`):
    /// `sampleCapacity` records of a size followed by `depth` return
    /// addresses, filled by `backtrace`, which does not allocate.
    static let depth = 40, sampleCapacity = 40_000, stride = 4
    /// Whether to sample stacks; a buffer, not a `var`: a stored `var`
    /// read goes through exclusivity checking, which allocates per thread.
    nonisolated(unsafe) static let sampling: UnsafeMutablePointer<Bool> = {
        let flag = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        flag.initialize(to: false)
        return flag
    }()
    nonisolated(unsafe) static let samples: UnsafeMutablePointer<UInt> = {
        let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: sampleCapacity * (depth + 1) + 2)
        buffer.initialize(repeating: 0, count: sampleCapacity * (depth + 1) + 2)
        return buffer
    }()

    static let logger: Logger = { type, _, size, newSize, _, _ in
        guard type & 2 != 0 else { return }
        let bytes = Int(bitPattern: type & 4 != 0 ? newSize : size)
        let index = bytes <= 1_008 ? 0 : (bytes <= 32 * 1_024 ? 1 : 2)
        let totals = MallocCounter.totals
        totals[index] &+= bytes
        totals[index + 3] &+= 1
        guard MallocCounter.sampling.pointee, index < 2, pthread_main_np() != 0 else { return }
        let samples = MallocCounter.samples
        samples[0] &+= 1
        let taken = Int(samples[1])
        guard samples[0] % UInt(MallocCounter.stride) == 0, taken < MallocCounter.sampleCapacity else { return }
        let record = samples + 2 + taken * (MallocCounter.depth + 1)
        record[0] = UInt(bytes)
        _ = backtrace(UnsafeMutablePointer(OpaquePointer(record + 1)), Int32(MallocCounter.depth))
        samples[1] = UInt(taken + 1)
    }

    /// Sampled bytes (scaled by `stride`) by the first frame outside the
    /// allocator, runtime and Foundation layers, and by the innermost
    /// ADFRendering frame on the stack.
    static func sampleReport() -> String {
        let skip = ["libsystem_malloc", "libsystem_platform", "libswiftCore", "libobjc", "CoreFoundation",
                    "Foundation", "libc++", "libdyld", "libsystem_c", "libsystem_blocks", "ADFRenderingTests",
                    "libswift_Concurrency", "libdispatch"]
        var byOwner: [String: Int] = [:], byADF: [String: Int] = [:], byPair: [String: Int] = [:]
        var names: [UInt: (image: String, symbol: String)] = [:]
        func describe(_ address: UInt) -> (image: String, symbol: String) {
            if let known = names[address] { return known }
            var info = Dl_info()
            var result = (image: "?", symbol: "?")
            if dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 {
                let path = info.dli_fname.map { String(cString: $0) } ?? "?"
                result.image = (path as NSString).lastPathComponent
                result.symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
            }
            names[address] = result
            return result
        }
        let taken = Int(samples[1])
        for i in 0..<taken {
            let record = samples + 2 + i * (depth + 1)
            let bytes = Int(record[0]) * stride
            var owner: (image: String, symbol: String)?
            var adf: String?
            for f in 1...depth where record[f] != 0 {
                let frame = describe(record[f])
                if owner == nil, !skip.contains(where: { frame.image.hasPrefix($0) }) { owner = frame }
                if adf == nil, frame.symbol.contains("ADFRendering"), !frame.symbol.contains("MallocCounter") { adf = frame.symbol }
                if owner != nil, adf != nil { break }
            }
            let ownerKey = owner.map { "\($0.image) \($0.symbol)" } ?? "?"
            byOwner[ownerKey, default: 0] += bytes
            byADF[adf ?? "(no ADFRendering frame)", default: 0] += bytes
            byPair[(adf ?? "-") + "  <=  " + ownerKey, default: 0] += bytes
        }
        func top(_ table: [String: Int], _ count: Int) -> String {
            table.sorted { $0.value > $1.value }.prefix(count)
                .map { String(format: "%8.0f KB  %@", Double($0.value) / 1024, $0.key) }.joined(separator: "\n")
        }
        return "samples \(taken) (1 in \(stride))\n-- by owner frame\n\(top(byOwner, 40))\n-- by innermost ADFRendering frame\n\(top(byADF, 30))\n-- by pair\n\(top(byPair, 40))"
    }

    static func reset() { totals.update(repeating: 0, count: 6) }
    static func install() { _ = totals; _ = samples; _ = sampling; slot?.pointee = logger }
    static func uninstall() { slot?.pointee = nil }
    static func snapshot() -> TextKit2FlipMemoryTests.Traffic {
        TextKit2FlipMemoryTests.Traffic(bytes: [totals[0], totals[1], totals[2]], count: [totals[3], totals[4], totals[5]])
    }
}
#endif
