import SwiftUI

/// A fabricated-but-consistent profile derived from a mention's name.
/// Deterministic: the same name always yields the same profile.
struct FakeProfile {
    let name: String
    let initials: String
    let title: String
    let team: String
    let email: String
    let status: String
    let color: Color

    init(name rawName: String) {
        let clean = rawName.hasPrefix("@") ? String(rawName.dropFirst()) : rawName
        let trimmed = clean.trimmingCharacters(in: .whitespaces)
        name = trimmed.isEmpty ? "Unknown" : trimmed

        let words = name.split(separator: " ")
        initials = words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()

        let h = Self.stableHash(name)
        let titles = ["Product Lead", "Staff Engineer", "Design Manager", "Data Scientist",
                      "Engineering Manager", "Product Designer", "Solutions Architect", "QA Lead"]
        let teams = ["Core", "Growth", "Platform", "Payments", "Mobile", "Design Systems", "Data", "Quality"]
        let statuses = ["Available", "In a meeting", "Focusing", "Away", "On vacation"]
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .red]

        title = titles[h % titles.count]
        team = teams[(h / 3) % teams.count]
        status = statuses[(h / 7) % statuses.count]
        color = palette[(h / 11) % palette.count]

        let handle = words.map { $0.lowercased() }.joined(separator: ".")
        email = "\(handle.isEmpty ? "user" : handle)@meridian.app"
    }

    /// FNV-1a over UTF-8 — stable across launches (unlike Swift's `Hasher`).
    private static func stableHash(_ s: String) -> Int {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in s.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return Int(hash % UInt64(Int.max))
    }
}
