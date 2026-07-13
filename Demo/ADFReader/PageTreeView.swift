import SwiftUI
import ADFConfluence

struct PageTreeView: View {
    let space: Space
    @State private var roots: [PageNode] = []
    @State private var failure: String?

    private let client = HTTPConfluenceClient(baseURL: AppConfig.confluenceBaseURL)

    var body: some View {
        List {
            if let failure {
                ContentUnavailableView("Couldn't Load Pages", systemImage: "wifi.slash", description: Text(failure))
            } else {
                OutlineGroup(roots, children: \.optionalChildren) { node in
                    NavigationLink(value: DocumentSource.remotePage(id: node.id, title: node.title)) {
                        Label(node.title, systemImage: "doc.text")
                    }
                }
            }
        }
        .navigationTitle(space.name)
        .task { await load() }
    }

    private func load() async {
        do { roots = PageTree.build(from: try await client.pages(inSpace: space.id)) }
        catch { failure = error.localizedDescription }
    }
}

private extension PageNode {
    /// `OutlineGroup` needs `nil` (not `[]`) for leaves to hide the chevron.
    var optionalChildren: [PageNode]? { children.isEmpty ? nil : children }
}
