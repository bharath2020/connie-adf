import SwiftUI
import ADFModel
import ADFPreparation

/// Disclosure container for `expand` / `nestedExpand`.
///
/// The body ships as unprepared `[ADFNode]` (the preparer deliberately skips
/// it, §5.1); on first expansion it is flattened off-main by wrapping the
/// nodes in a synthetic doc, then cached in `@State` so re-opening is free.
struct ExpandBlockView: View {
    let title: String
    let bodyNodes: [ADFNode]
    let isNested: Bool

    @Environment(\.adfTheme) private var theme
    @State private var isExpanded = false
    @State private var preparedBody: [RenderBlock]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: theme.spacing) {
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    Text(title.isEmpty ? "Expand" : title)
                        .fontWeight(.medium)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(theme.spacing * 1.25)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                Group {
                    if let preparedBody {
                        VStack(alignment: .leading, spacing: theme.spacing) {
                            ForEach(preparedBody) { block in
                                BlockView(block: block)
                            }
                        }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, theme.spacing * 1.25)
                .padding(.bottom, theme.spacing * 1.25)
                .task { await prepareBodyIfNeeded() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: theme.containerCornerRadius)
                .strokeBorder(Color.gray.opacity(isNested ? 0.2 : 0.3))
        )
    }

    /// Flattens the body nodes off-main on first open; the result is cached
    /// so later expansions render immediately. Preparation streams through
    /// `prepareStream`, whose producer checks cancellation between nodes, so
    /// collapsing or scrolling away mid-prepare cancels the `.task`, the
    /// chunk loop exits, the stream's termination cancels the producer, and
    /// the next open retries.
    private func prepareBodyIfNeeded() async {
        guard preparedBody == nil else { return }
        let root = ADFNode(id: "expand", type: "doc", kind: .doc(bodyNodes))
        let document = ADFDocument(version: 1, root: root, issues: [])
        let preparer = DocumentPreparer(theme: theme)
        var blocks: [RenderBlock] = []
        for await chunk in preparer.prepareStream(document, chunkSize: 50) {
            blocks.append(contentsOf: chunk)
        }
        // Never cache a partial flatten from a cancelled run.
        guard !Task.isCancelled else { return }
        preparedBody = blocks
    }
}
