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
/// (default `229377`), `ADF_LIVE_EMOJI_IDS` (optional comma-separated emoji
/// IDs fetched in addition to the page's emoji nodes).
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
        // Emoji images are checked by fetchPageEmoji (AtlassianEmojiFetcher).
        try #require(!scan.fileMedia.isEmpty, "page \(env.pageId) has no file media nodes; pick a page with an image")

        let attachments = try await fetcher.attachments(pageId: env.pageId)
        print("live: page lists \(attachments.count) attachment(s)")
        let mediaTypes = Dictionary(attachments.map { ($0.fileId, $0.mediaType) }, uniquingKeysWith: { first, _ in first })

        var decodedImages = 0
        for (index, attrs) in scan.fileMedia.enumerated() {
            guard case .file(let fileId, _) = attrs.source else { continue }
            let mediaType = mediaTypes[fileId] ?? "unknown"
            guard mediaType.lowercased().hasPrefix("image/") else {
                print("live: media #\(index + 1): \(mediaType), not an image; not downloaded")
                continue
            }
            let bytes = try await fetcher.data(for: attrs)
            let frames = Self.imageFrameCount(bytes)
            print("live: media #\(index + 1): \(bytes.count) bytes, \(mediaType), \(frames) image frame(s)")
            #expect(!bytes.isEmpty)
            #expect(frames > 0, "media #\(index + 1) (\(mediaType)) did not decode as an image")
            if frames > 0 { decodedImages += 1 }
        }
        #expect(decodedImages > 0)
    }

    @Test("every emoji with an ID on the page (and in ADF_LIVE_EMOJI_IDS) loads as a decodable image")
    func fetchPageEmoji() async throws {
        let credential = try #require(LiveEnvironment.credential)
        let env = LiveEnvironment.current
        let fetcher = AtlassianEmojiFetcher(credential: credential)
        let cloudId = try await fetcher.resolvedCloudId()

        // ADFModel's `.emoji(shortName:text:)` has no `id`, so read the raw ADF.
        let json = try await LivePageBody.fetchADFJSON(credential: credential, cloudId: cloudId, pageId: env.pageId)
        let scan = try EmojiScan(adfJSON: json)
        var references = scan.emojis
        for id in env.emojiIds where !references.contains(where: { $0.id == id }) {
            references.append(EmojiScan.Reference(id: id, shortName: ""))
        }
        print("live: page has \(scan.emojis.count) emoji node(s) with an ID, \(scan.emojisWithoutId) without; \(env.emojiIds.count) extra ID(s) from ADF_LIVE_EMOJI_IDS; \(scan.panelIcons.count) panel icon(s)")

        // Panel icons are reported, not asserted (site emoji on a private site
        // may be invisible to the emoji service).
        for (index, icon) in scan.panelIcons.enumerated() {
            do {
                let bytes = try await fetcher.data(emojiId: icon.id, shortName: icon.shortName)
                print("live: panel icon #\(index + 1) \(icon.shortName): \(bytes.count) bytes, \(LiveAtlassianMediaTests.imageFrameCount(bytes)) image frame(s)")
            } catch {
                print("live: panel icon #\(index + 1) \(icon.shortName): not loaded (\(error)); text fallback")
            }
        }

        guard !references.isEmpty else {
            print("live: NOTE page \(env.pageId) has no emoji with an ID and ADF_LIVE_EMOJI_IDS is empty; emoji image assertion skipped")
            return
        }
        for (index, reference) in references.enumerated() {
            let bytes = try await fetcher.data(emojiId: reference.id, shortName: reference.shortName)
            let frames = Self.imageFrameCount(bytes)
            print("live: emoji #\(index + 1) \(reference.shortName.isEmpty ? reference.id : reference.shortName): \(bytes.count) bytes, \(frames) image frame(s)")
            #expect(frames > 0, "emoji #\(index + 1) did not decode as an image")
        }
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
    /// `ADF_LIVE_EMOJI_IDS`, split on commas.
    let emojiIds: [String]

    static let current: LiveEnvironment = {
        let environment = ProcessInfo.processInfo.environment
        func value(_ name: String) -> String? {
            guard let raw = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return raw
        }
        let emojiIds = (value("ADF_LIVE_EMOJI_IDS") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return LiveEnvironment(site: value("ADF_LIVE_SITE"), pageId: value("ADF_LIVE_PAGE") ?? "229377", emojiIds: emojiIds)
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
        let value = try await fetchADFJSON(credential: credential, cloudId: cloudId, pageId: pageId)
        return try await ADFParser().parse(Data(value.utf8))
    }

    /// The raw ADF JSON string of the page body.
    static func fetchADFJSON(credential: AtlassianCredential, cloudId: String, pageId: String) async throws -> String {
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
        return value
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

/// Emoji references read from raw ADF JSON (`emoji.attrs.{id, shortName}`
/// and custom panel icons' `panelIconId`/`panelIcon`).
struct EmojiScan {
    struct Reference: Equatable {
        let id: String
        let shortName: String
    }

    private(set) var emojis: [Reference] = []
    private(set) var emojisWithoutId = 0
    private(set) var panelIcons: [Reference] = []

    init(adfJSON: String) throws {
        let root = try JSONSerialization.jsonObject(with: Data(adfJSON.utf8))
        visit(root)
    }

    private mutating func visit(_ value: Any) {
        if let object = value as? [String: Any] {
            let attrs = object["attrs"] as? [String: Any] ?? [:]
            switch object["type"] as? String {
            case "emoji":
                let shortName = attrs["shortName"] as? String ?? ""
                if let id = attrs["id"] as? String, !id.isEmpty {
                    emojis.append(Reference(id: id, shortName: shortName))
                } else {
                    emojisWithoutId += 1
                }
            case "panel":
                if let id = attrs["panelIconId"] as? String, !id.isEmpty {
                    panelIcons.append(Reference(id: id, shortName: attrs["panelIcon"] as? String ?? ""))
                }
            default:
                break
            }
            for child in object.values { visit(child) }
        } else if let array = value as? [Any] {
            for child in array { visit(child) }
        }
    }
}
