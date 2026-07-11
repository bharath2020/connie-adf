import Foundation
import ADFModel

/// List flattening: bullet/ordered/task/decision lists become flat
/// `PreparedListRow` arrays with pre-computed markers and depths, so the view
/// layer renders rows without any counting or recursion.
extension BlockPreparer {
    /// Flattens one list node (any list family) into rows at `depth`.
    func listRows(for list: ADFNode, depth: Int) -> [PreparedListRow] {
        switch list.kind {
        case .bulletList(let items, _):
            return items.flatMap { item in
                itemRows(item, marker: .bullet(depth: depth), depth: depth)
            }

        case .orderedList(let start, let items, _):
            var rows: [PreparedListRow] = []
            var ordinal = start
            for item in items {
                rows.append(contentsOf: itemRows(
                    item,
                    marker: .ordered(Self.orderedMarker(ordinal, depth: depth)),
                    depth: depth
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
                        marker: .task(done: state == .done),
                        segments: composer.compose(inline),
                        trailingBlocks: []
                    ))
                case .taskList:
                    // Schema nests task lists as siblings of task items.
                    rows.append(contentsOf: listRows(for: item, depth: depth + 1))
                default:
                    rows.append(contentsOf: itemRows(item, marker: .task(done: false), depth: depth))
                }
            }
            return rows

        case .decisionList(let items):
            return items.flatMap { item -> [PreparedListRow] in
                guard case .decisionItem(let inline) = item.kind else {
                    return itemRows(item, marker: .decision, depth: depth)
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

    /// Rows for one `listItem`: the item's leading paragraph becomes the row
    /// content, nested lists become deeper rows, and any other block children
    /// become the row's trailing blocks.
    private func itemRows(_ item: ADFNode, marker: ListMarker, depth: Int) -> [PreparedListRow] {
        var segments: [InlineSegment] = []
        var trailing: [RenderBlock] = []
        var nestedRows: [PreparedListRow] = []
        var consumedLeadingParagraph = false

        for child in item.children {
            switch child.kind {
            case .paragraph(let content, _) where !consumedLeadingParagraph:
                segments = composer.compose(content)
                consumedLeadingParagraph = true
            case .bulletList, .orderedList, .taskList, .decisionList:
                nestedRows.append(contentsOf: listRows(for: child, depth: depth + 1))
            default:
                trailing.append(contentsOf: blocks(for: child))
            }
        }

        let row = PreparedListRow(
            id: item.id,
            depth: depth,
            marker: marker,
            segments: segments,
            trailingBlocks: trailing
        )
        return [row] + nestedRows
    }

    // MARK: - Ordered markers

    /// Formats an ordinal per depth: decimal (`4.`), alphabetic (`a.`),
    /// roman (`i.`) — cycling every three levels.
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
