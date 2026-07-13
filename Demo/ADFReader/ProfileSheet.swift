import SwiftUI

/// A sample profile card for a tapped mention. Fully fabricated; no network.
/// Self-sizing so it fits a popover on iPad (and adapts to a sheet on iPhone,
/// where the detent applies).
struct ProfileCard: View {
    let name: String

    private var profile: FakeProfile { FakeProfile(name: name) }

    var body: some View {
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
        .padding(20)
        .frame(width: 300)
        .presentationDetents([.medium])   // applies only when adapted to a sheet
    }

    private func row(icon: String, text: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 20)
            Text(text)
            Spacer(minLength: 0)
        }
    }
}
