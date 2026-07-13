import Foundation
import ADFModel

/// List flattening: bullet/ordered/task/decision lists become flat
/// `PreparedListRow` arrays with pre-computed markers and depths, so the view
/// layer renders rows without any counting or recursion.
extension BlockPreparer {
    /// Marker style is keyed to *same-type* nesting (how many bullet-list or
    /// ordered-list ancestors a list has), matching Atlassian's renderer CSS
    /// (`ul ul → circle`, `ol ol → lower-alpha`, …) — a bullet list inside an
    /// ordered list is still a first-level bullet list. `depth` (overall
    /// nesting) drives indentation only.
    struct ListLevels {
        var bullet = 0
        var ordered = 0
    }

    /// Flattens one list node (any list family) into rows at `depth`.
    func listRows(for list: ADFNode, depth: Int, levels: ListLevels = ListLevels()) -> [PreparedListRow] {
        switch list.kind {
        case .bulletList(let items, _):
            var nested = levels
            nested.bullet += 1
            return items.flatMap { item in
                itemRows(item, marker: .bullet(depth: levels.bullet), depth: depth, nestedLevels: nested)
            }

        case .orderedList(let start, let items, _):
            var nested = levels
            nested.ordered += 1
            var rows: [PreparedListRow] = []
            var ordinal = start
            for item in items {
                rows.append(contentsOf: itemRows(
                    item,
                    marker: .ordered(Self.orderedMarker(ordinal, depth: levels.ordered)),
                    depth: depth,
                    nestedLevels: nested
                ))
                ordinal += 1
            }
            return rows

        case .taskList(let items):
            var rows: [PreparedListRow] = []
            for item in items {
                switch item.kind {
                case .taskItem(let state, let inline):
                    rows.append(PreparedListRow(
                        id: item.id,
                        depth: depth,
                        marker: .task(id: item.id, done: state == .done),
                        segments: composer.compose(inline),
                        trailingBlocks: []
                    ))
                case .taskList:
                    // Schema nests task lists as siblings of task items.
                    rows.append(contentsOf: listRows(for: item, depth: depth + 1, levels: levels))
                default:
                    rows.append(contentsOf: itemRows(item, marker: .task(id: item.id, done: false), depth: depth, nestedLevels: levels))
                }
            }
            return rows

        case .decisionList(let items):
            return items.flatMap { item -> [PreparedListRow] in
                guard case .decisionItem(let inline) = item.kind else {
                    return itemRows(item, marker: .decision, depth: depth, nestedLevels: levels)
                }
                return [PreparedListRow(
                    id: item.id,
                    depth: depth,
                    marker: .decision,
                    segments: composer.compose(inline),
                    trailingBlocks: []
                )]
            }

        default:
            return []
        }
    }

    /// Rows for one `listItem`, preserving document order: a *leading*
    /// paragraph becomes the marker row's content, nested lists become deeper
    /// rows at exactly the point they appear, and blocks that follow a nested
    /// list start a marker-less continuation row at the item's depth so
    /// nothing renders out of order. `nestedLevels` carries the same-type
    /// list counts that apply to any list nested inside this item.
    private func itemRows(_ item: ADFNode, marker: ListMarker, depth: Int, nestedLevels: ListLevels) -> [PreparedListRow] {
        var rows: [PreparedListRow] = []
        var segments: [InlineSegment] = []
        var trailing: [RenderBlock] = []
        var emittedMarkerRow = false
        var continuationCount = 0

        // Emits the pending row: the item's marker row first (always, even
        // when empty — the marker must precede any nested rows), then
        // marker-less continuation rows for content after nested lists.
        func flushRow() {
            if !emittedMarkerRow {
                rows.append(PreparedListRow(
                    id: item.id,
                    depth: depth,
                    marker: marker,
                    segments: segments,
                    trailingBlocks: trailing
                ))
                emittedMarkerRow = true
            } else if !segments.isEmpty || !trailing.isEmpty {
                continuationCount += 1
                rows.append(PreparedListRow(
                    id: "\(item.id)#cont\(continuationCount)",
                    depth: depth,
                    marker: .continuation,
                    segments: segments,
                    trailingBlocks: trailing
                ))
            }
            segments = []
            trailing = []
        }

        var isFirstChild = true
        for child in item.children {
            switch child.kind {
            case .paragraph(let content, _) where isFirstChild:
                segments = composer.compose(content)
            case .bulletList, .orderedList, .taskList, .decisionList:
                flushRow()
                rows.append(contentsOf: listRows(for: child, depth: depth + 1, levels: nestedLevels))
            default:
                trailing.append(contentsOf: blocks(for: child))
            }
            isFirstChild = false
        }
        flushRow()
        return rows
    }

    // MARK: - Ordered markers

    /// Formats an ordinal per ordered-list nesting level: decimal (`4.`),
    /// alphabetic (`a.`), roman (`i.`) — cycling every three levels.
    static func orderedMarker(_ ordinal: Int, depth: Int) -> String {
        switch depth % 3 {
        case 0: return "\(ordinal)."
        case 1: return "\(alphabetic(ordinal))."
        default: return "\(roman(ordinal))."
        }
    }

    private static func alphabetic(_ ordinal: Int) -> String {
        var n = max(ordinal, 1)
        var result = ""
        while n > 0 {
            n -= 1
            let scalar = UnicodeScalar(UInt8(97 + n % 26))
            result = String(scalar) + result
            n /= 26
        }
        return result
    }

    private static func roman(_ ordinal: Int) -> String {
        var n = max(ordinal, 1)
        let table: [(Int, String)] = [
            (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
            (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
            (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
        ]
        var result = ""
        for (value, numeral) in table {
            while n >= value {
                result += numeral
                n -= value
            }
        }
        return result
    }
}
