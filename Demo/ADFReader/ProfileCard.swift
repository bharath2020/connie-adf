import SwiftUI

/// A sample profile for a tapped mention. Fully fabricated; no network.
///
/// Adapts to how it's presented: in a regular size class (iPad) it's a compact,
/// fixed-width card shown in a popover anchored to the mention; in a compact
/// size class (iPhone) it's a full, native sheet — nav title, Done, drag
/// indicator, and a medium detent.
struct ProfileCard: View {
    let name: String

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss

    private var profile: FakeProfile { FakeProfile(name: name) }

    var body: some View {
        if sizeClass == .compact {
            NavigationStack {
                content
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .navigationTitle("Profile")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        } else {
            content
                .frame(width: 300)
                .padding(20)
        }
    }

    /// The shared card body — avatar, identity, contact block, footnote.
    private var content: some View {
        VStack(spacing: 16) {
            Circle()
                .fill(profile.color.gradient)
                .frame(width: 72, height: 72)
                .overlay {
                    Text(profile.initials)
                        .font(.title.weight(.semibold))
                        .foregroundStyle(.white)
                }

            VStack(spacing: 4) {
                Text(profile.name).font(.headline)
                Text("\(profile.title) · \(profile.team)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                row(icon: "envelope", text: profile.email)
                row(icon: "circle.fill", text: profile.status, tint: profile.color)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))

            Text("Sample profile — generated for demo purposes.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func row(icon: String, text: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 20)
            Text(text)
            Spacer(minLength: 0)
        }
    }
}
