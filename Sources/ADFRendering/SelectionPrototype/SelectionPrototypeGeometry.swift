// PROTOTYPE — THROWAWAY CODE. Not production. Delete or absorb after verdict.
//
// This file: geometry for the selection overlay.
// - Row "beacons": passive UIViews registered per top-level block so the
//   overlay can convert between row-local and content coordinates without
//   any SwiftUI geometry reads (the UIKit view hierarchy is the source of
//   truth, queried on demand only while a selection gesture is active).
// - Shadow TextKit layout: for plain rich-text blocks (the merged single-Text
//   fast path) a parallel NSLayoutManager stack over the same string computes
//   character ↔ point mappings. SwiftUI Text and TextKit are different layout
//   engines; how closely they agree is one of the questions this prototype
//   exists to measure (debug rect overlay draws the shadow layout's rects).
//   Fonts are heuristic (semantic body/heading styles; inline bold/italic
//   runs measured at base font) — the production fix is dual-scope attributes
//   baked at preparation time.

#if os(iOS)
import UIKit
import SwiftUI
import ADFPreparation

/// Weak registry of per-row beacon views, keyed by top-level block ID.
/// Plain class (not observable): registered/unregistered by row lifecycle,
/// read on demand during selection interactions only.
@MainActor
final class PrototypeBeaconRegistry {
    private struct WeakView { weak var view: UIView? }
    private var beacons: [String: WeakView] = [:]

    func register(_ id: String, view: UIView) { beacons[id] = WeakView(view: view) }
    func unregister(_ id: String) { beacons[id] = nil }
    func view(for id: String) -> UIView? { beacons[id]?.view }

    /// The registered beacon whose frame (in `reference` coordinates)
    /// contains `point.y`, or the nearest one vertically.
    func nearestBeacon(to point: CGPoint, in reference: UIView) -> (id: String, frame: CGRect)? {
        var best: (id: String, frame: CGRect, distance: CGFloat)?
        for (id, box) in beacons {
            guard let view = box.view, view.window != nil else { continue }
            let frame = view.convert(view.bounds, to: reference)
            let distance: CGFloat
            if point.y >= frame.minY && point.y <= frame.maxY {
                distance = 0
            } else {
                distance = min(abs(point.y - frame.minY), abs(point.y - frame.maxY))
            }
            if best == nil || distance < best!.distance {
                best = (id, frame, distance)
            }
        }
        guard let best else { return nil }
        return (best.id, best.frame)
    }
}

/// Passive marker view a prototype row installs behind its block content.
struct PrototypeRowBeacon: UIViewRepresentable {
    let blockID: String
    let registry: PrototypeBeaconRegistry

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        registry.register(blockID, view: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        registry.register(blockID, view: uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {}
}

/// A rich-text unit eligible for character-precise geometry: the block's
/// merged single-Text fast path (all-text segments, leading-aligned, no
/// indentation), whose shadow string equals the unit's plainText.
struct PrototypePreciseUnit {
    let blockID: String
    let font: UIFont
}

/// Shadow TextKit layout + rect/hit-test service for the overlay.
@MainActor
final class PrototypeGeometryService {
    let registry: PrototypeBeaconRegistry
    private let text: PrototypeDocumentText
    /// unitIndex → precise descriptor, for units where character precision
    /// is attempted; all other units fall back to whole-row rects.
    private let preciseUnits: [Int: PrototypePreciseUnit]
    /// unitIndex → cached shadow layout, keyed by the width it was built at.
    private var layouts: [Int: (width: CGFloat, storage: NSTextStorage,
                                manager: NSLayoutManager, container: NSTextContainer)] = [:]

    init(text: PrototypeDocumentText, blocks: [RenderBlock]) {
        self.text = text
        self.registry = PrototypeBeaconRegistry()

        var precise: [Int: PrototypePreciseUnit] = [:]
        var styleByID: [String: TextBlockStyle] = [:]
        for block in blocks {
            if case .richText(let segments, let style) = block.kind {
                let allText = segments.allSatisfy {
                    if case .text = $0 { return true } else { return false }
                }
                if allText, style.alignment == nil, style.indentation == 0 {
                    styleByID[block.id] = style
                }
            }
        }
        for (index, unit) in text.units.enumerated() {
            guard unit.ownerID == unit.topLevelBlockID,
                  let style = styleByID[unit.ownerID] else { continue }
            precise[index] = PrototypePreciseUnit(
                blockID: unit.ownerID,
                font: Self.approximateFont(for: style)
            )
        }
        self.preciseUnits = precise
    }

    /// Heuristic UIFont for a block: mirrors ADFTheme's semantic styles.
    /// Inline bold/italic/code runs are NOT reproduced — measured drift is a
    /// prototype finding, not an oversight.
    static func approximateFont(for style: TextBlockStyle) -> UIFont {
        guard style.isHeading else {
            return .preferredFont(forTextStyle: .body)
        }
        let base: UIFont
        switch style.headingLevel ?? 1 {
        case 1: base = .preferredFont(forTextStyle: .title1)
        case 2: base = .preferredFont(forTextStyle: .title2)
        case 3: base = .preferredFont(forTextStyle: .title3)
        case 4: return .preferredFont(forTextStyle: .headline) // semibold already
        case 5: base = .preferredFont(forTextStyle: .subheadline)
        default: base = .preferredFont(forTextStyle: .footnote)
        }
        let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold)
        return descriptor.map { UIFont(descriptor: $0, size: 0) } ?? base
    }

    func isPrecise(unit: Int) -> Bool { preciseUnits[unit] != nil }

    private func beacon(forUnit unit: Int) -> UIView? {
        registry.view(for: text.units[unit].topLevelBlockID)
    }

    private func layout(forUnit unit: Int) -> (NSLayoutManager, NSTextContainer, String)? {
        guard let precise = preciseUnits[unit], let beacon = beacon(forUnit: unit) else {
            return nil
        }
        let width = beacon.bounds.width.rounded()
        guard width > 0 else { return nil }
        let plain = text.units[unit].plainText
        if let cached = layouts[unit], cached.width == width {
            return (cached.manager, cached.container, plain)
        }
        let storage = NSTextStorage(string: plain, attributes: [.font: precise.font])
        let manager = NSLayoutManager()
        manager.usesFontLeading = false
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        layouts[unit] = (width, storage, manager, container)
        return (manager, container, plain)
    }

    // MARK: Character ↔ UTF-16 conversion (per-unit strings are short)

    private func utf16Offset(fromCharacterOffset offset: Int, in string: String) -> Int {
        let index = string.index(string.startIndex, offsetBy: min(offset, string.count))
        return string.utf16.distance(from: string.utf16.startIndex, to: index)
    }

    private func characterOffset(fromUTF16 utf16: Int, in string: String) -> Int {
        guard let index = string.utf16.index(
            string.utf16.startIndex, offsetBy: utf16, limitedBy: string.utf16.endIndex
        ), let charIndex = index.samePosition(in: string) else {
            return string.count
        }
        return string.distance(from: string.startIndex, to: charIndex)
    }

    // MARK: Queries (all rects/points in `reference` view coordinates)

    /// Line rects for a local Character range of one unit. Precise units get
    /// shadow-layout line rects; everything else gets the whole row frame.
    func rects(unit: Int, localRange: Range<Int>, in reference: UIView) -> [CGRect] {
        guard let beacon = beacon(forUnit: unit) else { return [] }
        guard let (manager, container, plain) = layout(forUnit: unit) else {
            return [beacon.convert(beacon.bounds, to: reference)]
        }
        let lower = utf16Offset(fromCharacterOffset: localRange.lowerBound, in: plain)
        let upper = utf16Offset(fromCharacterOffset: localRange.upperBound, in: plain)
        guard upper > lower else { return [] }
        let glyphs = manager.glyphRange(
            forCharacterRange: NSRange(location: lower, length: upper - lower),
            actualCharacterRange: nil
        )
        var rects: [CGRect] = []
        manager.enumerateEnclosingRects(
            forGlyphRange: glyphs,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: container
        ) { rect, _ in
            rects.append(rect)
        }
        return rects.map { beacon.convert($0, to: reference) }
    }

    /// Caret rect for a local Character offset in one unit.
    func caretRect(unit: Int, localOffset: Int, in reference: UIView) -> CGRect {
        guard let beacon = beacon(forUnit: unit) else { return .null }
        guard let (manager, container, plain) = layout(forUnit: unit) else {
            let frame = beacon.convert(beacon.bounds, to: reference)
            return CGRect(x: frame.minX, y: frame.minY, width: 2, height: frame.height)
        }
        let utf16 = utf16Offset(fromCharacterOffset: localOffset, in: plain)
        let length = (plain as NSString).length
        let atEnd = utf16 >= length
        let sampleIndex = atEnd ? max(length - 1, 0) : utf16
        let glyphs = manager.glyphRange(
            forCharacterRange: NSRange(location: sampleIndex, length: length == 0 ? 0 : 1),
            actualCharacterRange: nil
        )
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        let x = atEnd ? rect.maxX : rect.minX
        let local = CGRect(x: x, y: rect.minY, width: 2, height: rect.height)
        return beacon.convert(local, to: reference)
    }

    /// Maps a point in `reference` coordinates to a global Character offset
    /// (an insertion-point offset). Falls back to unit boundaries for
    /// non-precise units.
    func closestOffset(to point: CGPoint, in reference: UIView) -> Int? {
        guard let nearest = registry.nearestBeacon(to: point, in: reference),
              let unit = unitIndex(forBlockID: nearest.id) else { return nil }
        guard let beacon = registry.view(for: nearest.id) else { return nil }
        let local = reference.convert(point, to: beacon)
        guard let (manager, container, plain) = layout(forUnit: unit) else {
            // Whole-unit granularity: nearer half → start or end.
            let midY = beacon.bounds.midY
            let unitLength = text.units[unit].plainText.count
            return text.globalOffset(unit: unit, local: local.y < midY ? 0 : unitLength)
        }
        var fraction: CGFloat = 0
        let utf16 = manager.characterIndex(
            for: local, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        var charOffset = characterOffset(fromUTF16: utf16, in: plain)
        if fraction > 0.5 { charOffset = min(charOffset + 1, plain.count) }
        return text.globalOffset(unit: unit, local: charOffset)
    }

    /// First unit (in document order) rendered by the top-level block.
    /// Prototype simplification: for blocks owning several units (list rows)
    /// this returns the first — whole-block granularity.
    private func unitIndex(forBlockID id: String) -> Int? {
        text.units.firstIndex { $0.topLevelBlockID == id }
    }

    /// Debug: all line rects of every precise unit (for the fidelity overlay).
    func debugRects(in reference: UIView) -> [CGRect] {
        preciseUnits.keys.flatMap { unit in
            rects(unit: unit, localRange: 0..<text.units[unit].plainText.count, in: reference)
        }
    }
}
#endif
