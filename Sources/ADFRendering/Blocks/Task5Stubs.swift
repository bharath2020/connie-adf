import SwiftUI

// TEMPORARY — Task 4 scaffolding.
//
// `BlockView` routes the Task 5 kinds (listRows, tableSlice, media,
// mediaStrip, expand, layoutColumns, card, extensionPlaceholder) to this
// labeled placeholder. Task 5 replaces those switch cases with real views
// and DELETES this file.

/// Simple labeled rounded rectangle standing in for a not-yet-implemented
/// block family.
struct Task5StubView: View {
    let label: String

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.gray.opacity(0.08))
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        Color.gray.opacity(0.25),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )
            .overlay(
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
            )
            .accessibilityLabel("Placeholder: \(label)")
    }
}
