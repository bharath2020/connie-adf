import SwiftUI

/// Low-emphasis chip for unknown/future node types — the reader always sees
/// that something was elided; nothing silently disappears.
struct UnknownBlockView: View {
    let typeName: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.square.dashed")
                .imageScale(.small)
            Text("Unsupported content: \(typeName)")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.gray.opacity(0.12)))
        .accessibilityLabel("Unsupported content of type \(typeName)")
    }
}
