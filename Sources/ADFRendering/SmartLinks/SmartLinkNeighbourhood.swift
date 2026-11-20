import ADFPreparation

/// Where each smart link sits in a document, in **positions**: what
/// `.afterScrollingWithNearby` measures "nearby" in (design §8.5).
///
/// Each top-level row is one position, except a top-level list, where each
/// list row is one, so a long list is not "one row". Everything nested
/// inside a row (a panel's or quote's children, layout columns, a table
/// slice's cells, a list row's trailing blocks, media captions) shares its
/// row's (or list row's) position. Positions, not points: rows the lazy
/// stack has not built have no measured height.
///
/// Holds only the text owners that have smart links (owner id as the leaves
/// report it — `RenderBlock.id`, `PreparedListRow.id`, `PreparedMedia.id` —
/// its position and its keys), in document order, plus each top-level row's
/// first position. Unopened expand bodies are not prepared and are not
/// here. Built from the document's blocks by `SmartLinkCoordinator` on its
/// first nearby plan, then extended as blocks stream in.
struct SmartLinkNeighbourhood {
    struct Owner: Equatable {
        let id: String
        let position: Int
        let keys: [SmartLinkKey]
    }

    /// Owners with smart links, positions ascending (document order).
    private(set) var owners: [Owner] = []
    private var slots: [String: Int] = [:]
    /// The first position of each top-level row, by row index.
    private var rowStarts: [Int] = []
    /// Positions handed out so far.
    private(set) var positionCount = 0

    /// Top-level rows indexed so far.
    var rowCount: Int { rowStarts.count }

    init() {}

    init(_ blocks: some Sequence<RenderBlock>) {
        append(contentsOf: blocks)
    }

    mutating func append(contentsOf blocks: some Sequence<RenderBlock>) {
        for block in blocks { append(block) }
    }

    /// Indexes the next top-level row.
    mutating func append(_ block: RenderBlock) {
        rowStarts.append(positionCount)
        if case .listRows(let rows) = block.kind, !rows.isEmpty {
            for row in rows {
                collect(row, at: positionCount)
                positionCount += 1
            }
        } else {
            collect(block, at: positionCount)
            positionCount += 1
        }
    }

    /// The position of a text owner with smart links.
    func position(ofOwner id: String) -> Int? {
        slots[id].map { owners[$0].position }
    }

    /// The first position of the top-level row at `index`.
    func position(ofRow index: Int) -> Int? {
        rowStarts.indices.contains(index) ? rowStarts[index] : nil
    }

    /// The owners whose positions lie in `low...high`, in document order.
    func owners(from low: Int, through high: Int) -> ArraySlice<Owner> {
        guard low <= high else { return [] }
        var lower = 0
        var upper = owners.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if owners[middle].position < low { lower = middle + 1 } else { upper = middle }
        }
        var end = lower
        while end < owners.count, owners[end].position <= high { end += 1 }
        return owners[lower..<end]
    }

    private mutating func record(_ id: String, _ keys: [SmartLinkKey], at position: Int) {
        guard !keys.isEmpty else { return }
        slots[id] = owners.count
        owners.append(Owner(id: id, position: position, keys: keys))
    }

    private mutating func collect(_ block: RenderBlock, at position: Int) {
        record(block.id, block.smartLinkKeys, at: position)
        switch block.kind {
        case .listRows(let rows):
            for row in rows { collect(row, at: position) }
        case .panel(_, let children), .quote(let children), .extensionPlaceholder(_, let children):
            for child in children { collect(child, at: position) }
        case .tableSlice(_, let rows, _):
            for row in rows {
                for cell in row.cells {
                    for child in cell.blocks { collect(child, at: position) }
                }
            }
        case .media(let media):
            record(media.id, media.captionSmartLinkKeys, at: position)
        case .mediaStrip(let items):
            for media in items { record(media.id, media.captionSmartLinkKeys, at: position) }
        case .layoutColumns(let columns):
            for column in columns {
                for child in column.blocks { collect(child, at: position) }
            }
        case .richText, .codeBlock, .divider, .expand, .card, .custom, .unknown:
            break
        }
    }

    private mutating func collect(_ row: PreparedListRow, at position: Int) {
        record(row.id, row.smartLinkKeys, at: position)
        for child in row.trailingBlocks { collect(child, at: position) }
    }
}
