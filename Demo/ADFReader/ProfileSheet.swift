import SwiftUI

/// A sample profile card for a tapped mention. Fully fabricated; no network.
struct ProfileSheet: View {
    let name: String
    @Environment(\.dismiss) private var dismiss

    private var profile: FakeProfile { FakeProfile(name: name) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Circle()
                    .fill(profile.color.gradient)
                    .frame(width: 96, height: 96)
                    .overlay {
                        Text(profile.initials)
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.top, 24)

                VStack(spacing: 4) {
                    Text(profile.name).font(.title2.weight(.bold))
                    Text("\(profile.title) · \(profile.team)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    row(icon: "envelope", text: profile.email)
                    row(icon: "circle.fill", text: profile.status, tint: profile.color)
                }
                .padding().frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
                .padding(.horizontal)

                Text("Sample profile — generated for demo purposes.")
                    .font(.footnote).foregroundStyle(.tertiary)
                Spacer()
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func row(icon: String, text: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 20)
            Text(text)
            Spacer()
        }
    }
}
