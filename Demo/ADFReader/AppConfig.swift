import Foundation

enum AppConfig {
    /// Base URL of the Cloudflare-hosted static Confluence bundle.
    /// Set to the deployed *.pages.dev URL in Task 6.
    static let confluenceBaseURL = URL(string: "https://adfreader-confluence.pages.dev")!
}
