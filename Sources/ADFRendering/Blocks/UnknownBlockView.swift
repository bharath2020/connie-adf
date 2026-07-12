import SwiftUI

/// Low-emphasis chip for unknown/future node types — the reader always sees
/// that something was elided; nothing silently disappears.
struct UnknownBlockView: View {
    let typeName: String

    @ScaledMetric(relativeTo: .footnote) private var iconSpacing: CGFloat = 6
    @ScaledMetric(relativeTo: .footnote) private var horizontalPadding: CGFloat = 10
    @ScaledMetric(relativeTo: .footnote) private var verticalPadding: CGFloat = 5

    var body: some View {
        HStack(spacing: iconSpacing) {
            Image(systemName: "questionmark.square.dashed")
                .imageScale(.small)
            Text("Unsupported content: \(typeName)")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(Capsule().fill(Color.gray.opacity(0.12)))
        .accessibilityLabel("Unsupported content of type \(typeName)")
    }
}
