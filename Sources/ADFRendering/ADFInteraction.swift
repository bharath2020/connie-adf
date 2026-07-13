import SwiftUI

/// A user interaction with an interactive ADF element, delivered to the host
/// via the injected `adfInteractionHandler`. Parameters ride as associated
/// values so the host switches over intent, not booleans.
public enum ADFInteraction: Sendable {
    /// A task checkbox was tapped. `id` identifies the task; `isDone` is the
    /// new state the host should record.
    case taskToggled(id: String, isDone: Bool)
}

private struct ADFInteractionHandlerKey: EnvironmentKey {
    static let defaultValue: (@MainActor (ADFInteraction) -> Void)? = nil
}

private struct ADFTaskStatesKey: EnvironmentKey {
    static let defaultValue: [String: Bool] = [:]
}

private struct ADFMentionContentKey: EnvironmentKey {
    static let defaultValue: (@MainActor (String) -> AnyView)? = nil
}

public extension EnvironmentValues {
    /// Host-supplied sink for interactions (task toggles). `nil` (the default)
    /// renders tasks read-only.
    var adfInteractionHandler: (@MainActor (ADFInteraction) -> Void)? {
        get { self[ADFInteractionHandlerKey.self] }
        set { self[ADFInteractionHandlerKey.self] = newValue }
    }

    /// Per-task display override of the ADF `done` flag, keyed by task id.
    /// A task shows `adfTaskStates[id] ?? adfDone`.
    var adfTaskStates: [String: Bool] {
        get { self[ADFTaskStatesKey.self] }
        set { self[ADFTaskStatesKey.self] = newValue }
    }

    /// Host-supplied content shown when a mention is tapped, keyed by the
    /// mention's display name. The renderer presents it in a popover anchored
    /// to the mention — which adapts to a sheet in a compact size class. `nil`
    /// (the default) renders mentions read-only.
    var adfMentionContent: (@MainActor (String) -> AnyView)? {
        get { self[ADFMentionContentKey.self] }
        set { self[ADFMentionContentKey.self] = newValue }
    }
}
