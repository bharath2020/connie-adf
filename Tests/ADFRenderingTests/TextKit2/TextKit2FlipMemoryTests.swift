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
                    let traffic = try await Self.counting {
                        if switches {
                            host.rootView = ADFDocumentView(model: model, mediaProvider: TextKit2DiagnosticsTests.NoMedia(), textRenderer: renderer)
                        }
                        try await TextKit2DiagnosticsTests.settle(window)
                        TextKit2DiagnosticsTests.render(window)
                    }
                    if renderer == .textKit2 {
                        liveOn = TextKit2Diagnostics.shared.liveRowCount
                        for i in 0..<3 { on.bytes[i] += traffic.bytes[i]; on.count[i] += traffic.count[i] }
                    } else {
                        for i in 0..<3 { off.bytes[i] += traffic.bytes[i]; off.count[i] += traffic.count[i] }
                    }
                }
                footprints.append(Self.footprintKB() - start)
            }
            window.isHidden = true
            window.rootViewController = nil
            print("TK2 switch memory \(series): live TK2 rows ON \(liveOn); ten ON switches: \(on); ten OFF switches: \(off); raw footprint vs start after each pair (KB): \(footprints)")
        }
    }
}

/// Counts allocations by size class through `malloc_logger` (the stack
/// logging hook; no allocation inside the callback).
enum MallocCounter {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
    nonisolated(unsafe) static var bytes: (Int, Int, Int) = (0, 0, 0)
    nonisolated(unsafe) static var counts: (Int, Int, Int) = (0, 0, 0)
    nonisolated(unsafe) static var slot: UnsafeMutablePointer<Logger?>? = {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger")?.assumingMemoryBound(to: Logger?.self)
    }()

    static let logger: Logger = { type, _, size, newSize, _, _ in
        let allocate = type & 2 != 0, deallocate = type & 4 != 0
        guard allocate else { return }
        let bytes = Int(deallocate ? newSize : size)
        switch bytes {
        case ...1_008: MallocCounter.bytes.0 += bytes; MallocCounter.counts.0 += 1
        case ...(32 * 1_024): MallocCounter.bytes.1 += bytes; MallocCounter.counts.1 += 1
        default: MallocCounter.bytes.2 += bytes; MallocCounter.counts.2 += 1
        }
    }

    static func reset() { bytes = (0, 0, 0); counts = (0, 0, 0) }
    static func install() { slot?.pointee = logger }
    static func uninstall() { slot?.pointee = nil }
    static func snapshot() -> TextKit2FlipMemoryTests.Traffic {
        TextKit2FlipMemoryTests.Traffic(bytes: [bytes.0, bytes.1, bytes.2], count: [counts.0, counts.1, counts.2])
    }
}
#endif
