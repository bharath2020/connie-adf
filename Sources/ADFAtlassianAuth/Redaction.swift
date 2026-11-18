import Foundation

/// Helpers that keep secrets out of logs and descriptions.
public enum Redaction {
    /// `"<redacted:N chars>"` — never the token itself.
    public static func token(_ token: String) -> String {
        "<redacted:\(token.count) chars>"
    }

    /// Placeholder used wherever a secret would otherwise appear.
    public static let placeholder = "<redacted>"
}
