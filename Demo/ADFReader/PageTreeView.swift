import SwiftUI
import ADFConfluence

/// A space's page tree. Parent pages expand/collapse via a leading disclosure
/// chevron and are themselves openable via the row label; leaf pages are plain
/// navigation links. Loads fully expanded so the whole tree is visible at once.
struct PageTreeView: View {
    let space: Space

    @State private var roots: [PageNode] = []
    @State private var expanded: Set<String> = []
    @State private var failure: String?

    private let client = HTTPConfluenceClient(baseURL: AppConfig.confluenceBaseURL)

    var body: some View {
        List {
            if let failure {
                ContentUnavailableView("Couldn't Load Pages", systemImage: "wifi.slash", description: Text(failure))
            } else {
                ForEach(roots) { node in
                    PageRowView(node: node, expanded: $expanded)
                }
            }
        }
        .navigationTitle(space.name)
        .task { await load() }
    }

    private func load() async {
        do {
            let tree = PageTree.build(from: try await client.pages(inSpace: space.id))
            roots = tree
            expanded = Self.allIDs(in: tree)   // start fully expanded
        } catch {
            failure = error.localizedDescription
        }
    }

    private static func allIDs(in nodes: [PageNode]) -> Set<String> {
        var ids: Set<String> = []
        for node in nodes {
            ids.insert(node.id)
            ids.formUnion(allIDs(in: node.children))
        }
        return ids
    }
}

/// One row in the page tree. Recursive: a page with children renders as a
/// `DisclosureGroup` whose label opens the page and whose chevron toggles its
/// subtree; a childless page renders as a plain `NavigationLink`.
private struct PageRowView: View {
    let node: PageNode
    @Binding var expanded: Set<String>

    var body: some View {
        if node.children.isEmpty {
            NavigationLink(value: DocumentSource.remotePage(id: node.id, title: node.title)) {
                Label(node.title, systemImage: "doc.text")
            }
        } else {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(node.children) { child in
                    PageRowView(node: child, expanded: $expanded)
                }
            } label: {
                NavigationLink(value: DocumentSource.remotePage(id: node.id, title: node.title)) {
                    Label(node.title, systemImage: "folder")
                }
            }
        }
    }

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { expanded.contains(node.id) },
            set: { open in
                if open { expanded.insert(node.id) } else { expanded.remove(node.id) }
            }
        )
    }
}
