import Foundation
import ADFAtlassianAuth

enum AppConfig {
    /// Base URL of the Cloudflare-hosted static Confluence bundle (live).
    static let confluenceBaseURL = URL(string: "https://adfreader-confluence.pages.dev")!
    /// The Confluence site the bundle was exported from (`cloudflare/README.md`):
    /// its page IDs, and the `contentId-<page>` collections of its media, are
    /// that site's. A remote page loads real images through the account
    /// saved for this site, when there is one (`DemoMedia`).
    static let confluenceSite = try! AtlassianSite(parsing: "bharath2020.atlassian.net")
}
