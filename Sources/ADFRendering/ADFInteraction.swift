import SwiftUI

/// A user interaction with an interactive ADF element, delivered to the host
/// via the injected `adfInteractionHandler`. Parameters ride as associated
/// values so the host switches over intent, not booleans.
public enum ADFInteraction: Sendable {
    /// A mention capsule was tapped. `name` is the mention's display text.
    case mentionTapped(name: String)
    /// A task checkbox was tapped. `id` identifies the task; `isDone` is the
    /// new state the host should record.
    case taskToggled(id: String, isDone: Bool)
}

private struct ADFInteractionHandlerKey: EnvironmentKey {
    static let defaultValue: (@Sendable (ADFInteraction) -> Void)? = nil
}

private struct ADFTaskStatesKey: EnvironmentKey {
    static let defaultValue: [String: Bool] = [:]
}

public extension EnvironmentValues {
    /// Host-supplied sink for interactions. `nil` (the default) renders
    /// mentions and tasks read-only.
    var adfInteractionHandler: (@Sendable (ADFInteraction) -> Void)? {
        get { self[ADFInteractionHandlerKey.self] }
        set { self[ADFInteractionHandlerKey.self] = newValue }
    }

    /// Per-task display override of the ADF `done` flag, keyed by task id.
    /// A task shows `adfTaskStates[id] ?? adfDone`.
    var adfTaskStates: [String: Bool] {
        get { self[ADFTaskStatesKey.self] }
        set { self[ADFTaskStatesKey.self] = newValue }
    }
}
