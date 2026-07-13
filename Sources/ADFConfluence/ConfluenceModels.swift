import Foundation

public struct ResultsEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    public let results: [T]
}

public struct Space: Decodable, Identifiable, Sendable, Hashable {
    public let id: String
    public let key: String
    public let name: String
}

public struct PageSummary: Decodable, Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let parentId: String?
    public let position: Int
    public init(id: String, title: String, parentId: String?, position: Int) {
        self.id = id; self.title = title; self.parentId = parentId; self.position = position
    }
}

public struct PageNode: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public var children: [PageNode]
}

public enum PageTree {
    /// Build root-level nodes from a flat list. Roots have `parentId == nil`;
    /// each sibling level is ordered by `(position, title)`.
    public static func build(from summaries: [PageSummary]) -> [PageNode] {
        var childrenByParent: [String: [PageSummary]] = [:]
        var roots: [PageSummary] = []
        for s in summaries {
            if let p = s.parentId { childrenByParent[p, default: []].append(s) }
            else { roots.append(s) }
        }
        func node(_ s: PageSummary) -> PageNode {
            let kids = (childrenByParent[s.id] ?? []).sorted(by: ordered).map(node)
            return PageNode(id: s.id, title: s.title, children: kids)
        }
        return roots.sorted(by: ordered).map(node)
    }
    private static func ordered(_ a: PageSummary, _ b: PageSummary) -> Bool {
        a.position != b.position ? a.position < b.position : a.title < b.title
    }
}
