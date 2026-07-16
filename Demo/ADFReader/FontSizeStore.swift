import Foundation

/// Persists the per-document text-size step as `[docKey: Int]` in
/// UserDefaults. Read-modify-write per change; the data set is tiny.
struct FontSizeStore {
    var defaults: UserDefaults = .standard
    private let key = "adf.fontSizeSteps"

    func step(for docKey: String) -> Int {
        all()[docKey] ?? 0
    }

    func setStep(_ step: Int, docKey: String) {
        var map = all()
        if step == 0 {
            // The default needs no entry; dropping it keeps the map from
            // accumulating a key per document ever visited.
            map.removeValue(forKey: docKey)
        } else {
            map[docKey] = step
        }
        if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: key)
        }
    }

    private func all() -> [String: Int] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        return decoded
    }
}
