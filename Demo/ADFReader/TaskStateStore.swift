import Foundation

/// Persists task toggle state as `[docKey: [taskId: Bool]]` in UserDefaults.
/// Read-modify-write per change; the data set is tiny.
struct TaskStateStore {
    var defaults: UserDefaults = .standard
    private let key = "adf.taskStates"

    func states(for docKey: String) -> [String: Bool] {
        all()[docKey] ?? [:]
    }

    func setState(_ isDone: Bool, taskId: String, docKey: String) {
        var map = all()
        map[docKey, default: [:]][taskId] = isDone
        if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: key)
        }
    }

    private func all() -> [String: [String: Bool]] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: [String: Bool]].self, from: data)
        else { return [:] }
        return decoded
    }
}
