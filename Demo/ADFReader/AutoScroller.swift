import Foundation
import SwiftUI
import ADFRendering

/// Scripted end-to-end scroll for the `-autoscroll` launch mode: waits 1s
/// after the document is ready, then walks the reader's scroll target
/// through the whole block list at roughly 1,200 pt/s with repeated
/// `withAnimation` steps while `FrameMetrics` counts frames. Prints exactly
/// one `SCROLL_METRICS …` line, then exits 2s later.
@MainActor
enum AutoScroller {
    private static let pointsPerSecond: Double = 1_200
    /// The library's scroll hook is block-ID anchored, so pacing converts
    /// points/second into blocks/step using an assumed average rendered
    /// height per top-level block.
    private static let assumedBlockHeight: Double = 50
    private static let stepSeconds: Double = 0.25

    static func run(model: ADFDocumentModel, metrics: FrameMetrics, fixtureName: String) async {
        try? await Task.sleep(for: .seconds(1))
        metrics.start()
        metrics.reset()

        let ids = model.blocks.map(\.id)
        let blocksPerStep = max(1, Int((pointsPerSecond * stepSeconds / assumedBlockHeight).rounded()))
        var index = blocksPerStep
        while index < ids.count {
            withAnimation(.linear(duration: stepSeconds)) {
                model.scrollTarget = ids[index]
            }
            try? await Task.sleep(for: .seconds(stepSeconds))
            index += blocksPerStep
        }
        if let lastID = ids.last {
            withAnimation(.linear(duration: stepSeconds)) {
                model.scrollTarget = lastID
            }
            // Let the final step's animation settle before sampling.
            try? await Task.sleep(for: .milliseconds(500))
        }

        let snapshot = metrics.snapshot()
        let hitchRatio = snapshot.elapsedSeconds > 0
            ? snapshot.hitchMilliseconds / snapshot.elapsedSeconds
            : 0
        print(
            "SCROLL_METRICS fixture=\(fixtureName) frames=\(snapshot.totalFrames) "
                + "dropped=\(snapshot.droppedFrames) "
                + "hitchRatioMsPerS=\(String(format: "%.2f", hitchRatio))"
        )
        fflush(stdout)
        try? await Task.sleep(for: .seconds(2))
        exit(0)
    }
}
