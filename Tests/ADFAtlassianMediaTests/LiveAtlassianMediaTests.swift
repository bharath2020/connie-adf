import Foundation
import ImageIO
import Testing
import ADFAtlassianAuth
import ADFModel
import ADFAtlassianMedia

/// Opt-in check against a real Confluence page. Skipped unless
/// `ADF_LIVE_SITE` is set AND the standard adf-auth Keychain item for that
/// site exists (`adf-auth login --site <site>` saves it). Run it with
/// `Scripts/live-atlassian-fetch.sh`.
///
/// The credential is read at run time through `KeychainCredentialStore`
/// (`CredentialStore.load(site:)`); macOS may ask to allow keychain access.
/// Environment: `ADF_LIVE_SITE` (e.g. `mycompany`), `ADF_LIVE_PAGE`
/// (default `229377`).
///
/// Prints counts, sizes and media types only — never the token, the email
/// or an Authorization header.
@Suite("Live Atlassian media fetch", .enabled(if: LiveEnvironment.credential != nil), .timeLimit(.minutes(5)))
struct LiveAtlassianMediaTests {
    @Test("every file media node on the page downloads as a decodable image")
    func fetchPageMedia() async throws {
        let credential = try #require(LiveEnvironment.credential)
        let env = LiveEnvironment.current
        let fetcher = AtlassianMediaFetcher(credential: credential)
        let cloudId = try await fetcher.resolvedCloudId()

        let document = try await LivePageBody.fetchADF(credential: credential, cloudId: cloudId, pageId: env.pageId)
        let scan = MediaScan(document.root)
        print("live: page has \(scan.fileMedia.count) file media node(s), \(scan.externalMediaCount) external, \(scan.emojiCount) emoji node(s)")
        // TODO(adf-res5 emoji): custom emoji fetch is pending a decision (see
        // docs/Atlassian-Media-Fetch.md, "Custom emoji"). Only the count is
        // recorded here; there is deliberately no emoji fetch code.
        try #require(!scan.fileMedia.isEmpty, "page \(env.pageId) has no file media nodes; pick a page with an image")

        let attachments = try await fetcher.attachments(pageId: env.pageId)
        print("live: page lists \(attachments.count) attachment(s)")
        let mediaTypes = Dictionary(attachments.map { ($0.fileId, $0.mediaType) }, uniquingKeysWith: { first, _ in first })

        var decodedImages = 0
        for (index, attrs) in scan.fileMedia.enumerated() {
            let bytes = try await fetcher.data(for: attrs)
            guard case .file(let fileId, _) = attrs.source else { continue }
            let mediaType = mediaTypes[fileId] ?? "unknown"
            let frames = Self.imageFrameCount(bytes)
            print("live: media #\(index + 1): \(bytes.count) bytes, \(mediaType), \(frames) image frame(s)")
            #expect(!bytes.isEmpty)
            if mediaType.hasPrefix("image/") || mediaType == "unknown" {
                #expect(frames > 0, "media #\(index + 1) (\(mediaType)) did not decode as an image")
                if frames > 0 { decodedImages += 1 }
            }
        }
        #expect(decodedImages > 0)
    }

    static func imageFrameCount(_ data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }
}

/// The live-test settings, read from the environment, and the saved
/// adf-auth credential for that site.
struct LiveEnvironment: Sendable {
    let site: String?
    let pageId: String

    static let current: LiveEnvironment = {
        let environment = ProcessInfo.processInfo.environment
        func value(_ name: String) -> String? {
            guard let raw = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return raw
        }
        return LiveEnvironment(site: value("ADF_LIVE_SITE"), pageId: value("ADF_LIVE_PAGE") ?? "229377")
    }()

    /// Loaded once. `nil` (suite skipped) when `ADF_LIVE_SITE` is unset or
    /// unparsable, or when no adf-auth credential is saved for that site.
    static let credential: AtlassianCredential? = {
        guard let raw = current.site, let site = try? AtlassianSite(parsing: raw) else { return nil }
        return (try? KeychainCredentialStore().load(site: site)) ?? nil
    }()
}

/// Test-only page body fetch (the library has no need for it):
/// `GET {apiBase}/ex/confluence/{cloudId}/wiki/api/v2/pages/{id}?body-format=atlas_doc_format`.
/// `body.atlas_doc_format.value` is a JSON string holding the ADF document.
enum LivePageBody {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func fetchADF(credential: AtlassianCredential, cloudId: String, pageId: String) async throws -> ADFDocument {
        let base = AtlassianMediaFetcher.defaultAPIBase.absoluteString
        guard let url = URL(string: "\(base)/ex/confluence/\(cloudId)/wiki/api/v2/pages/\(pageId)?body-format=atlas_doc_format") else {
            throw Failure(description: "could not build the page URL")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        let basic = Data("\(credential.email):\(credential.token)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (body, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure(description: "page fetch returned HTTP \(status)")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let bodyObject = object["body"] as? [String: Any],
              let adf = bodyObject["atlas_doc_format"] as? [String: Any],
              let value = adf["value"] as? String else {
            throw Failure(description: "page body has no atlas_doc_format value")
        }
        return try await ADFParser().parse(Data(value.utf8))
    }
}

/// Walks the whole tree (mediaSingle, mediaGroup, tables, layouts, …).
struct MediaScan {
    private(set) var fileMedia: [MediaAttrs] = []
    private(set) var externalMediaCount = 0
    private(set) var emojiCount = 0

    init(_ root: ADFNode) {
        visit(root)
    }

    private mutating func visit(_ node: ADFNode) {
        switch node.kind {
        case .media(let attrs, _), .mediaInline(let attrs, _):
            switch attrs.source {
            case .file: fileMedia.append(attrs)
            case .external: externalMediaCount += 1
            }
        case .emoji:
            emojiCount += 1
        default:
            break
        }
        for child in node.children { visit(child) }
    }
}
