import Foundation
import SwiftUI
import ADFPreparation
import ADFRendering

/// Scripted end-to-end scroll for the `-autoscroll` launch mode: waits 3s
/// after the document is ready (launch settling — nav transitions, initial
/// prefetch — must not bleed into the scroll measurement), then drives the
/// reader's scroll target through the whole block list in long linear legs
/// at ~1,200 pt/s while `FrameMetrics` counts frames. Prints exactly one
/// `SCROLL_METRICS …` line, then exits 2s later.
///
/// The library's scroll hook is block-ID anchored, so pacing needs block
/// heights. Each block's rendered height is estimated from its prepared
/// content (text length at the reader's column width, code line counts,
/// table row batches, media aspect ratios), and every animation leg covers
/// its actual estimated distance in `distance / speed` seconds — so the
/// scroll speed stays ~constant whether the document is short paragraphs or
/// 800-point table slices.
@MainActor
enum AutoScroller {
    private static let pointsPerSecond: Double = 1_200

    /// One linear animation leg per block: the next block is always inside
    /// the lazy container's materialized region, so `scrollTo` resolves its
    /// offset without synchronous materialization. (Far targets — multi-
    /// thousand-point legs — measure as 200–300 ms resolution stalls, and
    /// springy per-leg animations add velocity bursts; short linear legs
    /// approximate a user's constant-velocity fling.)

    static func run(model: ADFDocumentModel, metrics: FrameMetrics, fixtureName: String) async {
        try? await Task.sleep(for: .seconds(3))
        metrics.recordsDrops = true
        metrics.start()
        metrics.reset()

        let blocks = model.blocks
        // Prefix offsets: offsets[i] = estimated top of block i.
        var offsets: [Double] = []
        offsets.reserveCapacity(blocks.count)
        var total: Double = 0
        for block in blocks {
            offsets.append(total)
            total += BlockHeightEstimator.estimatedHeight(of: block)
        }

        var index = 0
        while index < blocks.count - 1 {
            let next = index + 1
            let distance = max(offsets[next] - offsets[index], 1)
            let duration = distance / pointsPerSecond
            model.scrollTargetAnimation = .linear(duration: duration)
            model.scrollTarget = blocks[next].id
            try? await Task.sleep(for: .seconds(duration))
            index = next
        }
        // Let the final leg's animation settle before sampling.
        try? await Task.sleep(for: .milliseconds(500))

        let snapshot = metrics.snapshot()
        let hitchRatio = snapshot.elapsedSeconds > 0
            ? snapshot.hitchMilliseconds / snapshot.elapsedSeconds
            : 0
        for line in metrics.dropLog {
            print(line)
        }
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

/// Rough per-block rendered-height model for scroll pacing. Estimates only
/// need to be the right order of magnitude — each step's duration scales
/// with its estimated distance, so errors change local speed by a few tens
/// of percent, not orders of magnitude (which is what the old fixed
/// 50 pt/block assumption did to 800-point table slices).
enum BlockHeightEstimator {
    /// Approximate text column width in points (iPhone portrait reader).
    private static let columnPoints: Double = 360
    private static let bodyLinePoints: Double = 22
    private static let bodyCharsPerLine: Double = 45

    static func estimatedHeight(of block: RenderBlock) -> Double {
        height(of: block.kind)
    }

    private static func height(of kind: RenderBlock.Kind) -> Double {
        switch kind {
        case .richText(let segments, let style):
            let lines = lineCount(chars: characterCount(of: segments), charsPerLine: bodyCharsPerLine)
            let lineHeight = style.isHeading ? headingLinePoints(style.headingLevel) : bodyLinePoints
            return Double(lines) * lineHeight + 12

        case .codeBlock(_, let code):
            let lines = max(1, String(code.characters).count(where: { $0 == "\n" }) + 1)
            return Double(lines) * 19 + 28

        case .listRows(let rows):
            return rows.reduce(0) { partial, row in
                let indent = Double(row.depth) * 24 + 28
                let charsPerLine = max(16, (columnPoints - indent) / 8)
                let lines = lineCount(chars: characterCount(of: row.segments), charsPerLine: charsPerLine)
                let trailing = row.trailingBlocks.reduce(0) { $0 + height(of: $1.kind) }
                return partial + Double(lines) * bodyLinePoints + 6 + trailing
            }

        case .panel(_, let children):
            return children.reduce(24) { $0 + height(of: $1.kind) }

        case .quote(let children):
            return children.reduce(8) { $0 + height(of: $1.kind) }

        case .divider:
            return 20

        case .tableSlice(let layout, let rows, _):
            let columnPoints = max(layout.columnWidths?.min() ?? 96, 48)
            let charsPerLine = max(8, columnPoints / 8)
            return rows.reduce(0) { partial, row in
                let tallestCell = row.cells.reduce(1) { tallest, cell in
                    let chars = cell.blocks.reduce(0) { $0 + characterCount(of: $1.kind) }
                    return max(tallest, lineCount(chars: Double(chars), charsPerLine: charsPerLine))
                }
                return partial + Double(tallestCell) * 20 + 17
            }

        case .media(let media):
            return mediaHeight(media) + (media.caption == nil ? 0 : 24)

        case .mediaStrip:
            return 132

        case .expand:
            return 48 // collapsed

        case .layoutColumns(let columns):
            return columns.reduce(0) { tallest, column in
                max(tallest, column.blocks.reduce(0) { $0 + height(of: $1.kind) })
            }

        case .card:
            return 76

        case .custom(let custom):
            switch custom.sizing {
            case .aspectRatio(let width, let height, let maxWidth):
                let boxWidth = min(maxWidth ?? columnPoints, columnPoints)
                return height / width * boxWidth + 16 // + fixed row padding
            case .scaledChrome:
                return 76
            case .reflowingText:
                return bodyLinePoints * 3
            }

        case .extensionPlaceholder(_, let body):
            return body.reduce(56) { $0 + height(of: $1.kind) }

        case .unknown:
            return 36
        }
    }

    private static func headingLinePoints(_ level: Int?) -> Double {
        switch level ?? 1 {
        case 1: return 38
        case 2: return 32
        case 3: return 27
        default: return 24
        }
    }

    private static func mediaHeight(_ media: PreparedMedia) -> Double {
        let displayWidth: Double
        if let pixelWidth = media.pixelWidth {
            displayWidth = min(pixelWidth, columnPoints)
        } else if let fraction = media.widthFraction {
            displayWidth = columnPoints * fraction
        } else {
            displayWidth = min(media.attrs.width ?? columnPoints, columnPoints)
        }
        guard let width = media.attrs.width, let height = media.attrs.height, width > 0 else {
            return 220
        }
        return height / width * displayWidth
    }

    private static func lineCount(chars: Double, charsPerLine: Double) -> Int {
        max(1, Int((chars / charsPerLine).rounded(.up)))
    }

    private static func characterCount(of segments: [InlineSegment]) -> Double {
        segments.reduce(0) { partial, segment in
            switch segment {
            case .text(let text):
                return partial + Double(text.characters.count)
            case .atom:
                return partial + 10
            }
        }
    }

    private static func characterCount(of kind: RenderBlock.Kind) -> Int {
        if case .richText(let segments, _) = kind {
            return Int(characterCount(of: segments))
        }
        return 20
    }
}
